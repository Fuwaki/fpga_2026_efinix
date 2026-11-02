// st_dw.sv -- the ST block engine's DW stage: the 3x3 window, the depthwise
// convolution, the stem's im2col and the bypass path.
//
// Stream format (both sides): *_valid, *_ready, *_data[39:0] (4 lanes of
// 10-bit signed, lane j = bits [10j+9:10j]), *_last (last group beat of a
// pixel), *_eol (last beat of a line), *_sof (first beat of a frame).  A
// pixel is G = ceil(C/4) group beats, group 0 first, pixels in raster order;
// lanes beyond C are zero.
//
// Configuration is sampled on a one-cycle start pulse while idle; busy stays
// high until the last output beat has been accepted:
//
//   cfg_mode    0 DW, 1 IM2COL (the stem), 2 BYPASS
//   cfg_w/h     input grid, at least 2; even for stride 2
//   cfg_g       groups per pixel, 1..16 (line address = x*G + g)
//   cfg_stride  1 or 2: keep only output rows and columns with even yo/xo
//   cfg_dw_base DW ROM word of group 0, cfg_g words used
//   cfg_rq_base rq ROM word of channel 0, a multiple of 4
//   cfg_lo/hi   clamp of the requantisation lanes
//
// The sequencer that owns the pass table fills these from st_net_pkg, so
// nothing here looks the package up.
//
// ------------------------------------------------------------------ window
// Line storage: two st_line_ram instances (WORDS = 2560 group words of 40
// bit) used as a ping-pong store by row parity; row r is written into slot
// r%2.  Each instance is a 2048-word and a 512-word bank, 8 + 2 = 10 RAM10,
// so the line store is 2 x 10 = 20 RAM10 of 2560 x 40: Efinity rounds a
// non-power-of-two depth up, so one flat 2560-deep array would cost the
// 4096-deep shape, 20 RAM10 per instance.
//
// While input row r streams (r >= 1) every beat at address a reads slot
// (r-1)%2, which holds row r-1, and slot r%2, which holds row r-2 (garbage
// at r = 1, where the reflective top tap replaces it).  The incoming beat is
// written into slot r%2 one cycle behind the read of a; the read of the
// following beat already points at another address, so the read and write
// ports never meet.  Row 0 is only written and produces no output.
//
// The window beat for output row yo = r-1 is top = row r-2 (r = 1: the
// incoming row 1, the reflect), mid = row r-1, bot = the incoming row r.
// After the last input row the remaining output row H-1 is replayed: the
// addresses are walked again with no input, reading slot (H-2)%2 = row H-2
// and slot (H-1)%2 = row H-1, with top = row H-2, mid = row H-1 and bot =
// top (the bottom reflect).  A row tap is one 40-bit group word, so the
// three taps travel as one 120-bit column word.
//
// Columns: the three row taps feed a 120-bit column delay line in pixel
// steps, two shift registers of 32 entries (2 x 16 groups) with one
// asynchronous tap each.  The beat for (x, g) is the newest column; the
// entries G and 2G pushes older are columns x-1 and x-2 of the same group.
// Two copies, not one array with two read ports: the Titanium has no
// distributed RAM, so one array with two asynchronous reads becomes 3840
// flip-flops plus two 120-way read muxes, while a shift register with one tap
// per copy becomes SRL8 cells (3840 FF + 3046 LUT against 960 SRL8 + 486
// LUT, measured with the probe).
//
// Column x emits output column xo = x-1 from columns x-2, x-1 and x, with
// the reflect at xo = 0 taking the left column from the newest beat.  After
// the last column W-1 of a row the G flush beats of xo = W-1 are replayed
// from the delay line, with left = right = column W-2 (the right reflect).
// A row therefore costs W*G input beats plus G flush beats and yields W*G
// window beats.
//
// ---------------------------------------------------------------- datapath
// DW: per window beat and lane j (channel c = 4g + j)
//   acc_j = sum(ky, kx) win[ky][kx][j] * w[j*9 + ky*3 + kx] + bias_j
// with the 288-bit DW ROM word cfg_dw_base + g, and the bias, mantissa and
// shift of channel c from rq word cfg_rq_base + 4g + j (st_rq_rom, four
// banks); then four st_requant lanes (XW = 25) clamped to cfg_lo..cfg_hi.
// The 36 products are 10-bit signed x 8-bit signed -- one DSP block each on
// the Ti60, whose multipliers take 18-bit operands -- with registered
// operands and a 2-stage adder tree (three kernel-row sums, then those plus
// the bias): 36 DSP, plus four per XW = 25 requant lane (measured, see the
// ADR), 52 in all.
//
// IM2COL (C = 3, G = 1, the stem): 7 output beats per window beat, no
// requantisation.  Lane j of beat b is element n = 4b + j of
// v[n] = win[ky][kx][ic], n = ic*9 + ky*3 + kx, the PW ROM lane order of
// st_gen_params.rom_inputs; n = 27 is zero, and last is on beat 6.
//
// BYPASS: the input beat goes straight to the output with its flags.
//
// ------------------------------------------------------- latency and flow
// A window beat accepted in cycle t reaches the FIFO in cycle t + 11:
//
//   t        A  accept; the line address goes to both RAMs, the weight ROM
//               address is presented
//   t+1      B  line RAM and weight ROM data, row taps, column delay line
//   t+2      C  registered window and weight word
//   t+3         the 36 products
//   t+4         three kernel-row sums
//   t+5         the biased accumulators; the rq ROM (addressed at t+3, three
//               cycles behind the window) supplies the bias in this cycle
//   t+6..t+11   the four requant lanes (LAT = 6)
//
// The rq word is only needed from t+5 on, so its ROM read is held back three
// cycles instead of the 55-bit word riding down the pipeline: the ROM's own
// output register lands the bias on the accumulator, and one 24+6-bit
// register per lane carries mantissa and shift to the lanes.
//
// IM2COL registers the window at C too and emits its 7 beats on the seven
// cycles after C, so it takes one window beat every 8 cycles -- the stem's 8
// cycles per pixel.
//
// Back-pressure is a credit scheme, not a stalling pipeline: the 64-beat
// output FIFO sits after the datapath, and a window, flush or replay beat
// may enter stage A only when fifo_free - inflight >= the beats it will
// produce (1 for DW, 7 for IM2COL).  Beats that produce nothing (row 0, and
// the odd rows and columns of stride 2) need no credit, but they still fill
// the line store and the column delay line.  The pipeline itself never
// stalls; its valid bits just advance.  in_ready is high only when the
// window logic accepts a beat in that cycle.
module st_dw (
    input  logic               clk,
    input  logic               rst_n,

    // configuration, sampled on start
    input  logic               start,
    output logic               busy,
    input  logic        [1:0]  cfg_mode,
    input  logic        [9:0]  cfg_w,
    input  logic        [9:0]  cfg_h,
    input  logic        [4:0]  cfg_g,
    input  logic        [1:0]  cfg_stride,
    input  logic        [9:0]  cfg_dw_base,
    input  logic        [10:0] cfg_rq_base,
    input  logic signed [9:0]  cfg_lo,
    input  logic signed [9:0]  cfg_hi,

    // input stream
    input  logic               in_valid,
    output logic               in_ready,
    input  logic        [39:0] in_data,
    input  logic               in_last,
    input  logic               in_eol,
    input  logic               in_sof,

    // output stream
    output logic               out_valid,
    input  logic               out_ready,
    output logic        [39:0] out_data,
    output logic               out_last,
    output logic               out_eol,
    output logic               out_sof
);
    localparam int LINE_WORDS = 2560;      // 40-bit group words per line
    localparam int DLINE      = 32;        // 2 x 16 groups of column delay
    localparam int FIFO_DEPTH = 64;        // output beats
    localparam int FIFO_W     = 43;        // 40 data + last/eol/sof
    localparam int RQ_BANKS   = 4;         // DW channels per rq ROM word
    localparam int RQ_DEPTH   = 512;       // words per rq bank (1496 in all)
    localparam int DW_DEPTH   = 256;       // DW ROM words (180 in all)

    localparam logic [1:0] MODE_DW     = 2'd0;
    localparam logic [1:0] MODE_IM2COL = 2'd1;
    localparam logic [1:0] MODE_BYPASS = 2'd2;

    // sequencer states
    localparam logic [2:0] ST_IDLE   = 3'd0;
    localparam logic [2:0] ST_RUN    = 3'd1;   // input row `row` streams
    localparam logic [2:0] ST_FLUSH  = 3'd2;   // the G flush beats of xo = W-1
    localparam logic [2:0] ST_REPLAY = 3'd3;   // output row H-1, no input
    localparam logic [2:0] ST_DRAIN  = 3'd4;   // wait for the last beat out

    // what a flush is followed by
    localparam logic [1:0] FN_NEXT   = 2'd0;   // the next input row
    localparam logic [1:0] FN_REPLAY = 2'd1;   // output row H-1
    localparam logic [1:0] FN_DRAIN  = 2'd2;

    // ------------------------------------------------------ configuration
    logic [1:0]  mode;
    logic [9:0]  cw, ch;
    logic [4:0]  cg;
    logic [1:0]  cstride;
    logic [7:0]  dwb;
    logic [10:0] rqb;
    logic signed [9:0] clo, chi;
    logic [2:0]  state;
    logic [1:0]  fnext;
    logic        rep_sel;                  // 1 while replaying row H-1

    // position of the next beat to issue
    logic [9:0]  row, col;
    logic [4:0]  grp;
    logic [3:0]  icool;
    logic [7:0]  inflight;                 // beats promised by the pipeline

    // ------------------------------------------------------------ ROMs
    logic [7:0]   dw_addr;
    logic [287:0] dw_dout;
    logic [8:0]   rq_addr;
    logic [RQ_BANKS-1:0][63:0] rq_dout;
    logic [2:0][4:0] gpipe;                // the issued group, 1..3 cycles back

    // The rq word is needed twice, late: the accumulator stage wants its
    // bias and the requant lanes one stage after that want its mantissa and
    // shift.  The address therefore runs three cycles behind the window, so
    // the ROM's own output register lands the word on the bias adder, and
    // one 30-bit register per lane carries mant/k on to the lanes.  That
    // replaces the four 55-bit copies of the word that used to travel the
    // pipeline.  The conveyor shifts every cycle, like the valid bits it
    // travels beside: a beat issued in cycle t is in the accumulator stage
    // in cycle t+4, and the ROM read of its group is then four cycles old.
    always_ff @(posedge clk)
        gpipe <= {gpipe[1:0], grp};

    st_dw_rom #(.DEPTH(DW_DEPTH)) u_dw_rom (
        .clk  (clk),
        .addr (dw_addr),
        .dout (dw_dout)
    );

    st_rq_rom #(.NB(RQ_BANKS), .DEPTH(RQ_DEPTH)) u_rq_rom (
        .clk  (clk),
        .addr (rq_addr),
        .dout (rq_dout)
    );

    // ---------------------------------------------------- line store (2 x)
    logic [11:0] ra;                       // read address, stage A
    logic [11:0] dly_addr;                 // write address, one cycle later
    logic [39:0] dly_data;
    logic        dly_slot, dly_we;
    logic [39:0] ram0_dout, ram1_dout;

    st_line_ram #(.WORDS(LINE_WORDS)) u_line0 (
        .clk   (clk),
        .we    (dly_we && !dly_slot),
        .waddr (dly_addr),
        .wdata (dly_data),
        .raddr (ra),
        .rdata (ram0_dout)
    );

    st_line_ram #(.WORDS(LINE_WORDS)) u_line1 (
        .clk   (clk),
        .we    (dly_we && dly_slot),
        .waddr (dly_addr),
        .wdata (dly_data),
        .raddr (ra),
        .rdata (ram1_dout)
    );

    // ------------------------------------------------------- output FIFO
    logic        fifo_we;
    logic [42:0] fifo_wdata;
    logic        fifo_full;
    logic [6:0]  fifo_level;
    logic [42:0] fifo_rdata;

    fifo_sync_core #(.W(FIFO_W), .DEPTH(FIFO_DEPTH)) u_fifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .wen    (fifo_we),
        .wdata  (fifo_wdata),
        .wfull  (fifo_full),
        .rready (out_ready),
        .rvalid (out_valid),
        .rdata  (fifo_rdata),
        .level  (fifo_level)
    );

    assign out_data = fifo_rdata[39:0];
    assign out_last = fifo_rdata[40];
    assign out_eol  = fifo_rdata[41];
    assign out_sof  = fifo_rdata[42];

    // ------------------------------------------------ issue (stage A)
    wire win_mode = (mode != MODE_BYPASS);

    // Row r carries output row yo = r-1 and column x output column xo = x-1;
    // a row or column is emitted when its output index is even (stride 2).
    // Row 0 and column 0 are the reflect margins: stored, never emitted.
    wire row_kept = (cstride == 2'd1) || row[0];
    wire col_kept = (cstride == 2'd1) || col[0];
    wire run_lane = win_mode ? ((row != 10'd0) && (col != 10'd0) &&
                                row_kept && col_kept)
                             : 1'b1;
    wire rep_lane = (col != 10'd0) && row_kept && col_kept;

    logic       emit_beat;
    logic [7:0] produce;
    always_comb begin
        case (state)
            ST_RUN:    emit_beat = run_lane;
            ST_REPLAY: emit_beat = rep_lane;
            ST_FLUSH:  emit_beat = win_mode;
            default:   emit_beat = 1'b0;
        endcase
        produce = (emit_beat && (mode == MODE_IM2COL)) ? 8'd7 : {7'd0, emit_beat};
    end

    // Credit: the FIFO's contents plus everything still inside the pipeline
    // must fit together with the beats the next issue will produce.  level
    // does not count the word presented on rdata, hence the out_valid term.
    wire [7:0] fifo_occ = fifo_level + {7'd0, out_valid};
    wire [7:0] used     = fifo_occ + inflight;
    wire       cred_ok  = (produce == 8'd0) ||
                          (used + produce <= 8'(FIFO_DEPTH));

    // IM2COL emits 7 beats over the 7 cycles after stage C, so an issue is
    // followed by 7 idle cycles: period 8, the stem's 8 cycles per pixel.
    wire chan_ok = (mode != MODE_IM2COL) || (icool == 4'd0);

    wire accept_ok = chan_ok && cred_ok && !fifo_full;
    wire run_go    = (state == ST_RUN)    && in_valid && accept_ok;
    wire rep_go    = (state == ST_REPLAY) && accept_ok;
    wire flush_go  = (state == ST_FLUSH)  && accept_ok;
    wire beat_go   = run_go || rep_go;             // a window beat
    wire issue     = beat_go || flush_go;          // a beat enters stage B

    assign in_ready = (state == ST_RUN) && accept_ok;

    wire [11:0] addr_a    = 12'(col) * 12'(cg) + 12'(grp);
    wire        beat_last = (col == cw - 10'd1) && (grp == cg - 5'd1);
    wire [9:0]  col_nxt   = (col == cw - 10'd1) ? 10'd0 : col + 10'd1;
    wire [4:0]  grp_nxt   = (grp == cg - 5'd1) ? 5'd0 : grp + 5'd1;

    assign ra      = addr_a;
    assign dw_addr = dwb + 8'(grp);
    // rq words of the group: cfg_rq_base + 4g, an NB-aligned word address.
    // The read runs three cycles behind the window, hence gpipe[2].
    assign rq_addr = 9'((rqb + {4'd0, gpipe[2], 2'b00}) >> 2);

    // Flags of the emitted beat.  A flush beat is column W-1, so the last
    // group of the flush ends the output line; stride 2 has no flush, and
    // its last emitted input column W-1 ends the line.
    wire f_last = (grp == cg - 5'd1);
    wire f_eol  = f_last && ((state == ST_FLUSH) ||
                             ((cstride == 2'd2) && (col == cw - 10'd1)));
    wire f_sof  = run_go && (row == 10'd1) && (col == 10'd1) && (grp == 5'd0);

    // --------------------------------------------- stage B: the window
    logic [39:0] b_data;
    logic        b_push, b_emit, b_flush, b_left_ref, b_top_ref, b_bot_ref;
    logic        b_slot, b_last, b_eol, b_sof;
    logic [4:0]  b_grp;                    // group of the window beat

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_emit <= 1'b0;
            b_push <= 1'b0;
        end else begin
            b_emit <= issue && emit_beat && win_mode;
            b_push <= beat_go && win_mode;
        end
    end

    always_ff @(posedge clk) begin
        if (issue) begin
            b_flush    <= (state == ST_FLUSH);
            b_left_ref <= (col == 10'd1) && (state != ST_FLUSH);
            b_top_ref  <= run_go && (row == 10'd1);
            b_bot_ref  <= rep_go;
            b_slot     <= row[0] ^ rep_sel;
            b_grp      <= grp;
            b_data     <= in_data;
            b_last     <= f_last;
            b_eol      <= f_eol;
            b_sof      <= f_sof;
        end
    end

    wire [39:0] tap_top = b_slot ? ram1_dout : ram0_dout;
    wire [39:0] tap_mid = b_slot ? ram0_dout : ram1_dout;

    wire [39:0]  b_bot   = b_bot_ref ? tap_top : b_data;
    wire [39:0]  b_top   = b_top_ref ? b_data : tap_top;
    wire [119:0] tri_new = {b_top, tap_mid, b_bot};

    // Column delay line: two shift registers of 32 column words, the newest
    // at entry 0 and one push per entry, so entry k holds the beat pushed k
    // pushes ago.  The taps are G and 2G pushes behind the newest beat; a
    // flush beat reads G - g and 2G - g behind it, which are the entries of
    // columns W-1 and W-2 of group g (the line does not shift during a
    // flush).  Both offsets are at most 2G <= 32, so the read index is
    // offset - 1 and never leaves the array.
    //
    // Two copies rather than one array with two read ports: the Titanium has
    // no distributed RAM, so an array with two asynchronous reads is 3840
    // flip-flops plus two read muxes (measured: 3840 FF, 3046 LUT), while a
    // shift register with one asynchronous tap per copy maps to SRL8 cells
    // (measured: 960 SRL8, 486 LUT).
    logic [DLINE-1:0][119:0] dl_m, dl_lr;

    always_ff @(posedge clk) begin
        if (b_push) begin
            dl_m  <= {dl_m[DLINE-2:0], tri_new};
            dl_lr <= {dl_lr[DLINE-2:0], tri_new};
        end
    end

    wire [5:0] off_m   = b_flush ? (6'(cg) - 6'(b_grp)) : 6'(cg);
    wire [5:0] off_lr  = b_flush ? (6'(cg) * 6'd2 - 6'(b_grp)) : 6'(cg) * 6'd2;
    wire [4:0] idx_m   = 5'(off_m - 6'd1);
    wire [4:0] idx_lr  = 5'(off_lr - 6'd1);
    wire [119:0] tap_m  = dl_m[idx_m];
    wire [119:0] tap_lr = dl_lr[idx_lr];

    wire [119:0] col_l = b_left_ref ? tri_new : tap_lr;
    wire [119:0] col_m = tap_m;
    wire [119:0] col_r = b_flush ? tap_lr : tri_new;

    // The 9 window words, tap t = ky*3 + kx in the ROM's byte order; the top
    // row tap is bits [119:80] of a column word.
    wire [359:0] win;
    for (genvar t = 0; t < 9; t++) begin : g_win
        localparam int RW = 2 - t / 3;
        assign win[40*t +: 40] = ((t % 3) == 0) ? col_l[40*RW +: 40] :
                                 ((t % 3) == 1) ? col_m[40*RW +: 40] :
                                                  col_r[40*RW +: 40];
    end

    // --------------------------------- stage C: registered window, ROM data
    // The line RAMs and the ROMs are read in stage A, so their outputs in
    // stage B's cycle already belong to the beat being windowed, and stage C
    // captures window, weight word and rq words together.
    logic [359:0] win_c;
    logic [287:0] wgt_c;
    logic         c_dw_vld, c_im_vld;
    logic [2:0]   c_dw_flags;
    logic         c_im_eol, c_im_sof;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_dw_vld <= 1'b0;
            c_im_vld <= 1'b0;
        end else begin
            c_dw_vld <= b_emit && (mode == MODE_DW);
            c_im_vld <= b_emit && (mode == MODE_IM2COL);
        end
    end

    always_ff @(posedge clk) begin
        if (b_emit) begin
            win_c   <= win;
            wgt_c   <= dw_dout;
            c_dw_flags <= {b_sof, b_eol, b_last};
            c_im_eol   <= b_eol;
            c_im_sof   <= b_sof;
        end
    end

    // ----------------------------------------------------- DW: 36 products
    logic signed [17:0] prod [4][9];
    logic signed [24:0] rowsum [4][3];
    logic signed [24:0] acc [4];
    logic        d_vld, e_vld, f_vld;
    logic [2:0]  d_flags, e_flags, f_flags;

    // The rq word the lanes need, captured one stage after the ROM read: the
    // ROM address lags the window by three stages (g3), so rq_dout holds the
    // word of the beat in the accumulator stage and its bias is added there,
    // while this register holds mant/k for the lanes one stage later.
    logic [23:0] rq_mant [4];
    logic [5:0]  rq_k [4];

    always_ff @(posedge clk) begin
        for (int j = 0; j < 4; j++) begin
            if (e_vld) begin
                rq_k[j]    <= rq_dout[j][61:56];
                rq_mant[j] <= rq_dout[j][55:32];
            end
        end
    end

    always_ff @(posedge clk) begin
        for (int j = 0; j < 4; j++) begin
            for (int t = 0; t < 9; t++) begin
                if (c_dw_vld)
                    prod[j][t] <= $signed(win_c[40*t + 10*j +: 10]) *
                                  $signed(wgt_c[8*(9*j + t) +: 8]);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_vld <= 1'b0;
            e_vld <= 1'b0;
            f_vld <= 1'b0;
        end else begin
            d_vld   <= c_dw_vld;
            e_vld   <= d_vld;
            f_vld   <= e_vld;
            d_flags <= c_dw_flags;
            e_flags <= d_flags;
            f_flags <= e_flags;
        end
    end

    // 2-stage adder tree: three kernel-row sums, then those plus the bias.
    // The products are sign-extended first: a sum of three 18-bit products
    // does not fit 18 bits.  The bias is bits [24:0] of the rq word, which
    // hold its value as |bias| < 2**15 (bit 24 is its sign either way).
    always_ff @(posedge clk) begin
        for (int j = 0; j < 4; j++) begin
            for (int ky = 0; ky < 3; ky++) begin
                if (d_vld)
                    rowsum[j][ky] <= {{7{prod[j][3*ky][17]}},   prod[j][3*ky]} +
                                     {{7{prod[j][3*ky+1][17]}}, prod[j][3*ky+1]} +
                                     {{7{prod[j][3*ky+2][17]}}, prod[j][3*ky+2]};
            end
            if (e_vld)
                acc[j] <= rowsum[j][0] + rowsum[j][1] + rowsum[j][2] +
                          $signed(rq_dout[j][24:0]);
        end
    end

    // ------------------------------------------------- DW: 4 requant lanes
    logic signed [9:0] rq_y [4];
    logic [3:0]      rq_lane_vld;          // the lanes are in lockstep
    logic [3:0][2:0] rq_lane_tag;          // ... and so are their flags

    for (genvar j = 0; j < 4; j++) begin : g_rq
        st_requant #(.XW(25), .TW(3)) u_requant (
            .clk       (clk),
            .rst_n     (rst_n),
            .in_valid  (f_vld),
            .in_x      (acc[j]),
            .in_mant   (rq_mant[j]),
            .in_k      (rq_k[j]),
            .in_lo     (clo),
            .in_hi     (chi),
            .in_tag    (f_flags),
            .out_valid (rq_lane_vld[j]),
            .out_y     (rq_y[j]),
            .out_tag   (rq_lane_tag[j])
        );
    end

    wire rq_vld = rq_lane_vld[0];

    // The lanes are identical pipelines fed by one valid bit and one tag, so
    // they must agree; a disagreement means the datapath lost a beat.  The
    // check watches a registered copy of the reset, so it never looks at the
    // first edge, whose sampled values predate the asynchronous reset.
    logic rst_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_q <= 1'b0;
        else        rst_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst_q && rq_lane_vld[0] && (rq_lane_vld != {4{rq_lane_vld[0]}}))
            $error("st_dw: requant lanes disagree on valid");
        if (rst_q && rq_lane_vld[0] && (rq_lane_tag != {4{rq_lane_tag[0]}}))
            $error("st_dw: requant lanes disagree on their flags");
    end

    // ------------------------------------------------------ IM2COL emitter
    // v[n] = win[ky][kx][ic], n = ic*9 + ky*3 + kx; n = 27 and up are zero,
    // so the beat index may run past 6 without leaving the array.
    wire [319:0] im_el;
    for (genvar n = 0; n < 27; n++) begin : g_el
        assign im_el[10*n +: 10] = win_c[40*(n % 9) + 10*(n / 9) +: 10];
    end
    for (genvar n = 27; n < 32; n++) begin : g_el0
        assign im_el[10*n +: 10] = 10'd0;
    end

    logic [2:0] icnt;
    logic       irun;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irun <= 1'b0;
            icnt <= 3'd0;
        end else if (c_im_vld) begin
            irun <= 1'b1;
            icnt <= 3'd0;
        end else if (irun) begin
            if (icnt == 3'd6)
                irun <= 1'b0;
            icnt <= icnt + 3'd1;
        end
    end

    wire [39:0] im_beat = {im_el[10*(4*icnt + 3) +: 10], im_el[10*(4*icnt + 2) +: 10],
                           im_el[10*(4*icnt + 1) +: 10], im_el[10*(4*icnt + 0) +: 10]};
    wire        im_last = (icnt == 3'd6);
    wire        im_eol  = im_last && c_im_eol;
    wire        im_sof  = (icnt == 3'd0) && c_im_sof;

    // ------------------------------------------------------- output select
    always_comb begin
        case (mode)
            MODE_BYPASS: begin
                fifo_we    = run_go;
                fifo_wdata = {in_sof, in_eol, in_last, in_data};
            end
            MODE_IM2COL: begin
                fifo_we    = irun;
                fifo_wdata = {im_sof, im_eol, im_last, im_beat};
            end
            default: begin
                fifo_we    = rq_vld;
                fifo_wdata = {rq_lane_tag[0], rq_y[3], rq_y[2], rq_y[1], rq_y[0]};
            end
        endcase
    end

    // --------------------------------------------------------- sequencer
    wire drained = !out_valid && (fifo_level == 7'd0) && (inflight == 8'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            busy     <= 1'b0;
            mode     <= MODE_DW;
            cw       <= 10'd2;
            ch       <= 10'd2;
            cg       <= 5'd1;
            cstride  <= 2'd1;
            dwb      <= 8'd0;
            rqb      <= 11'd0;
            clo      <= 10'sd0;
            chi      <= 10'sd127;
            fnext    <= FN_NEXT;
            rep_sel  <= 1'b0;
            row      <= 10'd0;
            col      <= 10'd0;
            grp      <= 5'd0;
            icool    <= 4'd0;
            inflight <= 8'd0;
            dly_we   <= 1'b0;
            dly_slot <= 1'b0;
            dly_addr <= 12'd0;
            dly_data <= 40'd0;
        end else if (start && (state == ST_IDLE)) begin
            mode     <= cfg_mode;
            cw       <= cfg_w;
            ch       <= cfg_h;
            cg       <= cfg_g;
            cstride  <= cfg_stride;
            dwb      <= cfg_dw_base[7:0];
            rqb      <= cfg_rq_base;
            clo      <= cfg_lo;
            chi      <= cfg_hi;
            busy     <= 1'b1;
            state    <= ST_RUN;
            row      <= 10'd0;
            col      <= 10'd0;
            grp      <= 5'd0;
            icool    <= 4'd0;
            inflight <= 8'd0;
            rep_sel  <= 1'b0;
            dly_we   <= 1'b0;
            if (cfg_w < 10'd2 || cfg_h < 10'd2)
                $error("st_dw: cfg_w and cfg_h must be at least 2");
            if (cfg_g < 5'd1 || cfg_g > 5'd16)
                $error("st_dw: cfg_g must be 1..16");
            if (cfg_mode == MODE_IM2COL && cfg_g != 5'd1)
                $error("st_dw: im2col needs cfg_g = 1 (the stem has 3 channels)");
            if (cfg_mode != MODE_BYPASS &&
                int'(cfg_w) * int'(cfg_g) > LINE_WORDS)
                $error("st_dw: cfg_w * cfg_g exceeds the line store");
            if (int'(cfg_dw_base) + int'(cfg_g) > DW_DEPTH)
                $error("st_dw: cfg_dw_base + cfg_g exceeds the DW ROM");
            if (cfg_rq_base[1:0] != 2'd0)
                $error("st_dw: cfg_rq_base must be a multiple of 4");
            if (int'(cfg_rq_base) + 4 * int'(cfg_g) > RQ_BANKS * RQ_DEPTH)
                $error("st_dw: cfg_rq_base + 4*cfg_g exceeds the rq ROM");
            if (cfg_stride == 2'd2 && (cfg_w[0] || cfg_h[0]))
                $error("st_dw: stride 2 needs even cfg_w and cfg_h");
        end else begin
            // credits: an issue promises beats, a FIFO write delivers one
            inflight <= inflight + (issue ? produce : 8'd0) - (fifo_we ? 8'd1 : 8'd0);

            if (mode == MODE_IM2COL && issue)
                icool <= 4'd7;
            else if (icool != 4'd0)
                icool <= icool - 4'd1;

            // the line write, one cycle behind the read of the same beat
            dly_we <= run_go && win_mode;
            if (run_go) begin
                dly_slot <= row[0];
                dly_addr <= addr_a;
                dly_data <= in_data;
                // the stream's own flags must describe this beat grid
                if (in_last !== (grp == cg - 5'd1) ||
                    in_eol  !== (in_last && (col == cw - 10'd1))) begin
                    $error("st_dw: input flags disagree with the beat position");
                end
                if ((row == 10'd0) && (col == 10'd0) && (grp == 5'd0) && !in_sof)
                    $error("st_dw: the first input beat is not marked sof");
            end

            case (state)
                ST_RUN: begin
                    if (run_go) begin
                        if (grp == cg - 5'd1) begin
                            grp <= 5'd0;
                            col <= col_nxt;
                        end else begin
                            grp <= grp_nxt;
                        end
                        if (beat_last) begin
                            if (mode == MODE_BYPASS) begin
                                // straight through: no window, so a row end
                                // is just the next row, and only the frame's
                                // last beat ends the pass
                                if (row == ch - 10'd1) begin
                                    state <= ST_DRAIN;
                                end else begin
                                    row <= row + 10'd1;
                                    col <= 10'd0;
                                    grp <= 5'd0;
                                end
                            end else if ((row == 10'd0) || (cstride == 2'd2)) begin
                                // no flush: row 0 carries no output row, and
                                // stride 2 drops the last input row's window
                                if (row == ch - 10'd1) begin
                                    state <= ST_DRAIN;
                                end else begin
                                    row <= row + 10'd1;
                                    col <= 10'd0;
                                    grp <= 5'd0;
                                end
                            end else begin
                                // the last column flushes from the delay line;
                                // after the last input row the output row H-1
                                // still remains
                                state <= ST_FLUSH;
                                fnext <= (row == ch - 10'd1) ? FN_REPLAY : FN_NEXT;
                                col   <= cw - 10'd1;
                                grp   <= 5'd0;
                            end
                        end
                    end
                end
                ST_FLUSH: begin
                    if (flush_go) begin
                        if (grp == cg - 5'd1) begin
                            grp <= 5'd0;
                            case (fnext)
                                FN_NEXT: begin
                                    row   <= row + 10'd1;
                                    col   <= 10'd0;
                                    state <= ST_RUN;
                                end
                                FN_REPLAY: begin
                                    col     <= 10'd0;
                                    rep_sel <= 1'b1;
                                    state   <= ST_REPLAY;
                                end
                                default: begin
                                    state <= ST_DRAIN;
                                end
                            endcase
                        end else begin
                            grp <= grp + 5'd1;
                        end
                    end
                end
                ST_REPLAY: begin
                    if (rep_go) begin
                        if (grp == cg - 5'd1) begin
                            grp <= 5'd0;
                            col <= col_nxt;
                        end else begin
                            grp <= grp_nxt;
                        end
                        if (beat_last) begin
                            if (cstride == 2'd1) begin
                                state <= ST_FLUSH;     // xo = W-1 of row H-1
                                fnext <= FN_DRAIN;
                                col   <= cw - 10'd1;
                            end else begin
                                state <= ST_DRAIN;
                            end
                        end
                    end
                end
                ST_DRAIN: begin
                    if (drained) begin
                        busy  <= 1'b0;
                        state <= ST_IDLE;
                    end
                end
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // ------------------------------------------------------- static checks
    initial begin
        if ((1 << $clog2(FIFO_DEPTH)) != FIFO_DEPTH || FIFO_DEPTH < 8)
            $error("st_dw: FIFO_DEPTH must be a power of two, at least 8");
        if (DLINE != 32)
            $error("st_dw: the column delay line is 2 x 16 groups deep");
        if (RQ_BANKS != 4)
            $error("st_dw: the DW rq ROM has four banks");
        if (LINE_WORDS != 2560)
            $error("st_dw: one line is 2560 group words (2 x 10 RAM10)");
    end

endmodule
