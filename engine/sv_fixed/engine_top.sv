//=============================================================================
// engine_top.veryl -- E5b: the synthesizable engine top
//-----------------------------------------------------------------------------
// Hierarchy (what "veryl build" elaborates for this module):
//
//   engine_top
//     +-- seq  : layer_seq #(CASCADE = 1)   the 16 layer walk
//     |           +-- conv_stream           P-lane int8 MAC + line buffer
//     |           |     +-- requant_unit x2 (frozen, 2 values/cycle)
//     |           +-- tile_reader           raster window reader (stride/halo)
//     +-- padd : point_add                  residual branch requant + sat_add
//                 +-- requant_unit (frozen) + sat_add (frozen)
//
// Contract (architecture.md 8, 11; E4 descriptor semantics):
//   * one engine_top start runs n_layers descriptors from the external
//     descriptor ROM; the ROM index is desc_idx (driven by layer_seq), so the
//     ROM stays outside and both styles reuse this same top.
//   * the descriptor residual side is USED, not assumed zero: when the running
//     layer has d_res_en = 1, the top inserts one point_add pass after that
//     layer's done, i.e.
//         point[out_pt] = sat_add(round_shift(point[res_pt]*res_m0, res_shift),
//                                 point[out_pt])
//     with the branch plane taken from the point whose out_pt == res_pt
//     (res_br_off / res_br_len) and the trunk plane being this layer's own
//     output (d_y_off / d_y_bytes).  res_sat must be 1: point_add is always the
//     saturating variant, which is what all four residual slots declare.
//   * the four residual scalars (res.<r>_m0_18b.hex, res.<r>_shift.txt) arrive
//     by way of the extended descriptor: they are fields of the descriptor ROM
//     (option B, commit 4f20dad), which drives res_m0 / res_shift into this
//     module's input ports.  The ports are unchanged -- only the source is the
//     ROM rather than direct testbench wiring -- and they are NOT the per-oc
//     conv M0 table.  The descriptor field count is therefore 26, not 24.
//     res_pt -> plane offset, which needs out_pt, not extra ROM fields.
//   * because the residual pass writes back into the layer's own plane, a layer
//     with d_res_en = 1 must be run as its own start (n_layers = 1); the top
//     flags any other combination on err.
//
// Counters published for the E5 accounting: seq_st_cyc is the cycles the
// sequencer reports for the running layer (st_we strobe), res_cyc accumulates
// point_add's own cycles, res_steps counts residual passes.
//=============================================================================
module engine_top #(
    parameter int unsigned P    = 32,
    parameter int unsigned MAXC = 64,
    parameter int unsigned TW   = 64,
    parameter int unsigned TILE = 64,
    parameter int unsigned AW   = 24,
    parameter int unsigned MAXL = 16
) (
    input  var logic          clk     ,
    input  var logic          rst_n   ,
    input  var logic          start   ,
    output var logic          busy    ,
    output var logic          done    ,
    output var logic          err     ,
    input  var logic [16-1:0] img_h   ,
    input  var logic [16-1:0] img_w   ,
    input  var logic [8-1:0]  n_layers,

    // descriptor ROM (external, indexed by desc_idx)
    output var logic [8-1:0]  desc_idx  ,
    input  var logic          d_valid   ,
    input  var logic [4-1:0]  d_layer_id,
    input  var logic [8-1:0]  d_in_c    ,
    input  var logic [8-1:0]  d_out_c   ,
    input  var logic [2-1:0]  d_k       ,
    input  var logic [2-1:0]  d_stride  ,
    input  var logic [2-1:0]  d_pad     ,
    input  var logic          d_relu    ,
    input  var logic [6-1:0]  d_shift   ,
    input  var logic          d_up2x_in ,
    input  var logic          d_res_en  ,
    input  var logic [4-1:0]  d_res_pt  ,
    input  var logic          d_res_sat ,
    input  var logic [4-1:0]  d_out_pt  ,
    input  var logic          d_keep    ,
    input  var logic          d_unsigned,
    input  var logic [24-1:0] d_w_off   ,
    input  var logic [24-1:0] d_w_bytes ,
    input  var logic [24-1:0] d_b_off   ,
    input  var logic [24-1:0] d_m_off   ,
    input  var logic [24-1:0] d_x_off   ,
    input  var logic [24-1:0] d_y_off   ,
    input  var logic [24-1:0] d_x_words ,
    input  var logic [24-1:0] d_y_bytes ,

    // residual side (option A: scalars + resolved branch plane from outside)
    input  var logic signed [18-1:0] res_m0     ,
    input  var logic        [6-1:0]  res_shift  ,
    input  var logic        [AW-1:0] res_br_off ,
    input  var logic        [32-1:0] res_br_len ,
    output var logic        [AW-1:0] res_br_addr,
    input  var logic        [8-1:0]  res_br_data,
    output var logic        [AW-1:0] res_tr_addr,
    input  var logic        [8-1:0]  res_tr_data,

    // off-chip parameter stream
    output var logic        [24-1:0] w_addr,
    input  var logic        [8-1:0]  w_data,
    output var logic        [24-1:0] b_addr,
    input  var logic signed [32-1:0] b_data,
    output var logic        [24-1:0] m_addr,
    input  var logic signed [18-1:0] m_data,

    // feature map arena
    output var logic [32-1:0]         x_addr,
    input  var logic [(8 * MAXC)-1:0] x_data,
    output var logic                  y_we  ,
    output var logic [24-1:0]         y_addr,
    output var logic [8-1:0]          y_data,

    // status / evidence
    output var logic [32-1:0] seq_cyc   ,
    output var logic [32-1:0] res_cyc   ,
    output var logic [8-1:0]  res_steps ,
    output var logic          res_active,
    output var logic [48-1:0] tot_cyc   
);
    // ---- sequencer instance ------------------------------------------------
    logic          sq_busy  ;
    logic          sq_done  ;
    logic [8-1:0]  sq_didx  ;
    logic [24-1:0] sq_waddr ;
    logic [24-1:0] sq_baddr ;
    logic [24-1:0] sq_maddr ;
    logic [32-1:0] sq_xaddr ;
    logic          sq_ywe   ;
    logic [24-1:0] sq_yaddr ;
    logic [8-1:0]  sq_ydata ;
    logic          sq_stwe  ;
    logic [8-1:0]  sq_stidx ;
    logic [32-1:0] sq_stcyc ;
    logic [4-1:0]  sq_stlid ;
    logic [32-1:0] sq_stwb  ;
    logic [8-1:0]  sq_stbb  ;
    logic [8-1:0]  sq_stmb  ;
    logic [32-1:0] sq_stxp  ;
    logic [32-1:0] sq_styb  ;
    logic [8-1:0]  sq_stblk ;
    logic [8-1:0]  sq_sttl  ;
    logic [32-1:0] sq_ststl ;
    logic [48-1:0] sq_totwb ;
    logic [48-1:0] sq_totxp ;
    logic [48-1:0] sq_totyb ;
    logic [48-1:0] sq_totcyc;
    logic          sq_err   ;

    // ---- point_add instance ------------------------------------------------
    logic [AW-1:0] pt_br    ;
    logic [AW-1:0] pt_tr    ;
    logic          pt_we    ;
    logic [AW-1:0] pt_oaddr ;
    logic [8-1:0]  pt_odata ;
    logic          pt_busy  ;
    logic          pt_done  ;
    logic [32-1:0] pt_cyc   ;
    logic          pt_err   ;
    logic          pt_start ;
    logic [32-1:0] pt_nbytes;

    // ---- control -----------------------------------------------------------
    logic [3-1:0]  st_r     ;
    logic          busy_r   ;
    logic          done_r   ;
    logic          err_r    ;
    logic          sq_start ;
    logic [24-1:0] l_y_off  ;
    logic [32-1:0] l_y_bytes;
    logic          l_res_en ;
    logic          l_res_sat;
    logic          res_run  ;
    logic [32-1:0] seq_cyc_r;
    logic [32-1:0] res_cyc_r;
    logic [8-1:0]  res_stp_r;

    layer_seq #(
        .P       (P   ),
        .MAXC    (MAXC),
        .TW      (TW  ),
        .TILE    (TILE),
        .CASCADE (1   ),
        .MAXL    (MAXL)
    ) seq (
        .clk         (clk       ),
        .rst_n       (rst_n     ),
        .img_h       (img_h     ),
        .img_w       (img_w     ),
        .n_layers    (n_layers  ),
        .desc_start  (8'd0      ),
        .start       (sq_start  ),
        .busy        (sq_busy   ),
        .done        (sq_done   ),
        .desc_idx    (sq_didx   ),
        .d_valid     (d_valid   ),
        .d_layer_id  (d_layer_id),
        .d_in_c      (d_in_c    ),
        .d_out_c     (d_out_c   ),
        .d_k         (d_k       ),
        .d_stride    (d_stride  ),
        .d_pad       (d_pad     ),
        .d_relu      (d_relu    ),
        .d_shift     (d_shift   ),
        .d_up2x_in   (d_up2x_in ),
        .d_res_en    (d_res_en  ),
        .d_res_pt    (d_res_pt  ),
        .d_res_sat   (d_res_sat ),
        .d_res_m0    (res_m0    ),
        .d_res_shift (res_shift ),
        .d_out_pt    (d_out_pt  ),
        .d_keep      (d_keep    ),
        .d_unsigned  (d_unsigned),
        .d_w_off     (d_w_off   ),
        .d_w_bytes   (d_w_bytes ),
        .d_b_off     (d_b_off   ),
        .d_m_off     (d_m_off   ),
        .d_x_off     (d_x_off   ),
        .d_y_off     (d_y_off   ),
        .d_x_words   (d_x_words ),
        .d_y_bytes   (d_y_bytes ),
        .w_addr      (sq_waddr  ),
        .w_data      (w_data    ),
        .b_addr      (sq_baddr  ),
        .b_data      (b_data    ),
        .m_addr      (sq_maddr  ),
        .m_data      (m_data    ),
        .x_addr      (sq_xaddr  ),
        .x_data      (x_data    ),
        .y_we        (sq_ywe    ),
        .y_addr      (sq_yaddr  ),
        .y_data      (sq_ydata  ),
        .st_we       (sq_stwe   ),
        .st_idx      (sq_stidx  ),
        .st_layer_id (sq_stlid  ),
        .st_cyc      (sq_stcyc  ),
        .st_w_bytes  (sq_stwb   ),
        .st_b_words  (sq_stbb   ),
        .st_m_words  (sq_stmb   ),
        .st_x_px     (sq_stxp   ),
        .st_y_bytes  (sq_styb   ),
        .st_blocks   (sq_stblk  ),
        .st_tiles    (sq_sttl   ),
        .st_stall    (sq_ststl  ),
        .tot_cyc     (sq_totcyc ),
        .tot_w_bytes (sq_totwb  ),
        .tot_x_px    (sq_totxp  ),
        .tot_y_bytes (sq_totyb  ),
        .err         (sq_err    )
    );

    point_add #(
        .AW (AW)
    ) padd (
        .clk      (clk        ),
        .rst_n    (rst_n      ),
        .start    (pt_start   ),
        .busy     (pt_busy    ),
        .done     (pt_done    ),
        .n_bytes  (pt_nbytes  ),
        .m0_i     (res_m0     ),
        .shift_i  (res_shift  ),
        .br_addr  (pt_br      ),
        .br_data  (res_br_data),
        .tr_addr  (pt_tr      ),
        .tr_data  (res_tr_data),
        .out_we   (pt_we      ),
        .out_addr (pt_oaddr   ),
        .out_data (pt_odata   ),
        .cyc_o    (pt_cyc     ),
        .err_o    (pt_err     )
    );

    // ---- wiring ------------------------------------------------------------
    always_comb begin
        desc_idx    = sq_didx;
        busy        = busy_r;
        done        = done_r;
        err         = err_r | sq_err | pt_err;
        seq_cyc     = seq_cyc_r;
        res_cyc     = res_cyc_r;
        res_steps   = res_stp_r;
        res_active  = res_run;
        tot_cyc     = sq_totcyc;
        res_br_addr = res_br_off + pt_br;
        res_tr_addr = l_y_off[AW - 1:0] + pt_tr;
        pt_nbytes   = res_br_len;
        if ((res_run)) begin
            y_we   = pt_we;
            y_addr = l_y_off[AW - 1:0] + pt_oaddr;
            y_data = pt_odata;
        end else begin
            y_we   = sq_ywe;
            y_addr = sq_yaddr;
            y_data = sq_ydata;
        end
        if ((res_run)) begin
            w_addr = 0;
            b_addr = 0;
            m_addr = 0;
        end else begin
            w_addr = sq_waddr;
            b_addr = sq_baddr;
            m_addr = sq_maddr;
        end
        x_addr = sq_xaddr;
    end

    always_ff @ (posedge clk) begin
        if ((st_r == 3'd0)) begin
            done_r   <= 0;
            sq_start <= 0;
            pt_start <= 0;
            res_run  <= 0;
            if ((start)) begin
                busy_r    <= 1;
                err_r     <= 0;
                seq_cyc_r <= 0;
                res_cyc_r <= 0;
                res_stp_r <= 0;
                l_y_off   <= d_y_off;
                l_y_bytes <= d_y_bytes;
                l_res_en  <= d_res_en;
                l_res_sat <= d_res_sat;
                // a residual pass writes back into the layer's own plane, so
                // such a layer must be run alone
                if ((d_res_en && (n_layers != 8'd1))) begin
                    err_r <= 1;
                end
                if ((d_res_en && !d_res_sat)) begin
                    err_r <= 1;
                end
                sq_start <= 1;
                st_r     <= 3'd1;
            end
        end else if ((st_r == 3'd1)) begin
            sq_start <= 0;
            if ((sq_stwe)) begin
                seq_cyc_r <= sq_stcyc;
            end
            if ((sq_done)) begin
                if ((l_res_en)) begin
                    res_run  <= 1;
                    pt_start <= 1;
                    st_r     <= 3'd2;
                end else begin
                    st_r <= 3'd3;
                end
            end
        end else if ((st_r == 3'd2)) begin
            pt_start <= 0;
            if ((pt_done)) begin
                res_cyc_r <= res_cyc_r + pt_cyc;
                res_stp_r <= res_stp_r + 8'd1;
                res_run   <= 0;
                st_r      <= 3'd3;
            end
        end else if ((st_r == 3'd3)) begin
            busy_r <= 0;
            done_r <= 1;
            st_r   <= 3'd0;
        end
    end
endmodule
