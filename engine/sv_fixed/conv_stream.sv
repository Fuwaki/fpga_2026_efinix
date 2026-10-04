//=============================================================================
// conv_stream.veryl -- E3: row-streaming int8 convolution datapath
//-----------------------------------------------------------------------------
// One conv layer, one tile per run.  The datapath is fed by a raster pixel
// stream and keeps only a few rows on chip:
//
//   x pixel stream --> [line buffer: K_MAX rows x W_LB pixels x MAXC bytes]
//                        -> window gather -> P-lane MAC (P DSP)
//                        -> shared requant (2 frozen requant_unit, 2 DSP)
//                        -> one tagged oc-block beat per output pixel
//
// Contract (docs/engine/architecture.md):
//   §2  acc is int32 and exact; the ONLY numerically frozen step is requant,
//       and it is done by the very same requant_unit module (2 instances,
//       time shared at 2 values/cycle => R2 satisfied, DSP = P + 2).
//   §5  the tile window is S*(tile_w-1)+K wide; the halo comes from the stream
//       producer (tile_reader), which reflects only at the image border.
//       Window indices here are tile-local, so no border logic can leak in.
//   §6  P = oc block size = MAC lanes; oc blocks are walked per pixel so the
//       input stream is read exactly once (no input-channel split).
//   §4  line buffer RAM = NSLOT*(TW*2+2)*MAXC bytes, 1..3 orders of magnitude
//       below holding a whole feature map (see conv_lb_alloc_bytes).
//   §1  every module boundary is valid/ready; no "wait N cycles" assumption.
//
// RAM accounting (bytes); the pub functions below are asserted in
// test/tb_stream_ram.veryl:
//   line buffer : NSLOT(=3) * (TW*2+2) * MAXC       = 24 960 B @TW=64, MAXC=64
//                                                   = 49 536 B @TW=128,MAXC=64
//   weights     : K_MAX^2 * MAXC * ceil(MAXC/P) * P = 36 864 B @MAXC=64, P=32
//   whole map   : IN_C*H*W + OUT_C*H*W              = 2 MiB @128^2, 64ch => 84x
//
// Weight load port (w_we/w_addr/w_data) is SEQUENTIAL by contract: the host
// streams the layer's weight bytes in the verified layout
// ((ic*K+ky)*K+kx)*OUT_C+oc, addresses 0,1,2,...,w_bytes-1, with cfg_out_c
// already loaded (cfg = layer descriptor).  w_addr is compared against the
// internal byte counter; any mismatch sets the sticky w_seq_err.  Bytes are
// packed on the fly into (tap, oc-block) words so the compute side reads P
// weights in one cycle from one packed read port, while the load side keeps
// the frozen byte interface: no divider, no RAM read-modify-write.  The word
// under construction lives in the wr_sh register and the RAM is only ever
// written as one full word: a byte-slice write into a wide RAM word makes
// Efinity's Titanium mapper abort (docs/engine/e5_resources.md 3).
//=============================================================================

/// Line buffer RAM ALLOCATED for a tile width: NSLOT(=K_MAX=3) rows of
/// (TW*2+2) pixels, each pixel MAXC bytes.





module conv_stream #(
    parameter int unsigned P       = 32, // MAC lanes == oc block size (34 DSP at P=32)
    parameter int unsigned MAXC    = 64, // largest IN_C / OUT_C this instance supports
    parameter int unsigned TW      = 64, // largest tile width (output pixels) supported
    parameter int unsigned ACC_W   = 32,
    parameter int unsigned M0_W    = 18,
    parameter int unsigned SHIFT_W = 6 ,
    parameter int unsigned OCW     = 6 
) (
    input var logic clk  ,
    input var logic rst_n,

    // ---- layer descriptor + tile geometry (latch while !busy) --------------
    input  var logic               cfg_valid ,
    output var logic               cfg_ready ,
    input  var logic [8-1:0]       cfg_in_c  ,
    input  var logic [8-1:0]       cfg_out_c ,
    input  var logic [2-1:0]       cfg_k     ,
    input  var logic [2-1:0]       cfg_stride,
    input  var logic               cfg_relu  ,
    input  var logic [SHIFT_W-1:0] cfg_shift ,
    input  var logic [16-1:0]      tile_y0   , // tile origin in OUTPUT coords
    input  var logic [16-1:0]      tile_x0   ,
    input  var logic [16-1:0]      tile_h    , // effective output tile size
    input  var logic [16-1:0]      tile_w    ,
    input  var logic               start     ,
    output var logic               busy      ,
    output var logic               done      ,

    // ---- weight / bias / M0 loads (frozen byte layout, sequential sweep) ---
    input  var logic                    w_we     ,
    input  var logic        [16-1:0]    w_addr   ,
    input  var logic        [8-1:0]     w_data   ,
    output var logic                    w_seq_err,
    input  var logic                    b_we     ,
    input  var logic        [OCW-1:0]   b_addr   ,
    input  var logic signed [ACC_W-1:0] b_data   ,
    input  var logic                    m_we     ,
    input  var logic        [OCW-1:0]   m_addr   ,
    input  var logic signed [M0_W-1:0]  m_data   ,

    // ---- input pixel stream (HWC packed: channel ic at bits 8*ic +: 8) -----
    input  var logic                  x_valid  ,
    output var logic                  x_ready  ,
    input  var logic [(8 * MAXC)-1:0] x_pixel  ,
    input  var logic                  x_sof    , // first pixel of the tile window
    input  var logic                  x_eol    , // last pixel of a window row
    output var logic                  x_hdr_err, // sticky: sof/eol disagree with the stream geometry

    // ---- output beats: one oc block of one output pixel per beat ----------
    output var logic               y_valid  ,
    input  var logic               y_ready  ,
    output var logic [(8 * P)-1:0] y_data   , // byte j = channel oc_base + j
    output var logic [8-1:0]       y_oc_base,
    output var logic [8-1:0]       y_cnt    , // valid bytes of this beat
    output var logic [16-1:0]      y_oy     , // global output coords
    output var logic [16-1:0]      y_ox 
);
    // ---- compile-time geometry --------------------------------------------
    localparam int unsigned         NSLOT    = 3; // K_MAX: line buffer row slots
    localparam int unsigned         W_LB     = TW * 2 + 2; // max window width (S<=2, PAD<=1, K<=3)
    localparam int unsigned         LB_DEPTH = NSLOT * W_LB;
    localparam int unsigned         LBW      = $clog2(LB_DEPTH);
    localparam int unsigned         NTAP     = 9 * MAXC; // K_MAX^2 * IN_C_MAX
    localparam int unsigned         NPASS    = (MAXC + P - 1) / P;
    localparam int unsigned         W_DEPTH  = NTAP * NPASS; // packed words (one per tap/block)
    localparam int unsigned         WW       = $clog2(W_DEPTH);
    localparam logic        [8-1:0] NSLOT_M1 = NSLOT - 1;

    // ---- storage ----------------------------------------------------------
    logic        [(8 * MAXC)-1:0] lb    [LB_DEPTH]; // pixel-wide line buffer (1W1R)
    logic        [(8 * P)-1:0]    wr    [W_DEPTH] ; // packed weights (1W1R, P B/read)
    logic        [(8 * P)-1:0]    wr_sh           ; // packed word under construction
    logic signed [ACC_W-1:0]      acc   [2 * P]   ; // double-buffered acc banks
    logic signed [ACC_W-1:0]      bram  [MAXC]    ;
    logic signed [M0_W-1:0]       mram  [MAXC]    ;

    // ---- layer descriptor registers ---------------------------------------
    logic [8-1:0]       c_in_c  ;
    logic [8-1:0]       c_out_c ;
    logic [2-1:0]       c_k     ;
    logic [2-1:0]       c_stride;
    logic               c_relu  ;
    logic [SHIFT_W-1:0] c_shift ;
    logic [16-1:0]      c_ty0   ;
    logic [16-1:0]      c_tx0   ;
    logic [16-1:0]      c_th    ;
    logic [16-1:0]      c_tw    ;

    // ---- weight load counters (sequential sweep) --------------------------
    logic [16-1:0] ld_addr;
    logic [16-1:0] ld_t   ; // tap index
    logic [8-1:0]  ld_oc  ; // output channel inside the tap
    logic          w_err  ;
    logic          x_err  ;

    // ---- line buffer fill --------------------------------------------------
    logic [16-1:0] ld_row ; // rows already completed
    logic [16-1:0] ld_col ;
    logic [8-1:0]  ld_slot; // == ld_row % NSLOT

    // ---- MAC side ----------------------------------------------------------
    localparam logic [3-1:0] S_IDLE = 0;
    localparam logic [3-1:0] S_LOAD = 1;
    localparam logic [3-1:0] S_TAP  = 2;
    localparam logic [3-1:0] S_DONE = 3;

    localparam logic [2-1:0] T_WAIT = 0;
    localparam logic [2-1:0] T_MAC  = 1;
    localparam logic [2-1:0] T_END  = 2;

    logic [3-1:0]  state    ;
    logic [2-1:0]  tps      ;
    logic [16-1:0] oy       ;
    logic [16-1:0] ox       ;
    logic [8-1:0]  blk      ;
    logic [2-1:0]  ky       ;
    logic [2-1:0]  kx       ;
    logic [8-1:0]  tap_c    ;
    logic [8-1:0]  ic       ;
    logic [32-1:0] col_base ; // S * ox
    logic [8-1:0]  win_slot0; // (S * oy) % NSLOT
    logic [32-1:0] u_mac    ; // units whose MAC phase is complete
    logic [32-1:0] u_rq     ; // units whose requant+emit is complete

    // ---- shared requant side ----------------------------------------------
    localparam logic [2-1:0] RQ_IDLE  = 0;
    localparam logic [2-1:0] RQ_DRAIN = 1;
    localparam logic [2-1:0] RQ_EMIT  = 2;

    logic [2-1:0]  rq_state    ;
    logic [8-1:0]  drain_c     ;
    logic [8-1:0]  ybeat    [P];
    logic          b_pend   [2]; // unit waiting for / being requantised
    logic [16-1:0] b_oy     [2];
    logic [16-1:0] b_ox     [2];
    logic [8-1:0]  b_blk    [2];

    // ---- RAM read registers (registered read ports) -----------------------
    logic [(8 * MAXC)-1:0] lb_rd;
    logic [(8 * P)-1:0]    w_rd ;

    // ---- combinational helpers -------------------------------------------
    logic        [32-1:0] win_w_c           ;
    logic        [32-1:0] win_h_c           ;
    logic        [32-1:0] k2_c              ;
    logic        [32-1:0] np_c              ;
    logic        [32-1:0] ld_end_c          ;
    logic        [32-1:0] u_tot_c           ;
    logic        [32-1:0] slot_sum          ;
    logic        [32-1:0] cur_slot          ;
    logic        [32-1:0] acc_base          ;
    logic        [32-1:0] rq_base           ;
    logic        [8-1:0]  rq_blk_c          ;
    logic        [32-1:0] rq_ocb_c          ;
    logic        [32-1:0] rq_pe_c           ;
    logic        [32-1:0] rq_nc_c           ;
    logic        [32-1:0] rq_i0_c           ;
    logic        [32-1:0] rq_i1_c           ;
    logic        [32-1:0] rq_a0_c           ;
    logic        [32-1:0] rq_a1_c           ;
    logic        [32-1:0] rq_oc0_c          ;
    logic        [32-1:0] rq_oc1_c          ;
    logic        [32-1:0] cap_i0_c          ;
    logic        [32-1:0] cap_i1_c          ;
    logic        [8-1:0]  x_bytes     [MAXC];
    logic signed [8-1:0]  w_lane      [P]   ;
    logic signed [8-1:0]  x_s               ;
    logic                 ld_active         ;
    logic        [16-1:0] ld_win_w          ;
    logic        [16-1:0] ld_end_row        ;
    logic        [16-1:0] ld_lastcol        ;
    logic        [32-1:0] slot_wsum         ;
    logic        [32-1:0] ws_next_c         ;
    logic        [16-1:0] oy_p1_c           ;
    logic        [8-1:0]  n_ic              ;
    logic        [8-1:0]  n_tap             ;
    logic        [2-1:0]  n_kx              ;
    logic        [2-1:0]  n_ky              ;
    logic        [32-1:0] lb_rd_addr        ;
    logic        [32-1:0] w_rd_word_c       ;
    // ---- weight write-port helpers (whole-word assembly, see wr_sh) -------
    logic        [32-1:0]      ld_word_c; // packed word the byte belongs to
    logic        [8-1:0]       ld_lane_c; // byte lane inside that word
    logic        [(8 * P)-1:0] wr_nx    ; // wr_sh merged with the new byte
    logic signed [8-1:0]       rq_y0    ;
    logic signed [8-1:0]       rq_y1    ;

    always_comb begin
        win_w_c    = (32'(c_stride)) * ((32'(c_tw)) - 1) + (32'(c_k));
        win_h_c    = (32'(c_stride)) * ((32'(c_th)) - 1) + (32'(c_k));
        k2_c       = (32'(c_k)) * (32'(c_k));
        np_c       = ((32'(c_out_c)) + (32'(P)) - 1) / (32'(P));
        ld_end_c   = (32'(c_stride)) * (32'(oy)) + (32'(c_k));
        u_tot_c    = (32'(c_th)) * (32'(c_tw)) * np_c;
        ld_win_w   = win_w_c[15:0];
        ld_end_row = ld_end_c[15:0];
        ld_lastcol = ld_win_w - 1;
        ld_active  = ld_row < ld_end_row;

        // ---- one-step read lookahead ----------------------------------
        // lb_rd / w_rd are registered read ports, so the address presented
        // now must already be the next MAC step's address.
        if (tps == T_MAC) begin
            if ((32'(ic)) + 1 < (32'(c_in_c))) begin
                n_ic  = ic + 1;
                n_tap = tap_c;
                n_kx  = kx;
                n_ky  = ky;
            end else if ((32'(kx)) + 1 < (32'(c_k))) begin
                n_ic  = 0;
                n_tap = tap_c + 1;
                n_kx  = kx + 1;
                n_ky  = ky;
            end else if ((32'(ky)) + 1 < (32'(c_k))) begin
                n_ic  = 0;
                n_tap = tap_c + 1;
                n_kx  = 0;
                n_ky  = ky + 1;
            end else begin
                // last MAC step of the unit: address is not consumed
                n_ic  = 0;
                n_tap = 0;
                n_kx  = kx;
                n_ky  = ky;
            end
        end else begin
            n_ic  = ic;
            n_tap = tap_c;
            n_kx  = kx;
            n_ky  = ky;
        end
        slot_sum = (32'(win_slot0)) + (32'(n_ky));
        if (slot_sum > 32'd2) begin
            cur_slot = slot_sum - 3;
        end else begin
            cur_slot = slot_sum;
        end
        lb_rd_addr  = cur_slot * (32'(W_LB)) + col_base + (32'(n_kx));
        w_rd_word_c = ((32'(n_ic)) * k2_c + (32'(n_tap))) * (32'(NPASS)) + (32'(blk));
        // next output row / next window slot, computed combinationally:
        // always_ff assignments are nonblocking, so anything read back in the
        // same cycle must come from here (registers in, wires out).
        oy_p1_c   = oy + 1;
        slot_wsum = (32'(win_slot0)) + (32'(c_stride));
        if (slot_wsum > 32'd2) begin
            ws_next_c = slot_wsum - 3;
        end else begin
            ws_next_c = slot_wsum;
        end

        if (u_mac[0]) begin
            acc_base = 32'(P);
        end else begin
            acc_base = 0;
        end
        if (u_rq[0]) begin
            rq_base = 32'(P);
        end else begin
            rq_base = 0;
        end

        rq_blk_c = b_blk[u_rq[0]];
        rq_ocb_c = (32'(rq_blk_c)) * (32'(P));
        if ((32'(c_out_c)) - rq_ocb_c > (32'(P))) begin
            rq_pe_c = 32'(P);
        end else begin
            rq_pe_c = (32'(c_out_c)) - rq_ocb_c;
        end
        rq_nc_c = (rq_pe_c + 1) / 2;

        rq_i0_c = (32'(drain_c)) * 2;
        rq_i1_c = rq_i0_c + 1;
        // clamp: feeds beyond p_eff are ignored but must stay in range
        if (rq_i0_c < (32'(P))) begin
            rq_a0_c = rq_base + rq_i0_c;
        end else begin
            rq_a0_c = rq_base;
        end
        if (rq_i1_c < (32'(P))) begin
            rq_a1_c = rq_base + rq_i1_c;
        end else begin
            rq_a1_c = rq_base;
        end
        rq_oc0_c = rq_ocb_c + rq_i0_c;
        rq_oc1_c = rq_ocb_c + rq_i1_c;
        cap_i0_c = (32'(drain_c)) * 2 - 4; // 2*(drain_c-2)
        cap_i1_c = cap_i0_c + 1;

        for (int c = 0; c < MAXC; c++) begin
            x_bytes[c] = lb_rd[8 * c+:8];
        end
        for (int j = 0; j < P; j++) begin
            w_lane[j]        = w_rd[8 * j+:8];
            y_data[8 * j+:8] = ybeat[j];
        end
        x_s = x_bytes[ic];

        y_oc_base = rq_ocb_c[7:0];
        y_cnt     = rq_pe_c[7:0];
        y_oy      = b_oy[u_rq[0]];
        y_ox      = b_ox[u_rq[0]];
        cfg_ready = !busy;
        x_ready   = ld_active && (state == S_LOAD);
        w_seq_err = w_err;
        x_hdr_err = x_err;
    end

    // ---- weight write port: whole-word assembly ---------------------------
    // The load contract is sequential, so the bytes of a packed word arrive in
    // ascending lane order and lane 0 is always the first byte of a word: a
    // lane-0 byte therefore starts a fresh shadow, every later byte merges into
    // it, and the RAM sees one full-word write per loaded byte.  Lanes that a
    // final partial block never fills stay 0; the compute side ignores them
    // (y_cnt / rq_pe_c clamp to the layer's real channel count).
    always_comb begin
        ld_word_c = (ld_t * (16'(NPASS))) + (ld_oc / (8'(P)));
        ld_lane_c = ld_oc % (8'(P));
        wr_nx     = wr_sh;
        if (w_we) begin
            if (ld_lane_c == 0) begin
                wr_nx = 0;
            end
            for (int j = 0; j < P; j++) begin
                if (ld_lane_c == (8'(j))) begin
                    wr_nx[8 * j+:8] = w_data;
                end
            end
        end
    end

    // ---- memory read ports + parameter load ports -------------------------
    // (no reset: these RAMs are filled through the load ports)
    always_ff @ (posedge clk) begin
        lb_rd <= lb[lb_rd_addr[LBW - 1:0]];
        w_rd  <= wr[w_rd_word_c[WW - 1:0]];
        wr_sh <= wr_nx;
        if (w_we) begin
            wr[ld_word_c[WW - 1:0]] <= wr_nx;
        end
        if (b_we) begin
            bram[b_addr] <= b_data;
        end
        if (m_we) begin
            mram[m_addr] <= m_data;
        end
    end

    // ---- shared requant: 2 frozen requant_unit, 2 values per cycle --------
    logic signed [ACC_W-1:0] rq_acc0; always_comb rq_acc0 = acc[rq_a0_c] + bram[rq_oc0_c[OCW - 1:0]];
    logic signed [ACC_W-1:0] rq_acc1; always_comb rq_acc1 = acc[rq_a1_c] + bram[rq_oc1_c[OCW - 1:0]];

    requant_unit #(
        .ACC_W   (ACC_W  ),
        .M0_W    (M0_W   ),
        .SHIFT_W (SHIFT_W)
    ) rq0 (
        .clk     (clk                      ),
        .acc_i   (rq_acc0                  ),
        .m0_i    (mram[rq_oc0_c[OCW - 1:0]]),
        .shift_i (c_shift                  ),
        .relu_i  (c_relu                   ),
        .y_o     (rq_y0                    )
    );

    requant_unit #(
        .ACC_W   (ACC_W  ),
        .M0_W    (M0_W   ),
        .SHIFT_W (SHIFT_W)
    ) rq1 (
        .clk     (clk                      ),
        .acc_i   (rq_acc1                  ),
        .m0_i    (mram[rq_oc1_c[OCW - 1:0]]),
        .shift_i (c_shift                  ),
        .relu_i  (c_relu                   ),
        .y_o     (rq_y1                    )
    );

    // ---- main FSM (MAC side + shared requant side, one clocked block) -----

    always_ff @ (posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            tps       <= T_WAIT;
            busy      <= 0;
            done      <= 0;
            w_err     <= 0;
            x_err     <= 0;
            ld_addr   <= 0;
            ld_t      <= 0;
            ld_oc     <= 0;
            ld_row    <= 0;
            ld_col    <= 0;
            ld_slot   <= 0;
            oy        <= 0;
            ox        <= 0;
            blk       <= 0;
            ky        <= 0;
            kx        <= 0;
            tap_c     <= 0;
            ic        <= 0;
            col_base  <= 0;
            win_slot0 <= 0;
            u_mac     <= 0;
            u_rq      <= 0;
            rq_state  <= RQ_IDLE;
            drain_c   <= 0;
            y_valid   <= 0;
            c_in_c    <= 0;
            c_out_c   <= 0;
            c_k       <= 0;
            c_stride  <= 0;
            c_relu    <= 0;
            c_shift   <= 0;
            c_ty0     <= 0;
            c_tx0     <= 0;
            c_th      <= 0;
            c_tw      <= 0;
            for (int i = 0; i < 2; i++) begin
                b_pend[i] <= 0;
                b_oy[i]   <= 0;
                b_ox[i]   <= 0;
                b_blk[i]  <= 0;
            end
            for (int i = 0; i < P; i++) begin
                ybeat[i]   <= 0;
                acc[i]     <= 0;
                acc[P + i] <= 0;
            end
        end else begin
            // ---- descriptor latch ------------------------------------------
            if (cfg_valid && cfg_ready) begin
                c_in_c   <= cfg_in_c;
                c_out_c  <= cfg_out_c;
                c_k      <= cfg_k;
                c_stride <= cfg_stride;
                c_relu   <= cfg_relu;
                c_shift  <= cfg_shift;
                c_ty0    <= tile_y0;
                c_tx0    <= tile_x0;
                c_th     <= tile_h;
                c_tw     <= tile_w;
            end

            // ---- sequential weight sweep -> packed words -------------------
            // The (tap, oc) split of a weight byte needs OUT_C, so the layer
            // descriptor must already be on the config bus when the first weight
            // byte arrives; a weight byte with no descriptor on the bus is
            // flagged sticky on w_seq_err instead of silently mis-packing.
            if (w_we) begin
                if (w_addr != ld_addr) begin
                    w_err <= 1;
                end
                if (cfg_out_c == 0) begin
                    w_err <= 1;
                end
                ld_addr <= ld_addr + 1;
                if (ld_oc == (cfg_out_c - 1)) begin
                    ld_oc <= 0;
                    ld_t  <= ld_t + 1;
                end else begin
                    ld_oc <= ld_oc + 1;
                end
            end

            // ---- MAC side --------------------------------------------------
            case (state) inside
                S_IDLE: begin
                    busy <= 0;
                    if (start) begin
                        done      <= 0;
                        ld_addr   <= 0;
                        ld_t      <= 0;
                        ld_oc     <= 0;
                        ld_row    <= 0;
                        ld_col    <= 0;
                        ld_slot   <= 0;
                        oy        <= 0;
                        ox        <= 0;
                        blk       <= 0;
                        ky        <= 0;
                        kx        <= 0;
                        tap_c     <= 0;
                        ic        <= 0;
                        col_base  <= 0;
                        win_slot0 <= 0;
                        u_mac     <= 0;
                        u_rq      <= 0;
                        rq_state  <= RQ_IDLE;
                        drain_c   <= 0;
                        for (int i = 0; i < 2; i++) begin
                            b_pend[i] <= 0;
                        end
                        if ((c_th == 0) || (c_tw == 0) || (c_out_c == 0)) begin
                            done  <= 1;
                            state <= S_IDLE;
                        end else begin
                            busy  <= 1;
                            state <= S_LOAD;
                        end
                    end
                end
                // fill the rows the current output row needs: [ld_row, S*oy+K)
                S_LOAD: begin
                    if (ld_active) begin
                        if (x_valid) begin
                            lb[ld_slot * (16'(W_LB)) + ld_col] <= x_pixel;
                            if ((!x_sof) && (ld_row == 0) && (ld_col == 0)) begin
                                x_err <= 1;
                            end
                            if ((x_eol == 0) && (ld_col == ld_lastcol)) begin
                                x_err <= 1;
                            end
                            if ((x_eol != 0) && (ld_col != ld_lastcol)) begin
                                x_err <= 1;
                            end
                            if (ld_col == ld_lastcol) begin
                                ld_col <= 0;
                                if (ld_slot == NSLOT_M1) begin
                                    ld_slot <= 0;
                                end else begin
                                    ld_slot <= ld_slot + 1;
                                end
                                ld_row <= ld_row + 1;
                            end else begin
                                ld_col <= ld_col + 1;
                            end
                        end
                    end else begin
                        ky    <= 0;
                        kx    <= 0;
                        tap_c <= 0;
                        ic    <= 0;
                        tps   <= T_WAIT;
                        state <= S_TAP;
                    end
                end
                // accumulate one unit = (oy, ox, blk)
                S_TAP: begin
                    case (tps) inside
                        T_WAIT: begin
                            // the accumulator bank is free when the unit that
                            // used it two units ago finished requantising
                            if (u_mac - u_rq < 32'd2) begin
                                for (int j = 0; j < P; j++) begin
                                    acc[acc_base + j] <= 0;
                                end
                                tps <= T_MAC;
                            end
                        end
                        T_MAC: begin
                            for (int j = 0; j < P; j++) begin
                                acc[acc_base + j] <= acc[acc_base + j] + x_s * w_lane[j];
                            end
                            if ((32'(ic)) + 1 < (32'(c_in_c))) begin
                                ic <= ic + 1;
                            end else if ((32'(kx)) + 1 < (32'(c_k))) begin
                                kx    <= kx + 1;
                                tap_c <= tap_c + 1;
                                ic    <= 0;
                            end else if ((32'(ky)) + 1 < (32'(c_k))) begin
                                kx    <= 0;
                                ky    <= ky + 1;
                                tap_c <= tap_c + 1;
                                ic    <= 0;
                            end else begin
                                tps <= T_END;
                            end
                        end
                        T_END: begin
                            // hand the frozen accumulator bank to the shared
                            // requant engine, then step to the next unit
                            b_pend[u_mac[0]] <= 1;
                            b_oy[u_mac[0]]   <= c_ty0 + oy;
                            b_ox[u_mac[0]]   <= c_tx0 + ox;
                            b_blk[u_mac[0]]  <= blk;
                            u_mac            <= u_mac + 1;
                            ky               <= 0;
                            kx               <= 0;
                            tap_c            <= 0;
                            ic               <= 0;
                            if ((32'(blk)) + 1 < np_c) begin
                                blk <= blk + 1;
                                tps <= T_WAIT;
                            end else begin
                                blk <= 0;
                                if ((32'(ox)) + 1 < (32'(c_tw))) begin
                                    ox       <= ox + 1;
                                    col_base <= col_base + (32'(c_stride));
                                    tps      <= T_WAIT;
                                end else begin
                                    ox        <= 0;
                                    col_base  <= 0;
                                    win_slot0 <= ws_next_c[7:0];
                                    oy        <= oy_p1_c;
                                    if (oy_p1_c == c_th) begin
                                        state <= S_DONE;
                                    end else begin
                                        state <= S_LOAD;
                                    end
                                end
                            end
                        end
                        default: begin
                            tps <= T_WAIT;
                        end
                    endcase
                end
                S_DONE: begin
                    busy <= 1;
                    if (u_rq == u_mac) begin
                        busy  <= 0;
                        done  <= 1;
                        state <= S_IDLE;
                    end
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase

            // ---- shared requant engine: 2 values/cycle ---------------------
            case (rq_state) inside
                RQ_IDLE: begin
                    y_valid <= 0;
                    if (u_mac > u_rq) begin
                        drain_c  <= 0;
                        rq_state <= RQ_DRAIN;
                    end
                end
                RQ_DRAIN: begin
                    // capture the pair whose 2-cycle pipeline just landed
                    if (drain_c > 8'd1) begin
                        if (cap_i0_c < rq_pe_c) begin
                            ybeat[cap_i0_c[7:0]] <= rq_y0;
                        end
                        if (cap_i1_c < rq_pe_c) begin
                            ybeat[cap_i1_c[7:0]] <= rq_y1;
                        end
                    end
                    if ((32'(drain_c)) > rq_nc_c) begin
                        y_valid  <= 1;
                        rq_state <= RQ_EMIT;
                    end else begin
                        drain_c <= drain_c + 1;
                    end
                end
                RQ_EMIT: begin
                    y_valid <= 1;
                    if (y_ready) begin
                        b_pend[u_rq[0]] <= 0;
                        u_rq            <= u_rq + 1;
                        y_valid         <= 0;
                        rq_state        <= RQ_IDLE;
                    end
                end
                default: begin
                    rq_state <= RQ_IDLE;
                end
            endcase
        end
    end
endmodule
