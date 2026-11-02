// st_engine.sv -- the ST block engine: the style network as 15 DDR passes
// through one programmable datapath (docs/st-accel-engine-adr.md).
//
//   rd_main ─┬─ st_pre ──────────────────────────────────────────────┐ pass 0
//            └─ unpack(main) ─ [add IN] ─ st_dw ─ st_pw ─ [add OUT] ─┬─ st_pack ─┤ 1..13
//   rd_aux  ─── unpack(aux) ────┘ (up0)                  (resKb) ┘   └─ st_post ─┤ 14
//                                                                           wr ┘
//
// Routing is static per pass.  One st_add serves both positions: before the
// DW stage for the up0 skip (ST_ADD_IN), after the PW stage for the resKb
// residuals (ST_ADD_OUT).  The two readers share the AXI port through
// axi_arb.
//
// Per pass p the configuration comes from st_net_pkg (st_pass, st_layer,
// st_region): it is looked up into registers in S_CFG, the blocks the pass
// uses get one start pulse in S_GO, and S_RUN waits until all of them are
// idle and the writer's last B response is back.  Pass 0 reads the whole
// 1280x720 ISP slot; pass 14 writes the whole 1280x720 PROC slot, aligned
// pixel for pixel with it.  Blocks a pass does not use are never started, so they keep
// in_ready low and out_valid low.
//
// start (while idle) samples isp_base, proc_base and the pass range; a
// subrange lets a test run one pass on a preloaded DDR image.  pre_done rises
// when pass 0 has finished, so the ISP frame can be released early.  cycles
// is the length of the last complete run, err a DMA or framing error in it.
module st_engine
    import vid_pkg::*;
    import st_net_pkg::*;
(
    input  logic               clk,
    input  logic               rst_n,

    axi4_wr_if.mst             m_wr,
    axi4_rd_if.mst             m_rd,

    input  logic               start,
    input  logic [AXI_AW-1:0]  isp_base,    // ISP slot of the source frame
    input  logic [AXI_AW-1:0]  proc_base,   // PROC slot to write
    input  logic [3:0]         first_pass,  // passes run: first_pass..last_pass;
    input  logic [3:0]         last_pass,   // 0 and ST_N_PASSES-1 except in tests
    output logic               busy,
    output logic               pre_done,    // pass 0 complete: ISP slot no longer read
    output logic               err,         // sticky for the run
    output logic [3:0]         pass,        // current pass
    output logic [31:0]        cycles       // cycles of the last complete run
);
    // ==========================================================================
    // AXI: main and aux readers through the arbiter, the writer direct
    // ==========================================================================
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) aw [1] (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) ar [2] (.clk(clk), .rst_n(rst_n));

    axi_arb #(.NW(1), .NR(2)) u_arb (.sw(aw), .sr(ar), .mw(m_wr), .mr(m_rd));

    vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_main (.clk(clk), .rst_n(rst_n));
    vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_aux  (.clk(clk), .rst_n(rst_n));
    vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_wr   (.clk(clk), .rst_n(rst_n));

    // ==========================================================================
    // Pass configuration (registered in S_CFG)
    // ==========================================================================
    logic              is_pre, is_post, use_aux, add_in, add_out;
    logic [AXI_AW-1:0] rm_base, ra_base, wr_base;
    logic [15:0]       rm_bpl, rm_lines, ra_bpl, ra_lines, wr_bpl, wr_lines;
    logic [AXI_AW-1:0] rm_stride, ra_stride, wr_stride;
    logic              rm_shift;

    logic [6:0]        um_c, ua_c;
    logic              um_e2, ua_e2;
    logic [7:0]        um_pb, ua_pb;
    logic [9:0]        um_w, ua_w, um_h, ua_h;

    logic [1:0]        dw_mode;
    logic [9:0]        dw_w, dw_h;
    logic [4:0]        dw_g;
    logic [1:0]        dw_stride;
    logic [9:0]        dw_base;
    logic [10:0]       dw_rq;
    logic [9:0]        dw_lo, dw_hi;

    logic [16:0]       pw_npix;
    logic [1:0]        pw_n;
    logic [6:0]        pw_cin0, pw_cin1, pw_cout0, pw_cout1;
    logic [9:0]        pw_base0, pw_base1;
    logic [10:0]       pw_rq0, pw_rq1;
    logic [9:0]        pw_lo0, pw_lo1, pw_hi0, pw_hi1;

    logic [6:0]        pk_c;
    logic              pk_e2;
    logic [9:0]        pk_h;

    logic [23:0]       add_mant;
    logic [5:0]        add_k;

    // Region geometry: beats per line and line stride of a packed tensor.
    function automatic logic [15:0] r_bpl(input st_region_t r);
        return 16'((18'(r.w) * 18'(r.pb)) >> 4);
    endfunction
    function automatic logic [AXI_AW-1:0] r_stride(input st_region_t r);
        return AXI_AW'(18'(r.w) * 18'(r.pb));
    endfunction

    // ==========================================================================
    // Stages
    // ==========================================================================
    logic go;                               // one-cycle start of the pass
    logic rm_busy, ra_busy, wr_busy, rm_err, ra_err, wr_err;
    logic pre_busy, post_busy, um_busy, ua_busy, dw_busy, pw_busy, pk_busy;
    logic pre_err, post_err;
    logic [SEQ_W-1:0] rm_done, ra_done, wr_done, rm_errs, ra_errs, wr_errs;   // unused DMA counters

    tile_dma_rd #(.FIFO_BEATS(512), .RD_BURST(128)) u_rd_main (
        .m(ar[0]), .o(s_main),
        .start(go), .base_addr(rm_base), .beats_per_line(rm_bpl), .lines(rm_lines),
        .line_stride(rm_stride), .line_shift(rm_shift),
        .busy(rm_busy), .err(rm_err), .st_done(rm_done), .st_err(rm_errs));

    tile_dma_rd #(.FIFO_BEATS(256), .RD_BURST(64)) u_rd_aux (
        .m(ar[1]), .o(s_aux),
        .start(go && use_aux), .base_addr(ra_base), .beats_per_line(ra_bpl), .lines(ra_lines),
        .line_stride(ra_stride), .line_shift(1'b0),
        .busy(ra_busy), .err(ra_err), .st_done(ra_done), .st_err(ra_errs));

    tile_dma_wr #(.FIFO_BEATS(512), .WR_BURST(128)) u_wr (
        .m(aw[0]), .i(s_wr),
        .start(go), .base_addr(wr_base), .beats_per_line(wr_bpl), .lines(wr_lines),
        .line_stride(wr_stride),
        .busy(wr_busy), .err(wr_err), .st_done(wr_done), .st_err(wr_errs));

    // group streams: unpack main / aux, add, dw, pw, and the 128-bit outputs
    logic        um_v, um_r, um_l, um_e, um_s;  logic [39:0] um_d;
    logic        ua_v, ua_r, ua_l, ua_e, ua_s;  logic [39:0] ua_d;
    logic        ad_v, ad_r, ad_l, ad_e, ad_s;  logic [39:0] ad_d;
    logic        at_v, at_r, at_l, at_e, at_s;  logic [39:0] at_d;
    logic        di_v, di_r, di_l, di_e, di_s;  logic [39:0] di_d;
    logic        dw_v, dw_r, dw_l, dw_e, dw_s;  logic [39:0] dw_d;
    logic [127:0] dw_wide;                      // the im2col 16-byte beat
    logic        pw_v, pw_r, pw_l, pw_e, pw_s;  logic [39:0] pw_d;
    logic        pk_v, pk_r, pk_s, pk_e;        logic [127:0] pk_d;
    logic        pr_v, pr_r, pr_s, pr_e;        logic [127:0] pr_d;
    logic        po_v, po_r, po_s, po_e;        logic [127:0] po_d;
    logic        um_in_r, pre_in_r, ua_in_r, pk_in_r, po_in_r;

    st_pre u_pre (
        .clk(clk), .rst_n(rst_n),
        .in_valid(s_main.valid && is_pre), .in_ready(pre_in_r),
        .in_data(s_main.data[0]), .in_sof(s_main.sof), .in_eol(s_main.eol),
        .out_valid(pr_v), .out_ready(pr_r), .out_data(pr_d), .out_sof(pr_s), .out_eol(pr_e),
        .start(go && is_pre), .busy(pre_busy), .err(pre_err));

    st_unpack u_um (
        .clk(clk), .rst_n(rst_n), .start(go && !is_pre),
        .cfg_c(um_c), .cfg_elem2(um_e2), .cfg_pb(um_pb), .cfg_w(um_w), .cfg_h(um_h),
        .cfg_hrep(rm_shift), .busy(um_busy),
        .in_valid(s_main.valid && !is_pre), .in_ready(um_in_r),
        .in_data(s_main.data[0]), .in_sof(s_main.sof), .in_eol(s_main.eol),
        .out_valid(um_v), .out_ready(um_r), .out_data(um_d),
        .out_last(um_l), .out_eol(um_e), .out_sof(um_s));

    assign s_main.ready = is_pre ? pre_in_r : um_in_r;

    st_unpack u_ua (
        .clk(clk), .rst_n(rst_n), .start(go && use_aux),
        .cfg_c(ua_c), .cfg_elem2(ua_e2), .cfg_pb(ua_pb), .cfg_w(ua_w), .cfg_h(ua_h),
        .cfg_hrep(1'b0), .busy(ua_busy),
        .in_valid(s_aux.valid), .in_ready(ua_in_r),
        .in_data(s_aux.data[0]), .in_sof(s_aux.sof), .in_eol(s_aux.eol),
        .out_valid(ua_v), .out_ready(ua_r), .out_data(ua_d),
        .out_last(ua_l), .out_eol(ua_e), .out_sof(ua_s));

    assign s_aux.ready = ua_in_r;

    // add trunk: the main unpack (IN) or the PW output (OUT)
    assign at_v = add_in ? um_v : (add_out && pw_v);
    assign at_d = add_in ? um_d : pw_d;
    assign at_l = add_in ? um_l : pw_l;
    assign at_e = add_in ? um_e : pw_e;
    assign at_s = add_in ? um_s : pw_s;

    st_add u_add (
        .clk(clk), .rst_n(rst_n), .cfg_mant(add_mant), .cfg_k(add_k),
        .t_valid(at_v), .t_ready(at_r), .t_data(at_d), .t_last(at_l), .t_eol(at_e), .t_sof(at_s),
        .a_valid(ua_v && use_aux), .a_ready(ua_r), .a_data(ua_d),
        .a_last(ua_l), .a_eol(ua_e), .a_sof(ua_s),
        .out_valid(ad_v), .out_ready(ad_r), .out_data(ad_d),
        .out_last(ad_l), .out_eol(ad_e), .out_sof(ad_s));

    // DW input: the add (IN) or the main unpack
    assign di_v = add_in ? ad_v : um_v;
    assign di_d = add_in ? ad_d : um_d;
    assign di_l = add_in ? ad_l : um_l;
    assign di_e = add_in ? ad_e : um_e;
    assign di_s = add_in ? ad_s : um_s;
    assign um_r = add_in ? at_r : di_r;

    st_dw u_dw (
        .clk(clk), .rst_n(rst_n), .start(go && !is_pre), .busy(dw_busy),
        .cfg_mode(dw_mode), .cfg_w(dw_w), .cfg_h(dw_h), .cfg_g(dw_g), .cfg_stride(dw_stride),
        .cfg_dw_base(dw_base), .cfg_rq_base(dw_rq), .cfg_lo(dw_lo), .cfg_hi(dw_hi),
        .in_valid(di_v), .in_ready(di_r), .in_data(di_d),
        .in_last(di_l), .in_eol(di_e), .in_sof(di_s),
        .out_valid(dw_v), .out_ready(dw_r), .out_data(dw_d), .out_wide(dw_wide),
        .out_last(dw_l), .out_eol(dw_e), .out_sof(dw_s));

    st_pw u_pw (
        .clk(clk), .rst_n(rst_n),
        .in_valid(dw_v), .in_ready(dw_r), .in_data(dw_d),
        .in_last(dw_l), .in_eol(dw_e), .in_sof(dw_s),
        .out_valid(pw_v), .out_ready(pw_r), .out_data(pw_d),
        .out_last(pw_l), .out_eol(pw_e), .out_sof(pw_s),
        .start(go && !is_pre), .busy(pw_busy),
        .cfg_npix(pw_npix), .cfg_n(pw_n), .cfg_cin0(pw_cin0), .cfg_cin1(pw_cin1),
        .cfg_cout0(pw_cout0), .cfg_cout1(pw_cout1),
        .cfg_pw_base0(pw_base0), .cfg_pw_base1(pw_base1),
        .cfg_rq_base0(pw_rq0), .cfg_rq_base1(pw_rq1),
        .cfg_lo0(pw_lo0), .cfg_lo1(pw_lo1), .cfg_hi0(pw_hi0), .cfg_hi1(pw_hi1));

    // PW output: the add (OUT), st_post (pass 14) or st_pack
    assign pw_r = add_out ? at_r : is_post ? po_in_r : pk_in_r;

    // pack input: the add (OUT) or the PW output
    logic pki_v, pki_l, pki_e, pki_s;
    logic [39:0] pki_d;
    assign pki_v = add_out ? ad_v : (pw_v && !is_post);
    assign pki_d = add_out ? ad_d : pw_d;
    assign pki_l = add_out ? ad_l : pw_l;
    assign pki_e = add_out ? ad_e : pw_e;
    assign pki_s = add_out ? ad_s : pw_s;
    assign ad_r  = add_in ? di_r : pk_in_r;

    st_pack u_pack (
        .clk(clk), .rst_n(rst_n), .start(go && !is_pre && !is_post),
        .cfg_c(pk_c), .cfg_elem2(pk_e2), .cfg_h(pk_h), .busy(pk_busy),
        .in_valid(pki_v), .in_ready(pk_in_r), .in_data(pki_d),
        .in_last(pki_l), .in_eol(pki_e), .in_sof(pki_s),
        .out_valid(pk_v), .out_ready(pk_r), .out_data(pk_d), .out_sof(pk_s), .out_eol(pk_e));

    st_post u_post (
        .clk(clk), .rst_n(rst_n),
        .in_valid(pw_v && is_post), .in_ready(po_in_r), .in_data(pw_d),
        .in_last(pw_l), .in_sof(pw_s), .in_eol(pw_e),
        .out_valid(po_v), .out_ready(po_r), .out_data(po_d), .out_sof(po_s), .out_eol(po_e),
        .start(go && is_post), .busy(post_busy), .err(post_err));

    // writer input: pre (pass 0), post (pass 14) or pack
    assign s_wr.valid   = is_pre ? pr_v : is_post ? po_v : pk_v;
    assign s_wr.data[0] = is_pre ? pr_d : is_post ? po_d : pk_d;
    assign s_wr.sof     = is_pre ? pr_s : is_post ? po_s : pk_s;
    assign s_wr.eol     = is_pre ? pr_e : is_post ? po_e : pk_e;
    assign pr_r = is_pre && s_wr.ready;
    assign po_r = is_post && s_wr.ready;
    assign pk_r = !is_pre && !is_post && s_wr.ready;

    // ==========================================================================
    // Pass sequencer
    // ==========================================================================
    typedef enum logic [1:0] { S_IDLE, S_CFG, S_GO, S_RUN } state_e;
    state_e state;

    logic [AXI_AW-1:0] isp_q, proc_q;
    logic [3:0]        last_q;
    logic [31:0]       cyc;
    logic [1:0]        settle;              // DMA busy is valid two cycles after go

    wire stages_busy = rm_busy || ra_busy || wr_busy || pre_busy || post_busy || um_busy
                    || ua_busy || dw_busy || pw_busy || pk_busy;
    wire dma_err     = rm_err || ra_err || wr_err || pre_err || post_err;

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            pass     <= '0;
            go       <= 1'b0;
            settle   <= '0;
            pre_done <= 1'b0;
            err      <= 1'b0;
            cyc      <= '0;
            cycles   <= '0;
            isp_q    <= '0;
            proc_q   <= '0;
            last_q   <= '0;
        end else begin
            go <= 1'b0;
            if (state != S_IDLE) cyc <= cyc + 32'd1;

            unique case (state)
                S_IDLE: if (start) begin
                    isp_q    <= isp_base;
                    proc_q   <= proc_base;
                    last_q   <= last_pass;
                    pass     <= first_pass;
                    pre_done <= 1'b0;
                    err      <= 1'b0;
                    cyc      <= 32'd1;
                    state    <= S_CFG;
                end

                S_CFG: state <= S_GO;       // configuration registers load here

                S_GO: begin
                    go     <= 1'b1;
                    settle <= 2'd2;
                    state  <= S_RUN;
                end

                S_RUN: begin
                    if (settle != 0) settle <= settle - 2'd1;
                    if (dma_err) err <= 1'b1;
                    if (settle == 0 && !go && !stages_busy) begin
                        if (pass == 4'd0) pre_done <= 1'b1;
                        if (pass == last_q) begin
                            cycles <= cyc;
                            state  <= S_IDLE;
                        end else begin
                            pass  <= pass + 4'd1;
                            state <= S_CFG;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Configuration lookup for the current pass, registered in S_CFG.
    always_ff @(posedge clk) begin
        if (state == S_CFG) begin
            automatic st_pass_t   p  = st_pass(int'(pass));
            automatic st_region_t ri = st_region(int'(p.in_point));
            automatic st_region_t ra = st_region(int'(p.aux_point));
            automatic st_region_t ro = st_region(int'(p.out_point));
            automatic st_layer_t  l0 = st_layer(int'(p.first_layer));
            // PW layers: after the DW layer, or the im2col stem layer itself
            automatic int         pf = (l0.kind == ST_KIND_DW) ? int'(p.first_layer) + 1
                                                               : int'(p.first_layer);
            automatic int         pn = int'(p.n_layers) - ((l0.kind == ST_KIND_DW) ? 1 : 0);
            automatic st_layer_t  la = st_layer(pf);
            automatic st_layer_t  lb = st_layer(pf + 1);
            automatic st_add_factor_t af = st_add_factor(int'(p.add_rq));

            is_pre  <= (pass == 4'd0);
            is_post <= (pass == 4'(ST_N_PASSES - 1));
            use_aux <= (p.add_mode != ST_ADD_NONE);
            add_in  <= (p.add_mode == ST_ADD_IN);
            add_out <= (p.add_mode == ST_ADD_OUT);

            // main read
            if (pass == 4'd0) begin
                rm_base   <= isp_q;
                rm_bpl    <= 16'(CAM_W * PIX_BYTES / BEAT_BYTES);
                rm_lines  <= 16'(CAM_H);
                rm_stride <= AXI_AW'(LINE_STRIDE);
                rm_shift  <= 1'b0;
            end else begin
                rm_base   <= AXI_AW'(ri.base);
                rm_bpl    <= r_bpl(ri);
                rm_lines  <= 16'(p.in_h);
                rm_stride <= r_stride(ri);
                rm_shift  <= p.upsample;
            end
            um_c  <= ri.c;
            um_e2 <= (ri.elem == 2'd2);
            um_pb <= ri.pb;
            um_w  <= ri.w;
            um_h  <= 10'(p.in_h);

            // aux read
            ra_base   <= AXI_AW'(ra.base);
            ra_bpl    <= r_bpl(ra);
            ra_lines  <= 16'(ra.h);
            ra_stride <= r_stride(ra);
            ua_c  <= ra.c;
            ua_e2 <= (ra.elem == 2'd2);
            ua_pb <= ra.pb;
            ua_w  <= ra.w;
            ua_h  <= ra.h;
            add_mant <= af.mant;
            add_k    <= af.k;

            // write
            if (pass == 4'(ST_N_PASSES - 1)) begin
                wr_base   <= proc_q;
                wr_bpl    <= 16'(CAM_W * PIX_BYTES / BEAT_BYTES);
                wr_lines  <= 16'(CAM_H);
                wr_stride <= AXI_AW'(LINE_STRIDE);
            end else begin
                wr_base   <= AXI_AW'(ro.base);
                wr_bpl    <= r_bpl(ro);
                wr_lines  <= 16'(ro.h);
                wr_stride <= r_stride(ro);
            end

            // DW stage: st_dw modes are 0 DW, 1 IM2COL, 2 BYPASS
            dw_mode   <= (l0.kind == ST_KIND_DW) ? 2'd0 :
                         (l0.kind == ST_KIND_IM2COL) ? 2'd1 : 2'd2;
            dw_w      <= 10'(p.in_w);
            dw_h      <= 10'(p.in_h);
            dw_g      <= 5'((p.in_c + 7'd3) >> 2);
            dw_stride <= l0.stride;
            dw_base   <= l0.dw_base;
            dw_rq     <= l0.rq_base;
            dw_lo     <= l0.lo;
            dw_hi     <= l0.hi;

            // PW stage: 1x1 layers keep the DW output grid
            pw_npix  <= 17'(p.out_w * p.out_h);
            pw_n     <= 2'(pn);
            pw_cin0  <= la.cin;   pw_cin1  <= lb.cin;
            pw_cout0 <= la.cout;  pw_cout1 <= lb.cout;
            pw_base0 <= la.pw_base; pw_base1 <= lb.pw_base;
            pw_rq0   <= la.rq_base; pw_rq1   <= lb.rq_base;
            pw_lo0   <= la.lo;    pw_lo1   <= lb.lo;
            pw_hi0   <= la.hi;    pw_hi1   <= lb.hi;

            // pack
            pk_c  <= p.out_c;
            pk_e2 <= (ro.elem == 2'd2);
            pk_h  <= 10'(p.out_h);
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk)
        if (rst_n && state == S_CFG) begin
            automatic st_pass_t  p  = st_pass(int'(pass));
            automatic st_layer_t l0 = st_layer(int'(p.first_layer));
            automatic int        pn = int'(p.n_layers) - ((l0.kind == ST_KIND_DW) ? 1 : 0);
            if (pass != 4'd0 && (pn < 1 || pn > 2))
                $error("st_engine: pass %0d has %0d PW layers", pass, pn);
        end
`endif

    logic unused;
    assign unused = ^{rm_done, ra_done, wr_done, rm_errs, ra_errs, wr_errs};
endmodule
