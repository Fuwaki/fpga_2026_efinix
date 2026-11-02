// st_pre.sv -- pass 0 (pre): ISP slot RGB565 -> the guided net's p0 codes.
//
// Input: the whole ISP frame, straight from tile_dma_rd.  160 beats per line
// (1280 px, 8 px per 128-bit beat), 720 lines; beat xb of line y carries
// source pixels 8*xb .. 8*xb+7, pixel 0 in bits [15:0].  sof must be on beat
// 0 of line 0 and eol on beat 159 of every line; anything else sets the
// sticky err.
//
// Output: the engine's group stream, one beat per pixel, lanes 0..2 = the R,
// G, B code in a 10-bit lane, lane 3 zero, last on every beat, eol on the
// last pixel of an output line, sof on the first pixel of the frame:
//
//   cfg_pool = 0 (FULL): 640x360, code = LUT[(2x2 box of RGB8 + 2) >> 2]
//   cfg_pool = 1 (POOL): 320x180, code = (2x2 box of the p0 codes + 2) >> 2
//
// That is st_guided.pre() followed by Net.quantize_input, and
// st_guided.pool_int() of those p0 codes.  The 2x2 box of RGB8 is the sum of
// four vid_pkg::unpack565 values, avg = (sum + 2) >> 2 (sum <= 1020, so
// avg <= 255); the LUT is the 256-entry point-0 quantiser that
// tools/st_gen_prelut.py writes.  POOL sums p0 codes, so its fields are
// unsigned 9 bit (the guided net's codes are 0..127).
//
// Structure.  Source lines pair up: line 2r fills the pair-sum row, line
// 2r+1 completes the boxes and emits code row r.
//
//   * pair RAM, 160 words x 108 bits: four output columns x three channels x
//     9 bits.  Beat xb covers output columns 4xb .. 4xb+3, column k being
//     source pixels 8xb+2k, 8xb+2k+1.  An even line writes its beat's four
//     horizontal pair sums to word xb, one beat per cycle; an odd line adds
//     the beat's own pair sums to the word read for it, giving four box sums.
//     The read is issued on the accept of the *previous* beat with the
//     address of the next one, so the word is in the read register when the
//     beat arrives and stays there across input gaps.
//   * the four box sums (4 x 3 x 10 bits) are held while the emitter looks
//     one column per cycle up in the LUT (three copies, one per channel) and
//     writes the output register.  An odd-line beat is accepted only once
//     the previous one's four columns have been issued, so an odd line runs
//     4 cycles per beat: 160 + 640 cycles per source line pair, 288k cycles
//     per frame plus the odd lines' drain (measured 291 024, both modes).
//   * POOL adds a pool row RAM of 320 words x 27 bits (3 channels x 9 bits).
//     Code columns arrive one per cycle; columns 2k and 2k+1 of a code row
//     are summed (2k is held in a register).  Even rows write the pair sum
//     to word k, odd rows add word k and emit (s + 2) >> 2 as pixel
//     (k, r/2), one pixel per two columns.  Pairs never straddle a beat
//     (4 columns per beat) or a code row (640 columns), so the hold register
//     is always empty at both boundaries.
//
// Back-pressure: the output register holds a beat until it is accepted,
// which stalls the column emitter, which stalls input acceptance.  An even
// source line emits nothing of its own, so it only waits for the odd line
// before it to finish.
//
// Resources: pair RAM 160 x 108 (3 RAM10 at 256x40), pool RAM 320 x 27
// (2 RAM10 at 512x20), LUT 3 x 256 x 8 (3 RAM10).  No multiplier: the box
// average is a shift and the LUT is a ROM.
module st_pre
    import vid_pkg::*;
#(
    parameter int SRC_W = 1280,              // frame width, pixels
    parameter int SRC_H = 720,               // frame height, lines
    parameter string LUT_FILE = "./rtl/st_accel_new/gen/guided/st_pre_lut.hex"
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         start,              // one cycle, while idle
    input  logic         cfg_pool,           // sampled on start: 0 FULL, 1 POOL
    output logic         busy,               // until the last output beat is accepted
    output logic         err,                // input framing mismatch, sticky

    // Source: the ISP frame as AXI beats, sof/eol per line.
    input  logic         in_valid,
    output logic         in_ready,
    input  logic [127:0] in_data,
    input  logic         in_sof,
    input  logic         in_eol,

    // Results: the group stream, one beat per pixel.
    output logic         out_valid,
    input  logic         out_ready,
    output logic [39:0]  out_data,
    output logic         out_last,
    output logic         out_eol,
    output logic         out_sof
);
    // ------------------------------------------------------------- geometry
    localparam int BPL  = SRC_W / BEAT_PIX;     // source beats per line, 160
    localparam int NCOL = 4 * BPL;              // code columns per row, 640
    localparam int NROW = SRC_H / 2;            // code rows, 360
    localparam int PCOL = NCOL / 2;             // pooled columns per row, 320
    localparam int PROW = NROW / 2;             // pooled rows, 180
    localparam int PW   = 9;                    // pair-sum field, 2 x 8 bit
    localparam int CW   = 10;                   // box-sum field, 4 x 8 bit
    localparam int MW   = 3 * PW;               // one column, 3 channels
    localparam int XW   = $clog2(BPL);          // source beat within the line
    localparam int LW   = $clog2(SRC_H);        // source line
    localparam int OW   = $clog2(NCOL);         // output column, 0..639
    localparam int RW   = $clog2(NROW);         // output row, 0..359
    localparam int KW   = $clog2(PCOL);         // pooled column, 0..319

    initial begin
        if (SRC_W % BEAT_PIX != 0)
            $error("st_pre: SRC_W must be a multiple of %0d", BEAT_PIX);
        if (SRC_H % 4 != 0)
            $error("st_pre: SRC_H must be a multiple of 4 (2x2 box, then pool)");
    end

    // ------------------------------------------------------------ LUT (ROM)
    // One copy per channel so all three lookups happen in the same cycle.
    logic [7:0] lut_r [256], lut_g [256], lut_b [256];
    initial begin
        $readmemh(LUT_FILE, lut_r);
        $readmemh(LUT_FILE, lut_g);
        $readmemh(LUT_FILE, lut_b);
    end

    // ------------------------------------------------------------- control
    logic          run;
    logic          pool_mode;               // sampled from cfg_pool on start
    logic          in_done;                 // the frame's last source beat is in
    logic [LW-1:0] src_line;                // 0..SRC_H-1
    logic [XW-1:0] xb;                      // source beat within the line

    assign busy = run;

    // --------------------------------------------------------- pair-sum RAM
    // Write port: an even line's beat.  Read port: registered, issued on the
    // accept of the beat before the one it is used for.  Read and write
    // addresses never coincide (an odd line writes nothing).
    logic [4*MW-1:0] pair_mem [BPL];
    logic [4*MW-1:0] pair_q;                // registered read data
    logic [4*MW-1:0] pair_word;             // this beat's four pair sums

    // ---------------------------------------------------------- pool row RAM
    logic [MW-1:0] pool_mem [PCOL];
    logic [MW-1:0] pool_q;                  // registered read data

    // --------------------------------------------------- input window sums
    // Column k of the beat is source pixels 2k, 2k+1; its pair sum is 9 bits
    // (two 8-bit codes).  Field 3k+0 is blue, 3k+1 green, 3k+2 red.
    rgb888_t wpx [BEAT_PIX];

    always_comb begin
        for (int p = 0; p < BEAT_PIX; p++)
            wpx[p] = unpack565(rgb565_t'(in_data[16*p +: 16]));
        for (int k = 0; k < 4; k++) begin
            pair_word[MW*k + 0*PW +: PW] = PW'(wpx[2*k].b) + PW'(wpx[2*k+1].b);
            pair_word[MW*k + 1*PW +: PW] = PW'(wpx[2*k].g) + PW'(wpx[2*k+1].g);
            pair_word[MW*k + 2*PW +: PW] = PW'(wpx[2*k].r) + PW'(wpx[2*k+1].r);
        end
    end

    // --------------------------------------------------------- output stage
    logic         out_valid_r;
    logic [39:0]  out_data_r;
    logic         out_sof_r, out_eol_r, out_fin_r;

    assign out_valid = out_valid_r;
    assign out_data  = out_data_r;
    assign out_sof   = out_sof_r;
    assign out_eol   = out_eol_r;
    assign out_last  = 1'b1;                // one beat per pixel

    wire out_free = !out_valid_r || out_ready;

    // Pixel tags: the counters advance as pixels are created, in order.
    logic [OW-1:0] ocol;                    // 0..639, or 0..319 in POOL
    logic [RW-1:0] orow;                    // 0..359, or 0..179 in POOL
    wire [OW-1:0]  out_cols = pool_mode ? OW'(PCOL) : OW'(NCOL);
    wire [RW-1:0]  out_rows = pool_mode ? RW'(PROW) : RW'(NROW);
    wire           px_eol   = (ocol == out_cols - OW'(1));
    wire           px_sof   = (orow == '0) && (ocol == '0);
    wire           px_fin   = (orow == out_rows - RW'(1)) && px_eol;

    // ----------------------------------------------------- column emitter
    // The four box sums of the odd-line beat being emitted, one column per
    // cycle: avg -> LUT -> that column's three codes one cycle later.
    // bs_par is the code row's parity, carried alongside so the pool stage
    // still knows it after the next beat has loaded bs_q.
    logic [12*CW-1:0] bs_q;
    logic             bs_par;
    logic [2:0]       e_col;                // columns issued, 0..4
    logic             col_v;                // col_r/g/b hold a code triple
    logic             col_par;              // code row of col_r/g/b
    logic [7:0]       col_r, col_g, col_b;

    logic [3*CW-1:0] bs_col;
    always_comb begin
        bs_col = '0;
        for (int k = 0; k < 4; k++)
            if (3'(k) == e_col) bs_col = bs_q[3*CW*k +: 3*CW];
    end
    wire [CW-1:0] bs_r = bs_col[3*CW-1 -: CW];
    wire [CW-1:0] bs_g = bs_col[2*CW-1 -: CW];
    wire [CW-1:0] bs_b = bs_col[CW-1:0];

    function automatic logic [7:0] avg8(input logic [CW-1:0] s);
        avg8 = 8'((s + CW'(2)) >> 2);
    endfunction

    // ---------------------------------------------------------- pool stage
    // Codes of a pair's even column are held until the odd one arrives; the
    // pair sum of the row above is read from the pool RAM in the meantime.
    logic [MW-1:0] pp_c;
    logic          pp_have;
    logic [KW-1:0] pcol;                    // pair index within the row

    wire [MW-1:0] col_c    = {1'b0, col_r, 1'b0, col_g, 1'b0, col_b};
    wire [MW-1:0] pair_sum = pp_c + col_c;  // <= 254 per field

    logic [MW-1:0] pooled;
    always_comb
        for (int f = 0; f < 3; f++)
            pooled[PW*f +: PW] = PW'((10'(pool_q[PW*f +: PW])
                                      + 10'(pair_sum[PW*f +: PW]) + 10'd2) >> 2);

    // ------------------------------------------------------- handshakes
    wire col_take = col_v && out_free;
    wire col_free = !col_v || col_take;
    wire do_issue = (e_col != 3'd4) && col_free;
    // bs_q is free again once its fourth column has been issued.
    wire bs_free  = (e_col == 3'd4) || ((e_col == 3'd3) && do_issue);

    wire          even_line = !src_line[0];
    wire          last_beat = (xb == XW'(BPL - 1));
    wire          last_line = (src_line == LW'(SRC_H - 1));
    wire [XW-1:0] xb_next   = last_beat ? '0 : xb + XW'(1);
    wire          exp_sof   = (src_line == '0) && (xb == '0);
    wire          exp_eol   = last_beat;

    assign in_ready = run && !in_done && (even_line || bs_free);
    wire   accept   = in_valid && in_ready;

    // ------------------------------------------------------------ pixel out
    // FULL: every emitted column is a pixel.  POOL: the second column of a
    // pair on an odd code row is one pooled pixel.
    wire [39:0] px_col  = {10'd0, 10'(col_b), 10'(col_g), 10'(col_r)};
    wire [39:0] px_pool = {10'd0, 10'(pooled[0*PW +: PW]),
                           10'(pooled[1*PW +: PW]), 10'(pooled[2*PW +: PW])};
    wire        pool_px = pp_have && col_par;
    wire        mk_px   = col_take && (!pool_mode || pool_px);

    // ---------------------------------------------------------------- FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run         <= 1'b0;
            pool_mode   <= 1'b0;
            in_done     <= 1'b0;
            err         <= 1'b0;
            src_line    <= '0;
            xb          <= '0;
            pair_q      <= '0;
            pool_q      <= '0;
            out_valid_r <= 1'b0;
            out_data_r  <= '0;
            out_sof_r   <= 1'b0;
            out_eol_r   <= 1'b0;
            out_fin_r   <= 1'b0;
            ocol        <= '0;
            orow        <= '0;
            bs_q        <= '0;
            bs_par      <= 1'b0;
            e_col       <= 3'd4;
            col_v       <= 1'b0;
            col_par     <= 1'b0;
            col_r       <= '0;
            col_g       <= '0;
            col_b       <= '0;
            pp_c        <= '0;
            pp_have     <= 1'b0;
            pcol        <= '0;
        end else begin
            if (start && !run) begin
                run       <= 1'b1;
                pool_mode <= cfg_pool;
                err       <= 1'b0;
                in_done   <= 1'b0;
                src_line  <= '0;
                xb        <= '0;
                ocol      <= '0;
                orow      <= '0;
                e_col     <= 3'd4;
                col_v     <= 1'b0;
                pp_have   <= 1'b0;
                pcol      <= '0;
            end

            // -------------------------------------------------- column issue
            if (do_issue) begin
                col_v   <= 1'b1;
                col_par <= bs_par;
                col_r   <= lut_r[avg8(bs_r)];
                col_g   <= lut_g[avg8(bs_g)];
                col_b   <= lut_b[avg8(bs_b)];
                e_col   <= e_col + 3'd1;
            end else if (col_take) begin
                col_v   <= 1'b0;
            end

            // ------------------------------------------------ column consume
            // POOL: a pair of code columns becomes one pooled code, written
            // to the pool row RAM on even code rows and completed from it on
            // odd ones.  The RAM read is issued with the pair's first column,
            // one cycle before the sum that needs it.
            if (col_take && pool_mode) begin
                if (!pp_have) begin
                    pp_have <= 1'b1;
                    pp_c    <= col_c;
                    if (col_par) pool_q <= pool_mem[pcol];
                end else begin
                    pp_have <= 1'b0;
                    if (!col_par) pool_mem[pcol] <= pair_sum;
                    pcol <= (pcol == KW'(PCOL - 1)) ? '0 : pcol + KW'(1);
                end
            end

            // ------------------------------------------------------- input
            // The pair RAM read is issued with the address of the beat that
            // will be accepted next: one cycle later pair_q holds it, and it
            // stays there through input gaps until that beat arrives.  This
            // block comes after the emitter's so that a beat accepted in the
            // cycle its predecessor's fourth column is issued resets e_col.
            if (accept) begin
                pair_q <= pair_mem[xb_next];
                if (in_sof !== exp_sof || in_eol !== exp_eol) err <= 1'b1;
                if (even_line) begin
                    pair_mem[xb] <= pair_word;
                end else begin
                    for (int f = 0; f < 12; f++)
                        bs_q[CW*f +: CW] <= CW'(pair_q[PW*f +: PW])
                                          + CW'(pair_word[PW*f +: PW]);
                    bs_par <= src_line[1];
                    e_col  <= 3'd0;
                end
                if (last_beat) begin
                    xb       <= '0;
                    src_line <= src_line + LW'(1);
                    if (last_line) in_done <= 1'b1;
                end else begin
                    xb <= xb + XW'(1);
                end
            end

            // ------------------------------------------------------ output
            if (out_valid_r && out_ready) begin
                out_valid_r <= 1'b0;
                if (out_fin_r) run <= 1'b0;
            end

            // A new pixel goes into the output register when it is free; last,
            // so it wins over the acceptance above.
            if (mk_px) begin
                out_valid_r <= 1'b1;
                out_data_r  <= pool_mode ? px_pool : px_col;
                out_sof_r   <= px_sof;
                out_eol_r   <= px_eol;
                out_fin_r   <= px_fin;
                if (px_eol) begin
                    ocol <= '0;
                    orow <= orow + RW'(1);
                end else begin
                    ocol <= ocol + OW'(1);
                end
            end
        end
    end
endmodule
