// vid_subsystem.sv -- the new video subsystem behind flat ports.
//
// Interfaces are used inside only; the ports are plain AXI signals so the
// Verilog top level connects to it as to any other block, and so the AXI
// attributes the controller needs but the subsystem never varies (size,
// burst type, cache, prot, lock, strobes) are fixed in one place.
//
// Contents:
//   axi_arb      write masters: 0 legacy, 1 display producer, 2 processing,
//                               3 self-test
//                read  masters: 0 legacy, 1-2 display layers, 3 processing,
//                               4 self-test
//                (lower index = higher priority)
//   self-test    vid_testgen -> vdma_wr -> frame_ring (test) -> vdma_rd ->
//                vid_testchk, every word compared, results in status
//   display      producer -> vdma_wr -> frame_ring (ISP) -> vdma_rd
//                (dual-clock) -> compositor, in the pixel clock, out to the
//                HDMI encoder.  The producer is the camera (DISP_SRC = 1):
//                csi_capture (CSI clock) -> line_release -> isp_top, or the
//                test picture vid_patgen (DISP_SRC = 0).
//   processing   PROC_EN: proc_engine reads each new frame of the ISP ring,
//                runs proc_stub and writes the PROC ring.  The compositor
//                shows the ISP ring as layer 0 and the PROC ring as layer 1,
//                single or split (COMP_CFG).
module vid_subsystem
    import vid_pkg::*;
#(
    parameter bit ENABLE_SELFTEST = 1,
    // 0 = the legacy frame store gets no DDR access (its requests are never
    // accepted, so it simply stalls).
    parameter bit LEGACY_EN       = 1,
    // Display producer: 0 = vid_patgen test picture, 1 = camera through the ISP.
    parameter bit DISP_SRC        = 0,
    // Camera path: 1 = replace the sensor's pixels with csi_capture's fixed
    // picture (sensor timing kept), for on-board signature checks.
    parameter bit CSI_PATTERN     = 0,
    parameter isp_cfg_t ISP_CFG   = ISP_CFG_DEFAULT,
    parameter string GAMMA_CURVE  = "./rtl/gamma_conrrection/SRGB_ENC.mem",
    parameter bit PROC_EN         = 0,
    parameter proc_mode_e PROC_MODE = PROC_INVERT,
    parameter comp_cfg_t COMP_CFG = COMP_CFG_DEFAULT,
    // Display pattern timing; simulation shortens the frame period.
    parameter int PAT_FRAME_CYCLES  = 3_333_333,
    parameter int PAT_LINE_CYCLES   = 2_000,
    // Self-test geometry and timing; simulation shortens them.
    parameter int TEST_LINES        = CAM_H,
    parameter int TEST_FRAME_CYCLES = 3_333_333,
    parameter int TEST_LINE_CYCLES  = 2_000,
    // Outstanding bursts allowed at the DDR port, per direction.  Both are 1
    // because of how the board's (encrypted) controller behaves:
    //   reads:  a second read issued before the first completes returns
    //           wrong data (about 8% of self-test frames carried another
    //           master's data; the legacy picture showed horizontal glitches);
    //   writes: queued writes are served before reads, so with 8 writes in
    //           flight a read waited up to 11 us and the display reader fell
    //           to 30 frames/s with underflows; with 1, reads wait at most
    //           6 us and the display holds 60 frames/s.
    parameter int DDR_MAX_WR        = 1,
    parameter int DDR_MAX_RD        = 1
) (
    input  logic                  clk,          // AXI / core clock
    input  logic                  rst_n,

    // ---------------------------------------- legacy frame store (AXI slave)
    input  logic [AXI_IW-1:0]     lg_awid,
    input  logic [AXI_AW-1:0]     lg_awaddr,
    input  logic [7:0]            lg_awlen,
    input  logic                  lg_awvalid,
    output logic                  lg_awready,
    input  logic [AXI_DW-1:0]     lg_wdata,
    input  logic                  lg_wlast,
    input  logic                  lg_wvalid,
    output logic                  lg_wready,
    output logic [AXI_IW-1:0]     lg_bid,
    output logic [1:0]            lg_bresp,
    output logic                  lg_bvalid,
    input  logic                  lg_bready,
    input  logic [AXI_IW-1:0]     lg_arid,
    input  logic [AXI_AW-1:0]     lg_araddr,
    input  logic [7:0]            lg_arlen,
    input  logic                  lg_arvalid,
    output logic                  lg_arready,
    output logic [AXI_IW-1:0]     lg_rid,
    output logic [AXI_DW-1:0]     lg_rdata,
    output logic [1:0]            lg_rresp,
    output logic                  lg_rlast,
    output logic                  lg_rvalid,
    input  logic                  lg_rready,

    // ------------------------------------------------ DDR controller (master)
    output logic [AXI_IW-1:0]     ddr_awid,
    output logic [AXI_AW-1:0]     ddr_awaddr,
    output logic [7:0]            ddr_awlen,
    output logic [2:0]            ddr_awsize,
    output logic [1:0]            ddr_awburst,
    output logic                  ddr_awlock,
    output logic [3:0]            ddr_awcache,
    output logic [2:0]            ddr_awprot,
    output logic                  ddr_awvalid,
    input  logic                  ddr_awready,
    output logic [AXI_DW-1:0]     ddr_wdata,
    output logic [AXI_DW/8-1:0]   ddr_wstrb,
    output logic                  ddr_wlast,
    output logic                  ddr_wvalid,
    input  logic                  ddr_wready,
    input  logic [AXI_IW-1:0]     ddr_bid,
    input  logic [1:0]            ddr_bresp,
    input  logic                  ddr_bvalid,
    output logic                  ddr_bready,
    output logic [AXI_IW-1:0]     ddr_arid,
    output logic [AXI_AW-1:0]     ddr_araddr,
    output logic [7:0]            ddr_arlen,
    output logic [2:0]            ddr_arsize,
    output logic [1:0]            ddr_arburst,
    output logic                  ddr_arlock,
    output logic [3:0]            ddr_arcache,
    output logic [2:0]            ddr_arprot,
    output logic                  ddr_arvalid,
    input  logic                  ddr_arready,
    input  logic [AXI_IW-1:0]     ddr_rid,
    input  logic [AXI_DW-1:0]     ddr_rdata,
    input  logic [1:0]            ddr_rresp,
    input  logic                  ddr_rlast,
    input  logic                  ddr_rvalid,
    output logic                  ddr_rready,

    // ---------------------------------------------- camera (CSI pixel clock)
    input  logic                  csi_clk,
    input  logic                  csi_vs,
    input  logic                  csi_hs,
    input  logic                  csi_de,
    input  logic [39:0]           csi_data,     // 4 RAW10 pixels, leftmost in [9:0]

    // ------------------------------------------------- display (pixel clock)
    input  logic                  pix_clk,
    output logic [7:0]            pix_r,
    output logic [7:0]            pix_g,
    output logic [7:0]            pix_b,
    output logic                  pix_de,
    output logic                  pix_hs,
    output logic                  pix_vs,

    output vid_status_t           status
);
    localparam int NW = 4, NR = 5;
    // Lower index = higher priority.  The camera cannot wait and the display
    // must not underflow; processing and the self-test can wait.
    localparam int W_DISP = 1, W_PROC = 2, W_SELF = 3;
    localparam int R_DISP = 1, R_DISP1 = 2, R_PROC = 3, R_SELF = 4;

    // Pixel-clock reset: asserted with rst_n, released synchronously.
    logic pix_rst_q1, pix_rst_n;
    always_ff @(posedge pix_clk or negedge rst_n)
        if (!rst_n) {pix_rst_n, pix_rst_q1} <= 2'b00;
        else        {pix_rst_n, pix_rst_q1} <= {pix_rst_q1, 1'b1};

    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mw [NW] (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mr [NR] (.clk(clk), .rst_n(rst_n));
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));

    // ------------------------------------------------- legacy = master 0
    assign mw[0].awid    = lg_awid;
    assign mw[0].awaddr  = lg_awaddr;
    assign mw[0].awlen   = lg_awlen;
    assign mw[0].awvalid = lg_awvalid && LEGACY_EN;
    assign lg_awready    = mw[0].awready && LEGACY_EN;
    assign mw[0].wdata   = lg_wdata;
    assign mw[0].wlast   = lg_wlast;
    assign mw[0].wvalid  = lg_wvalid && LEGACY_EN;
    assign lg_wready     = mw[0].wready && LEGACY_EN;
    assign lg_bid        = mw[0].bid;
    assign lg_bresp      = mw[0].bresp;
    assign lg_bvalid     = mw[0].bvalid;
    assign mw[0].bready  = lg_bready;

    assign mr[0].arid    = lg_arid;
    assign mr[0].araddr  = lg_araddr;
    assign mr[0].arlen   = lg_arlen;
    assign mr[0].arvalid = lg_arvalid && LEGACY_EN;
    assign lg_arready    = mr[0].arready && LEGACY_EN;
    assign lg_rid        = mr[0].rid;
    assign lg_rdata      = mr[0].rdata;
    assign lg_rresp      = mr[0].rresp;
    assign lg_rlast      = mr[0].rlast;
    assign lg_rvalid     = mr[0].rvalid;
    assign mr[0].rready  = lg_rready;

    // ------------------------------------------------------- self-test
    if (ENABLE_SELFTEST) begin : g_selftest
        frame_geom_t geom;
        assign geom = '{w: 13'(CAM_W), h: 13'(TEST_LINES)};

        vstream_if #(.T(rgb565_t), .PPC(2)) gen (.clk(clk), .rst_n(rst_n));
        vstream_if #(.T(rgb565_t), .PPC(2)) back (.clk(clk), .rst_n(rst_n));
        ring_prod_if rp ();
        ring_cons_if rc [1] ();

        logic [15:0] gen_frame;
        vid_testgen #(.FRAME_CYCLES(TEST_FRAME_CYCLES), .LINE_CYCLES(TEST_LINE_CYCLES)) u_gen (
            .o(gen), .geom(geom), .enable(1'b1), .frame(gen_frame));

        frame_ring #(.SLOTS(3), .NCONS(1)) u_ring (
            .clk(clk), .rst_n(rst_n), .p(rp), .c(rc), .status(status.test_ring));

        vdma_wr #(.FIFO_BEATS(512)) u_wr (
            .s(gen), .m(mw[W_SELF]), .ring(rp),
            .ring_base(RING_TEST_BASE), .geom(geom), .src_seq(gen_frame),
            .st_frames(status.tw_frames), .st_skipped(status.tw_skipped),
            .st_errors(status.tw_errors), .st_sig(status.tw_sig));

        logic         rd_busy, rd_start;
        frame_token_t rd_tok;
        logic [SEQ_W-1:0] rd_frames, rd_late;
        always_ff @(posedge clk or negedge rst_n)
            if (!rst_n) rd_start <= 1'b0;
            else        rd_start <= !rd_busy && !rd_start;

        vdma_rd #(.FIFO_BEATS(512), .RD_BURST(128)) u_rd (
            .m(mr[R_SELF]), .ring(rc[0]), .o(back),
            .ring_base(RING_TEST_BASE), .start(rd_start), .policy(ACQ_NEW_ONLY), .geom(geom),
            .x0_beat(8'd0), .nbeats(8'(CAM_W / BEAT_PIX)),
            .busy(rd_busy), .token(rd_tok),
            .st_frames(rd_frames), .st_miss(status.tr_miss), .st_late(rd_late));

        vid_testchk u_chk (
            .s(back), .geom(geom), .frame_id(rd_tok.src_seq),
            .st_frames(status.tc_frames), .st_bad_frames(status.tc_bad_frames),
            .st_bad_words(status.tc_bad_words), .st_first_bad(status.tc_first_bad),
            .st_last_bad(status.tc_last_bad), .st_last_pos(status.tc_last_pos));
    end else begin : g_no_selftest
        assign mw[W_SELF].awvalid = 1'b0;
        assign mw[W_SELF].awid    = '0;
        assign mw[W_SELF].awaddr  = '0;
        assign mw[W_SELF].awlen   = '0;
        assign mw[W_SELF].wvalid  = 1'b0;
        assign mw[W_SELF].wdata   = '0;
        assign mw[W_SELF].wlast   = 1'b0;
        assign mw[W_SELF].bready  = 1'b1;
        assign mr[R_SELF].arvalid = 1'b0;
        assign mr[R_SELF].arid    = '0;
        assign mr[R_SELF].araddr  = '0;
        assign mr[R_SELF].arlen   = '0;
        assign mr[R_SELF].rready  = 1'b1;
        assign status.test_ring     = '0;
        assign status.tw_frames     = '0;
        assign status.tw_errors     = '0;
        assign status.tw_skipped    = '0;
        assign status.tw_sig        = '0;
        assign status.tc_frames     = '0;
        assign status.tc_bad_frames = '0;
        assign status.tc_bad_words  = '0;
        assign status.tc_first_bad  = '0;
        assign status.tc_last_bad   = '0;
        assign status.tc_last_pos   = '0;
        assign status.tr_miss       = '0;
    end

    // --------------------------------------------------------- display
    if (1) begin : g_display
        vstream_if #(.T(rgb565_t), .PPC(2)) prod (.clk(clk), .rst_n(rst_n));
        vstream_if #(.T(rgb565_t), .PPC(2)) lay0 (.clk(pix_clk), .rst_n(pix_rst_n));
        vstream_if #(.T(rgb565_t), .PPC(2)) lay1 (.clk(pix_clk), .rst_n(pix_rst_n));
        ring_prod_if rp ();
        ring_cons_if rc [2] ();         // 0: display layer 0, 1: processing
        ring_status_t ring_st;
        logic [SEQ_W-1:0] prod_seq;

        if (DISP_SRC) begin : g_cam
            // CSI clock reset: asserted with rst_n, released synchronously.
            logic csi_rst_q1, csi_rst_n;
            always_ff @(posedge csi_clk or negedge rst_n)
                if (!rst_n) {csi_rst_n, csi_rst_q1} <= 2'b00;
                else        {csi_rst_n, csi_rst_q1} <= {csi_rst_q1, 1'b1};

            logic        cw_en, cw_full;
            logic [41:0] cw_data;
            csi_capture #(.PATTERN(CSI_PATTERN)) u_cap (
                .clk(csi_clk), .rst_n(csi_rst_n),
                .vs(csi_vs), .hs(csi_hs), .de(csi_de), .data(csi_data),
                .wen(cw_en), .wdata(cw_data), .wfull(cw_full),
                .st_frames(status.cap_frames), .st_lines(status.cap_lines),
                .st_beats(status.cap_beats), .st_dropped(status.cap_dropped));

            vpush_if #(.T(raw10_t),  .PPC(2)) raw (.clk(clk), .rst_n(rst_n));
            vpush_if #(.T(rgb565_t), .PPC(2)) img (.clk(clk), .rst_n(rst_n));

            line_release u_rel (
                .wclk(csi_clk), .wrst_n(csi_rst_n), .wen(cw_en), .wdata(cw_data), .wfull(cw_full),
                .o(raw), .st_holes(status.rel_holes));

            isp_top #(.GAMMA_CURVE(GAMMA_CURVE)) u_isp (
                .i(raw), .o(img), .cfg(ISP_CFG),
                .st_sum(status.raw_sum), .st_clip(status.raw_clip), .st_dark(status.raw_dark));

            push2stream u_p2s (.p(img), .s(prod), .st_dropped(status.isp_dropped));

            // Frames are numbered by the capture's frame counter, synchronised
            // only for labelling (it is sampled when the slot is acquired).
            logic [SEQ_W-1:0] seq_s1, seq_s2;
            always_ff @(posedge clk or negedge rst_n)
                if (!rst_n) {seq_s2, seq_s1} <= '0;
                else        {seq_s2, seq_s1} <= {seq_s1, status.cap_frames};
            assign prod_seq = seq_s2;
        end else begin : g_pat
            vid_patgen #(.FRAME_CYCLES(PAT_FRAME_CYCLES), .LINE_CYCLES(PAT_LINE_CYCLES)) u_pat (
                .o(prod), .enable(1'b1), .frame(prod_seq));
            assign status.cap_frames  = '0;
            assign status.cap_lines   = '0;
            assign status.cap_beats   = '0;
            assign status.cap_dropped = '0;
            assign status.rel_holes   = '0;
            assign status.isp_dropped = '0;
            assign status.raw_sum     = '0;
            assign status.raw_clip    = '0;
            assign status.raw_dark    = '0;
        end

        frame_ring #(.SLOTS(4), .NCONS(2)) u_ring (
            .clk(clk), .rst_n(rst_n), .p(rp), .c(rc), .status(ring_st));
        assign status.isp_ring_err = ring_st.proto_err;

        vdma_wr #(.FIFO_BEATS(512)) u_wr (
            .s(prod), .m(mw[W_DISP]), .ring(rp),
            .ring_base(RING_ISP_BASE), .geom(CAM_GEOM), .src_seq(prod_seq),
            .st_frames(status.pw_frames), .st_skipped(status.pw_skipped),
            .st_errors(status.pw_errors), .st_sig(status.pw_sig));

        // Raster frame request, pixel clock -> core clock.
        logic frame_req;
        (* async_reg = "true" *) logic [2:0] req_sync;
        always_ff @(posedge clk or negedge rst_n)
            if (!rst_n) req_sync <= '0;
            else        req_sync <= {req_sync[1:0], frame_req};
        wire rd_start = req_sync[2] ^ req_sync[1];

        // Each layer reads only the columns the compositor shows.
        localparam logic [7:0] X0B0 = crop_beats(COMP_CFG, 0, 1'b0), NB0 = crop_beats(COMP_CFG, 0, 1'b1);
        localparam logic [7:0] X0B1 = crop_beats(COMP_CFG, 1, 1'b0), NB1 = crop_beats(COMP_CFG, 1, 1'b1);

        logic         rd_busy, rd1_busy;
        logic [SEQ_W-1:0] rd1_late;      // same start as layer 0, counted there
        frame_token_t rd_tok, rd1_tok;
        // Long bursts: the DDR port serves one read at a time (DDR_MAX_RD),
        // so every burst pays the full read latency; 128 beats amortise it.
        if (NB0 != 0) begin : g_rd0
            vdma_rd #(.FIFO_BEATS(512), .RD_BURST(128), .ASYNC(1)) u_rd (
                .m(mr[R_DISP]), .ring(rc[0]), .o(lay0),
                .ring_base(RING_ISP_BASE), .start(rd_start), .policy(ACQ_REPEAT_OK), .geom(CAM_GEOM),
                .x0_beat(X0B0), .nbeats(NB0),
                .busy(rd_busy), .token(rd_tok),
                .st_frames(status.dr_frames), .st_miss(status.dr_miss), .st_late(status.dr_late));
        end else begin : g_no_rd0
            rd_idle u_idle (.m(mr[R_DISP]), .ring(rc[0]));
            stream_idle u_sidle (.o(lay0));
            assign rd_busy = 1'b0;
            assign rd_tok  = '0;
            assign status.dr_frames = '0;
            assign status.dr_miss   = '0;
            assign status.dr_late   = '0;
        end

        // Processing: ISP ring -> proc_stub -> PROC ring, shown as layer 1.
        ring_prod_if pp ();
        ring_cons_if pc [1] ();
        if (PROC_EN) begin : g_proc
            ring_status_t pring_st;
            frame_ring #(.SLOTS(3), .NCONS(1)) u_pring (
                .clk(clk), .rst_n(rst_n), .p(pp), .c(pc), .status(pring_st));
            assign status.proc_ring_err = pring_st.proto_err;

            proc_engine #(.MODE(PROC_MODE)) u_proc (
                .mr(mr[R_PROC]), .mw(mw[W_PROC]), .src(rc[1]), .dst(pp),
                .src_base(RING_ISP_BASE), .dst_base(RING_PROC_BASE),
                .st_frames(status.pr_frames), .st_miss(status.pr_miss),
                .st_errors(status.pr_errors), .st_skipped(status.pr_skipped));
        end else begin : g_no_proc
            rd_idle u_idle (.m(mr[R_PROC]), .ring(rc[1]));
            assign mw[W_PROC].awvalid = 1'b0;
            assign mw[W_PROC].awid    = '0;
            assign mw[W_PROC].awaddr  = '0;
            assign mw[W_PROC].awlen   = '0;
            assign mw[W_PROC].wvalid  = 1'b0;
            assign mw[W_PROC].wdata   = '0;
            assign mw[W_PROC].wlast   = 1'b0;
            assign mw[W_PROC].bready  = 1'b1;
            assign pp.req     = 1'b0;
            assign pp.op      = RING_P_ACQ;
            assign pp.src_seq = '0;
            assign status.proc_ring_err = 1'b0;
            assign status.pr_frames  = '0;
            assign status.pr_miss    = '0;
            assign status.pr_errors  = '0;
            assign status.pr_skipped = '0;
        end

        if (PROC_EN && NB1 != 0) begin : g_rd1
            vdma_rd #(.FIFO_BEATS(512), .RD_BURST(128), .ASYNC(1)) u_rd (
                .m(mr[R_DISP1]), .ring(pc[0]), .o(lay1),
                .ring_base(RING_PROC_BASE), .start(rd_start), .policy(ACQ_REPEAT_OK), .geom(CAM_GEOM),
                .x0_beat(X0B1), .nbeats(NB1),
                .busy(rd1_busy), .token(rd1_tok),
                .st_frames(status.dr1_frames), .st_miss(status.dr1_miss), .st_late(rd1_late));
        end else begin : g_no_rd1
            rd_idle u_idle (.m(mr[R_DISP1]), .ring(pc[0]));
            stream_idle u_sidle (.o(lay1));
            assign rd1_busy = 1'b0;
            assign rd1_tok  = '0;
            assign status.dr1_frames = '0;
            assign status.dr1_miss   = '0;
        end

        // How far the processed layer trails the camera layer, in frames.
        always_ff @(posedge clk or negedge rst_n)
            if (!rst_n)                          status.seq_gap <= '0;
            else if (rd_tok.valid && rd1_tok.valid) status.seq_gap <= rd_tok.src_seq - rd1_tok.src_seq;

        logic [15:0] cp_bad [2], cp_rs [2];
        compositor #(.CFG(COMP_CFG)) u_comp (
            .layer0(lay0), .layer1(lay1), .frame_req(frame_req),
            .r(pix_r), .g(pix_g), .b(pix_b), .de(pix_de), .hs(pix_hs), .vs(pix_vs),
            .st_bad_lines(cp_bad), .st_resyncs(cp_rs),
            .st_frame_sum(status.cp_frame_sum), .st_jumps(status.cp_jumps));
        assign status.cp_bad_lines  = cp_bad[0];
        assign status.cp1_bad_lines = cp_bad[1];
        assign status.cp_resyncs    = cp_rs[0];
        assign status.cp1_resyncs   = cp_rs[1];
    end

    // ---------------------------------------- legacy burst-length monitor
    // The legacy writer's wlast logic is hand-rolled; check that each burst
    // carries exactly awlen + 1 beats, because the arbiter orders W by AW and
    // a mismatch would hand beats to the next master's burst.
    logic       lm_valid, lm_full;
    logic [7:0] lm_len;
    logic [3:0] lm_level;
    logic [8:0] lm_beats;
    wire        lm_w    = lg_wvalid && mw[0].wready;
    wire        lm_last = lm_w && lg_wlast;

    fifo_sync_core #(.W(8), .DEPTH(8)) u_lm (
        .clk(clk), .rst_n(rst_n),
        .wen(lg_awvalid && mw[0].awready), .wdata(lg_awlen), .wfull(lm_full),
        .rready(lm_last), .rvalid(lm_valid), .rdata(lm_len), .level(lm_level));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lm_beats             <= '0;
            status.lg_wlen_err   <= '0;
            status.lg_last_len   <= '0;
            status.lg_last_beats <= '0;
        end else if (lm_w) begin
            lm_beats <= lm_last ? '0 : lm_beats + 1'b1;
            // Early wlast, missing wlast, or W with no AW outstanding.
            if ((lm_last && lm_beats != 9'(lm_len)) || (!lm_last && lm_beats == 9'(lm_len))
                || !lm_valid) begin
                status.lg_wlen_err   <= status.lg_wlen_err + 1'b1;
                status.lg_last_len   <= lm_len;
                status.lg_last_beats <= 8'(lm_beats + 1'b1);
            end
        end
    end

    // AXI forbids withdrawing an address before it is accepted; the legacy
    // engines do it when they reset at frame boundaries.  Count it.
    logic lg_arv_d, lg_arr_d, lg_awv_d, lg_awr_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lg_arv_d <= 1'b0; lg_arr_d <= 1'b0; lg_awv_d <= 1'b0; lg_awr_d <= 1'b0;
            status.lg_ar_wd <= '0;
            status.lg_aw_wd <= '0;
        end else begin
            lg_arv_d <= lg_arvalid; lg_arr_d <= mr[0].arready;
            lg_awv_d <= lg_awvalid; lg_awr_d <= mw[0].awready;
            if (lg_arv_d && !lg_arr_d && !lg_arvalid)
                status.lg_ar_wd <= status.lg_ar_wd + 1'b1;
            if (lg_awv_d && !lg_awr_d && !lg_awvalid)
                status.lg_aw_wd <= status.lg_aw_wd + 1'b1;
        end
    end

    // ------------------------------------------------- DDR read latency
    // With one read outstanding at a time, a single counter suffices.
    logic        lat_run;
    logic [15:0] lat_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lat_run            <= 1'b0;
            lat_cnt            <= '0;
            status.rd_lat_max  <= '0;
            status.rd_lat_last <= '0;
        end else begin
            if (dr.arvalid && dr.arready) begin
                lat_run <= 1'b1;
                lat_cnt <= '0;
            end else if (lat_run && dr.rvalid && dr.rready) begin
                lat_run            <= 1'b0;
                status.rd_lat_last <= lat_cnt;
                if (lat_cnt > status.rd_lat_max)
                    status.rd_lat_max <= lat_cnt;
            end else if (lat_run && lat_cnt != 16'hFFFF) begin
                lat_cnt <= lat_cnt + 1'b1;
            end
        end
    end

    // ------------------------------------------------ DDR write latency
    // AW accepted to B, one write outstanding at a time (DDR_MAX_WR = 1).
    logic        wl_run;
    logic [15:0] wl_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wl_run            <= 1'b0;
            wl_cnt            <= '0;
            status.wr_lat_max <= '0;
        end else begin
            if (dw.awvalid && dw.awready) begin
                wl_run <= 1'b1;
                wl_cnt <= '0;
            end else if (wl_run && dw.bvalid && dw.bready) begin
                wl_run <= 1'b0;
                if (wl_cnt > status.wr_lat_max)
                    status.wr_lat_max <= wl_cnt;
            end else if (wl_run && wl_cnt != 16'hFFFF) begin
                wl_cnt <= wl_cnt + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------- DDR
    axi_arb #(.NW(NW), .NR(NR), .MAX_WR(DDR_MAX_WR), .MAX_RD(DDR_MAX_RD)) u_arb (
        .sw(mw), .sr(mr), .mw(dw), .mr(dr));

    assign ddr_awid    = dw.awid;
    assign ddr_awaddr  = dw.awaddr;
    assign ddr_awlen   = dw.awlen;
    assign ddr_awsize  = 3'($clog2(BEAT_BYTES));
    assign ddr_awburst = 2'b01;          // INCR
    assign ddr_awlock  = 1'b0;
    assign ddr_awcache = 4'b0011;
    assign ddr_awprot  = 3'b010;
    assign ddr_awvalid = dw.awvalid;
    assign dw.awready  = ddr_awready;
    assign ddr_wdata   = dw.wdata;
    assign ddr_wstrb   = '1;
    assign ddr_wlast   = dw.wlast;
    assign ddr_wvalid  = dw.wvalid;
    assign dw.wready   = ddr_wready;
    assign dw.bid      = ddr_bid;
    assign dw.bresp    = ddr_bresp;
    assign dw.bvalid   = ddr_bvalid;
    assign ddr_bready  = dw.bready;

    assign ddr_arid    = dr.arid;
    assign ddr_araddr  = dr.araddr;
    assign ddr_arlen   = dr.arlen;
    assign ddr_arsize  = 3'($clog2(BEAT_BYTES));
    assign ddr_arburst = 2'b01;
    assign ddr_arlock  = 1'b0;
    assign ddr_arcache = 4'b0011;
    assign ddr_arprot  = 3'b010;
    assign ddr_arvalid = dr.arvalid;
    assign dr.arready  = ddr_arready;
    assign dr.rid      = ddr_rid;
    assign dr.rdata    = ddr_rdata;
    assign dr.rresp    = ddr_rresp;
    assign dr.rlast    = ddr_rlast;
    assign dr.rvalid   = ddr_rvalid;
    assign ddr_rready  = dr.rready;

endmodule


// An unused read master and ring consumer.
module rd_idle (
    axi4_rd_if.mst     m,
    ring_cons_if.user  ring
);
    import vid_pkg::*;
    assign m.arvalid   = 1'b0;
    assign m.arid      = '0;
    assign m.araddr    = '0;
    assign m.arlen     = '0;
    assign m.rready    = 1'b1;
    assign ring.req    = 1'b0;
    assign ring.op     = RING_C_ACQ;
    assign ring.policy = ACQ_REPEAT_OK;
endmodule

// A stream source that never offers anything.
module stream_idle (vstream_if.src o);
    assign o.valid = 1'b0;
    assign o.sof   = 1'b0;
    assign o.eol   = 1'b0;
    assign o.data  = '0;
endmodule
