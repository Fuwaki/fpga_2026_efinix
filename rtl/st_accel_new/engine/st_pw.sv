// st_pw.sv -- PW stage of the ST block engine (guided net at 640x360).
//
// A group-stream stage: it runs one 1x1 convolution on one 8-output x 16-input
// int8 MAC array (st_mac8x16) and requantises the result with four st_requant
// lanes (docs/st-accel-engine-adr.md, docs/st-guided-adr.md).
//
// One pass is one layer, cin -> cout with cin, cout <= 80 (NI = ceil(cin/16)
// input tiles, NO = ceil(cout/8) output tiles); a two-layer pass of the net is
// split into two passes by the sequencer that owns the pass table.  A pixel
// costs
//
//     max( NO*NI , 2*NO )  + a small constant
//
// cycles: the array runs NO*NI cycles per pixel and the four requant lanes 2*NO
// for the same pixel, so the requant term dominates only for cin <= 16.  The
// constant is the ROM prologue (3), the collector and array latency and the
// last pair's requant drain.
//
// ----------------------------------------------------------- pixel pairs
// Pixels are processed in pairs (2q, 2q+1) and cfg_npix is even.  The issue
// order of a pair is
//
//     for ot: for it: for px in {0,1}
//
// so a 1024-bit weight word (ot, it) is used on two consecutive array cycles,
// for pixel 2q and then pixel 2q+1, and the ROM only supplies 512 bits per
// cycle: line 2a of st_pw_rom is bits [511:0] of word a (output lanes 0..3)
// and line 2a+1 is bits [1023:512] (lanes 4..7).  The array still fires every
// cycle, with no bubble between pairs, output tiles or passes, because the ROM
// runs one word ahead:
//
//   pipe_go     one ROM read per fire, plus a three-read prologue;
//   read k      line k mod 2*NO*NI, so the counter's wrap is the next pair's
//               first word -- the last pair of a pass already reads word 0;
//   rd1         one read behind pw_dout, so pw_dout (a high half) and rd1 (the
//               low half before it) are one whole word;
//   w_cur       {pw_dout, rd1} on every cycle pw_dout is a high half, held
//               otherwise: the word of the pair on the array.
//
// The read stream leads the fire stream by exactly three reads, so fire m is
// accompanied by read m+3 and the word a pair needs is complete two cycles
// before its first fire and stays in w_cur for its second one.
//
// Two pixels alternate on the array, so the array's own accumulator cannot be
// used: it runs with in_first = in_last = 1 (a plain 8x16 dot product, which
// drops its accumulator adder) and two accumulator sets, one per pixel of the
// pair, add the dot products up.  Each set is written to the tile FIFO at the
// last input tile of its output tile.
//
// Structure.
//   collector   group beats -> four 80 x int8 banks, bank = pixel index mod 4,
//               so pair q+1 is collected while pair q is on the array.  Wide
//               mode (cfg_wide) takes 16 int8 values per beat on in_wide,
//               byte k of beat b = element 16b + k, which is what the DW
//               stage's im2col port emits (a 27-element vector is 2 beats);
//               narrow mode keeps 4 lanes per beat, low 8 bits of each lane
//               (a 80-channel vector is 20 beats);
//   issue       one pair at a time: 2*NO*NI array cycles, weight word
//               pw_base + ot*NI + it, the pair's two banks selected by pixel
//               parity;
//   MAC         st_pw_rom (registered) -> rd1 -> w_cur -> st_mac8x16
//               (LAT 4) -> two accumulator sets -> tile FIFO (TILE_DEPTH
//               entries: the 8 accumulators of an output tile and the tile's
//               7-bit tag);
//   requant     4 lanes, the two halves of an output tile back to back, LAT 6;
//               one half tile is 4 channels, exactly one group beat.  The 512
//               bits of requant words of a tile are not stored: they are a
//               function of the tile's output tile, so the drain reads them
//               from st_rq_rom, one read per half tile with the address
//               presented one cycle ahead;
//   output      OUT_DEPTH beats in one block RAM, split into two regions by
//               pixel parity, each with its own write pointer, read pointer and
//               credit (OUT_DEPTH/2 beats each).  The array and the drain walk
//               the pair output tile by output tile, so the two pixels of a
//               pair interleave; the read side drains region 0 for the G beats
//               of pixel 2q and then region 1 for pixel 2q+1, which keeps the
//               output pixel-major without holding a pixel's accumulator tiles
//               in flip-flops.
//
// Flags.  A pixel's sof/eol are ORed over its input beats; sof is placed on the
// first output group beat of the pixel, eol and last on the final one.
//
// A pass is cfg_npix pixels (18 bits: 640x360 = 230400): the stage takes no
// input beyond them and ends when all of them are collected and every pipeline
// is empty, so input gaps of any length are harmless.
//
// Resources.  The vector banks are flip-flop banks, 4 x 80 bytes = 2560 flops
// (one 80-byte bank per pixel of the two pairs in flight); the weight register
// is 1536 flops (w_cur, rd1).  The PW ROM is PW_DEPTH lines of 512 bits
// (512 x 512 = 26 RAM10 at 512x20; the guided net's 204 words are 408 lines),
// the requant ROM RQ_DEPTH x 4 x 64 bits (512 x 4 words per bank: 1496 words
// in all) and the output FIFO 512 x 39 bits (2 RAM10 at 512x20).
module st_pw #(
    parameter int    TILE_DEPTH = 8,        // accumulator tiles in the tile FIFO
    parameter int    OUT_DEPTH  = 512,      // output beats, two regions of half
    parameter int    PW_DEPTH   = 512,      // PW ROM lines of 512 bits
    parameter int    RQ_DEPTH   = 512,      // requant words per bank (4 banks)
    parameter string PW_HEX     = "rtl/st_accel_new/gen/guided/st_pw.hex",
    parameter string RQ_HEX     = "rtl/st_accel_new/gen/guided/st_rq_lines.hex"
) (
    input  logic              clk,
    input  logic              rst_n,

    // group stream in
    input  logic              in_valid,
    output logic              in_ready,
    input  logic [39:0]       in_data,      // 4 int8 lanes in 10-bit fields
    input  logic [127:0]      in_wide,      // 16 int8 values, cfg_wide = 1
    input  logic              in_last,
    input  logic              in_eol,
    input  logic              in_sof,

    // group stream out
    output logic              out_valid,
    input  logic              out_ready,
    output logic [39:0]       out_data,
    output logic              out_last,
    output logic              out_eol,
    output logic              out_sof,

    // one-cycle start pulse while idle; busy until the last beat is accepted
    input  logic              start,
    output logic              busy,

    // configuration, sampled on start
    input  logic [17:0]       cfg_npix,     // pixels of the pass, even
    input  logic              cfg_wide,     // input beats are in_wide[127:0]
    input  logic [6:0]        cfg_cin,
    input  logic [6:0]        cfg_cout,
    input  logic [9:0]        cfg_pw_base,  // first weight word
    input  logic [10:0]       cfg_rq_base,  // first requant word, multiple of 4
    input  logic signed [9:0] cfg_lo,
    input  logic signed [9:0] cfg_hi
);
    // st_requant in_valid -> out_valid.
    localparam int LAT_RQ = 6;

    localparam int TF_AW = (TILE_DEPTH > 1) ? $clog2(TILE_DEPTH) : 1;
    localparam int PW_AW = $clog2(PW_DEPTH);
    localparam int RQ_AW = $clog2(RQ_DEPTH);

    // The output FIFO is one RAM of OUT_DEPTH words, two regions of
    // OUT_DEPTH/2 beats, one per pixel parity.
    localparam int REG_DEPTH = OUT_DEPTH / 2;
    localparam int R_AW      = $clog2(REG_DEPTH);

    // The vector banks: 80 int8, the widest cin (NI = 5), one per pixel index
    // mod 4.
    localparam int XB = 80;                 // bytes per bank
    localparam int XW = 8 * XB;             // bits per bank

    // Output beats of the layer: ceil(cout/4) <= 20, five bits.
    function automatic logic [4:0] div4(input logic [6:0] v);
        div4 = 5'((8'(v) + 8'd3) >> 2);
    endfunction
    function automatic logic [3:0] div8(input logic [6:0] v);
        div8 = 4'((8'(v) + 8'd7) >> 3);
    endfunction
    function automatic logic [3:0] div16(input logic [6:0] v);
        div16 = 4'((8'(v) + 8'd15) >> 4);
    endfunction

    // ------------------------------------------------------- configuration
    logic              wide_r;
    logic [6:0]        cin_r, cout_r;
    logic [9:0]        pw_r;
    logic [10:0]       rq_r;
    logic signed [9:0] lo_r, hi_r;

    wire [4:0]  g_r   = div4(cout_r);        // output beats of a pixel
    wire [3:0]  no_r  = div8(cout_r);        // output tiles
    wire [3:0]  ni_r  = div16(cin_r);        // input tiles
    wire [5:0]  nw_r  = 6'(no_r) * 6'(ni_r); // weight words of a pixel, <= 50
    wire [6:0]  nw2_r = {nw_r, 1'b0};        // ROM lines of a pixel, <= 100
    logic [10:0] pw2_r;                      // 2 * pw_base, the first line

    // ------------------------------------------------------- vector banks
    // Four banks, pixel index mod 4, each 80 bytes as five words of 16 (the
    // array's input tile, NI <= 5): bank b word w holds elements 16w..16w+15.
    // Word granularity is what makes the write cheap -- a beat fills exactly
    // one word in wide mode and a quarter of one in narrow mode, so no byte of
    // a bank is ever written at a dynamic position.  Four named banks rather
    // than an unpacked array: an array of four 640-bit banks makes Efinity's
    // mapper crash (the two-bank version did not).  Data only, no reset.
    localparam int NB = 5;                  // words per bank
    logic [NB-1:0][127:0] xa0, xa1, xa2, xa3;

    // ===================================================== input collector
    logic [1:0]  col_pix;           // pixel being collected, index mod 4
    logic [4:0]  col_beat;          // beat of that pixel (<= 5 wide, <= 20 narrow)
    logic        col_act;           // pixel partially collected
    logic        col_sof, col_eol;
    logic        pix_sof [4];       // per pixel, index mod 4
    logic        pix_eol [4];

    wire [1:0] col_bank  = col_pix;
    wire       in_accept = in_valid && in_ready;
    // Narrow mode assembles a word from four beats of four lanes, so the
    // collector stages one word and writes the bank on the beat that fills it
    // (and on the pixel's last beat, for a cin that does not fill it).  Wide
    // mode writes every beat's word directly.
    logic [3:0][31:0] xw_stage;     // narrow: the word being assembled
    wire  [2:0]   col_word = wide_r ? 3'(col_beat) : 3'(col_beat[4:2]);
    wire          col_fill = !wide_r && (col_beat[1:0] == 2'd3);
    // The word a beat writes: its own in wide mode; in narrow mode the staged
    // word with this beat's four lanes spliced in, so the beat that fills the
    // word writes it complete (the stage register itself is one beat behind).
    logic [3:0][31:0] xw_next;
    always_comb begin
        for (int k = 0; k < 4; k++)
            xw_next[k] = (k == int'(col_beat[1:0])) ? in_lane : xw_stage[k];
    end
    wire  [127:0] xw_data  = wide_r ? in_wide : xw_next;
    // a narrow beat writes on the beat that fills the word, and on the pixel's
    // last beat (cin need not fill the bank)
    wire          xw_we    = in_accept && (wide_r || col_fill || in_last);

    // one group beat as 4 lanes of int8 in the low bytes
    wire [31:0] in_lane = {in_data[30 +: 8], in_data[20 +: 8],
                           in_data[10 +: 8], in_data[0 +: 8]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) xw_stage <= '0;
        else if (in_accept && !wide_r) xw_stage[col_beat[1:0]] <= in_lane;
    end

    // The pair on the array reads banks p_iss-2 and p_iss-1, so the collector
    // may only write the two banks of the next pair, p_iss and p_iss+1.
    wire       col_room  = (2'(col_pix - p_iss) < 2'd2);
    // The pixel is complete at this clock edge: its bank is written now and
    // read by the op's first fire next cycle, so the op may start in this
    // cycle instead of waiting for col_pix to move (one cycle per pixel).
    wire       col_fin   = in_accept && in_last;

    logic [17:0] pix_left;          // pixels of the pass still to collect
    assign in_ready = busy && (pix_left != 18'd0) && (col_act || col_room);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       pix_left <= 18'd0;
        else if (start)                   pix_left <= cfg_npix;
        else if (in_accept && in_last)    pix_left <= pix_left - 18'd1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_pix  <= 2'd0;
            col_beat <= 5'd0;
            col_act  <= 1'b0;
            col_sof  <= 1'b0;
            col_eol  <= 1'b0;
            for (int k = 0; k < 4; k++) begin
                pix_sof[k] <= 1'b0;
                pix_eol[k] <= 1'b0;
            end
        end else if (start) begin
            col_pix  <= 2'd0;
            col_beat <= 5'd0;
            col_act  <= 1'b0;
            col_sof  <= 1'b0;
            col_eol  <= 1'b0;
        end else if (in_accept) begin
            // The bank is XB bytes, so a legal pixel (cin <= 80) fits: wide
            // mode has at most 5 beats of 16 and narrow at most 20 of 4.  The
            // write is gated on that, and an over-long pixel is a stream error
            // (the same bound the simulation checks).
            if (xw_we) begin
                unique case (col_bank)
                    2'd0:    xa0[col_word] <= xw_data;
                    2'd1:    xa1[col_word] <= xw_data;
                    2'd2:    xa2[col_word] <= xw_data;
                    default: xa3[col_word] <= xw_data;
                endcase
            end
            // the flags of the pixel: ORed over its beats, cleared at its end
            col_sof <= col_sof | in_sof;
            col_eol <= col_eol | in_eol;
            if (in_last) begin
                pix_sof[col_pix] <= col_sof | in_sof;
                pix_eol[col_pix] <= col_eol | in_eol;
                col_sof  <= 1'b0;
                col_eol  <= 1'b0;
                col_pix  <= col_pix + 2'd1;
                col_beat <= 5'd0;
                col_act  <= 1'b0;
            end else begin
                col_beat <= col_beat + 5'd1;
                col_act  <= 1'b1;
            end
`ifndef SYNTHESIS
            if (wide_r ? (col_beat == 5'd5) : (col_beat == 5'd20))
                $error("st_pw: pixel beat %0d exceeds the %0d-byte bank", col_beat, XB);
`endif
        end
    end

    // ============================================================== issue
    logic        op_act;
    logic        op_px;             // 0: first pixel of the pair, 1: second
    logic        op_bank;           // bank base of the pair: 0 -> banks 0,1
    logic [3:0]  op_ot, op_it;
    logic [1:0]  op_sof, op_eol;    // per pixel of the pair
    logic [1:0]  p_iss;             // next pixel, even: the pair's first

    // Tiles fired but not yet drained: in the array pipeline, the tile FIFO
    // and the requant lanes.  The array writes the FIFO four cycles after a
    // tile's last input beat, so a credit based on tf_wp - tf_rp alone would
    // let a burst overwrite entries that are not written yet.
    logic [TF_AW:0] tile_used;
    // Beats reserved in a region but not pushed yet, at most the credit
    // (REG_DEPTH), so one bit more than the depth's log2.
    logic [R_AW:0]  pend [2];

    // Tile FIFO and drain bookkeeping.  The pointers carry one bit more than
    // the index so that full and empty differ; the level is their difference.
    logic [TF_AW:0]   tf_wp, tf_rp;
    logic             dr_phase;     // 0: first half of the head tile, 1: second
    wire  [TF_AW:0]   tile_occ = tf_wp - tf_rp;
    wire              tile_pop = dr_phase && (tile_occ != '0);

    // Output FIFO, two regions of REG_DEPTH beats: write pointers, read
    // pointers, the beats of the pair read from each region, and the read port.
    logic [R_AW:0]    of_wp [2], of_rp [2];
    logic             rd_reg;       // region being drained: pixel parity
    logic [4:0]       rd_cnt;       // beats of the current pixel read
    // A lane is clamped to cfg_lo..cfg_hi, inside -256..255 (int8, or u8 for
    // the output layer), so the FIFO keeps 9 bits of it: 3 + 4 x 9 = 39 bits,
    // two RAM10 at 512x20 instead of three for the 43-bit word.
    logic [38:0]      of_mem [OUT_DEPTH];
    logic [38:0]      of_din;
    logic [38:0]      of_rdata;
    logic             of_rvld;
    logic             of_we;
    wire  [R_AW:0]    of_lvl [2] = {of_wp[0] - of_rp[0], of_wp[1] - of_rp[1]};
    wire              of_empty;

    // Room for the pair's G beats in both regions.  of_lvl counts the words in
    // the RAM only, not the one on the read port, so the credit bounds the RAM
    // side at REG_DEPTH words and a push never overflows (a push needs an
    // outstanding reservation, pend > 0).
    wire [9:0] out_need0 = 10'(of_lvl[0]) + 10'(pend[0]) + 10'(g_r);
    wire [9:0] out_need1 = 10'(of_lvl[1]) + 10'(pend[1]) + 10'(g_r);
    wire       out_room = (out_need0 <= 10'(REG_DEPTH)) && (out_need1 <= 10'(REG_DEPTH));

    // The pair is complete: the collector has moved past its two pixels, or
    // its second pixel is being completed in this cycle by its last beat.
    wire [1:0] pair_d   = 2'(col_pix - p_iss);
    wire       pair_fin = col_fin && (pair_d == 2'd1);
    wire       pair_ok  = (pair_d >= 2'd2) || pair_fin;

    // tile_fin: the beat completes an output tile of its pixel, so it is the
    // last input tile of the tile and both pixels of the pair write one.
    wire tile_fin = (op_it == (ni_r - 4'd1));
    wire op_end   = tile_fin && op_px && (op_ot == (no_r - 4'd1));
    wire tile_ok  = (tile_used != (TF_AW+1)'(TILE_DEPTH));
    wire fire     = op_act && (!tile_fin || tile_ok);

    // An op can start in the cycle the previous one's last beat is accepted:
    // the array then runs without a bubble between pairs.
    wire chain = fire && op_end;
    // The pair may start once the prologue has read both halves of word 0, so
    // the first fire lands on a cycle w_cur holds it: with warm = 3 the reads
    // of lines 0 and 1 complete on the cycle warm is 1, and a take there fires
    // one cycle later.
    wire take  = busy && (warm <= 2'd1) && pair_ok && out_room
              && (!op_act || chain);

    // the pair's flags: the second pixel's are still in the running OR when it
    // is completed in this cycle
    wire [1:0] iss_sof = {pair_fin ? (col_sof | in_sof) : pix_sof[2'(p_iss + 2'd1)],
                          pix_sof[p_iss]};
    wire [1:0] iss_eol = {pair_fin ? (col_eol | in_eol) : pix_eol[2'(p_iss + 2'd1)],
                          pix_eol[p_iss]};

    // The beat's operand tile: 16 int8 lanes, zero beyond cin.  The pixel
    // parity picks the bank and op_it the bank's word, so the read is a 4-way
    // mux of 5-word banks (20:1) rather than of 80-byte banks.
    wire [127:0] op_word = op_bank ? (op_px ? xa3[op_it] : xa2[op_it])
                                   : (op_px ? xa1[op_it] : xa0[op_it]);

    // the lanes beyond cin are zero (a word past NI is never read: op_it < NI)
    wire [4:0] last_word = 5'(ni_r - 4'd1);
    logic [15:0][7:0] x_tile;
    always_comb begin
        for (int j = 0; j < 16; j++) begin
            x_tile[j] = ((16 * int'(op_it) + j) < int'(cin_r))
                      ? op_word[8*j +: 8] : 8'd0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_act  <= 1'b0;
            op_px   <= 1'b0;
            op_bank <= 1'b0;
            op_ot   <= 4'd0;
            op_it   <= 4'd0;
            op_sof  <= 2'd0;
            op_eol  <= 2'd0;
            p_iss   <= 2'd0;
            tile_used <= '0;
        end else if (start) begin
            op_act  <= 1'b0;
            op_px   <= 1'b0;
            op_ot   <= 4'd0;
            op_it   <= 4'd0;
            p_iss   <= 2'd0;
            tile_used <= '0;
        end else begin
            // issue wins over fire: when the last beat of a pair is accepted
            // and the next pair can start, the descriptor is replaced this
            // cycle and the new pair's first beat fires next cycle, with no
            // bubble.
            if (take) begin
                op_act  <= 1'b1;
                op_px   <= 1'b0;
                op_bank <= p_iss[1];
                op_sof  <= iss_sof;
                op_eol  <= iss_eol;
                op_ot   <= 4'd0;
                op_it   <= 4'd0;
                p_iss   <= p_iss + 2'd2;
            end else if (fire) begin
                op_px <= ~op_px;
                if (op_px && tile_fin) begin
                    op_it <= 4'd0;
                    if (op_ot == (no_r - 4'd1)) op_act <= 1'b0;
                    else                        op_ot <= op_ot + 4'd1;
                end else if (op_px) begin
                    op_it <= op_it + 4'd1;
                end
            end
            // one slot per tile, from the last input beat to the drain
            tile_used <= tile_used + 1'(fire && tile_fin) - 1'(tile_pop);
        end
    end

    // ================================================== weight ROM pipeline
    // The ROM runs one word ahead of the array, so a pair's two beats never
    // stall the array: read k of the stream is line k mod 2*NO*NI, and fire m
    // is accompanied by read m+2, so the counter's wrap is the next pair's
    // first word.  rd1 is one read behind pw_dout, and d_odd says whether
    // pw_dout is a high half; a high half plus rd1 is a whole word, which w_cur
    // holds for the pair's two beats.  A gap in the fire stream freezes the
    // read side (the ROM's clock enable holds its output) and w_cur simply
    // reloads the same word, so the two stay in step whatever the gaps.
    //
    // The pass opens with three reads (lines 0..2, two and a half words ahead),
    // so word 0 is in w_cur before the first fire; warm counts them down and
    // gates the first take.
    logic [6:0]   pw_line;          // ROM line presented this cycle
    logic [1:0]   warm;             // prologue reads left
    logic         d_odd;            // pw_dout is a high half
    logic [511:0] rd1, pw_dout;
    logic [1023:0] w_cur;           // the next fire's weight word

    wire [10:0] pw_addr = pw2_r + 11'(pw_line);
    wire        pipe_go = fire || (warm != 2'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pw_line <= 7'd0;
            warm    <= 2'd0;
            d_odd   <= 1'b0;
            rd1     <= '0;
            w_cur   <= '0;
        end else if (start) begin
            pw_line <= 7'd0;
            warm    <= 2'd3;
            d_odd   <= 1'b0;
            rd1     <= '0;
            w_cur   <= '0;
        end else if (pipe_go) begin
            pw_line <= (pw_line == (nw2_r - 7'd1)) ? 7'd0 : pw_line + 7'd1;
            rd1     <= pw_dout;
            d_odd   <= pw_line[0];
            if (warm != 2'd0) warm <= warm - 2'd1;
            // d_odd is the parity of the line whose data is on pw_dout now, so
            // pw_dout and rd1 are one whole word; the load is inside the
            // enable, so a gap in the fire stream freezes it too.
            if (d_odd) w_cur <= {pw_dout, rd1};
        end
    end

    st_pw_rom #(.DEPTH(PW_DEPTH), .HEX(PW_HEX)) u_pw_rom (
        .clk  (clk),
        .ce   (pipe_go),
        .addr (PW_AW'(pw_addr)),
        .dout (pw_dout)
    );

    // ==================================================== array and adders
    // in_first = in_last = 1: the array returns the 8x16 dot product of the
    // beat four cycles later, and the pair's two accumulator sets add them up.
    logic               mac_done;
    logic signed [23:0] mac_acc [8];

    st_mac8x16 u_mac (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_valid(fire),
        .in_x    (x_tile),
        .in_w    (w_cur),
        .in_first(1'b1),
        .in_last (1'b1),
        .done    (mac_done),
        .acc_out (mac_acc)
    );

    // ------------------------------------------------------- tile tags
    // The tag of a tile is wanted in the mac_done cycle, four cycles after the
    // tile's last input beat was accepted: output tile, pixel parity, sof,
    // eol.  The clamp limits, cin and cout are the pass's, so nothing else
    // travels with the tile.
    logic [6:0] dv_tag [4];
    logic       dv_px [4];
    logic       dv_first [4];       // first input tile of the output tile
    logic       dv_last [4];        // last input tile of the output tile

    wire [6:0] beat_tag = {op_ot, op_px, op_sof[op_px], op_eol[op_px]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 4; k++) begin
                dv_tag[k]   <= 7'd0;
                dv_px[k]    <= 1'b0;
                dv_first[k] <= 1'b0;
                dv_last[k]  <= 1'b0;
            end
        end else if (start) begin
            for (int k = 0; k < 4; k++) dv_tag[k] <= 7'd0;
        end else begin
            dv_tag[0]   <= beat_tag;
            dv_px[0]    <= op_px;
            dv_first[0] <= (op_it == 4'd0);
            dv_last[0]  <= tile_fin;
            for (int k = 1; k < 4; k++) begin
                dv_tag[k]   <= dv_tag[k-1];
                dv_px[k]    <= dv_px[k-1];
                dv_first[k] <= dv_first[k-1];
                dv_last[k]  <= dv_last[k-1];
            end
        end
    end

    // ------------------------------------------------ pair accumulators
    // One set per pixel of the pair, cleared on the output tile's first input
    // tile.  |sum| < 80*127*127 < 2**21, so 24 bits hold it.  Plain vectors,
    // not arrays: Efinity reads an unpacked array of a few wide words as a
    // memory and tries to place it in a RAM10.
    logic [191:0] acc0, acc1;
    logic [191:0] acc_px;
    logic [191:0] acc_sum;
    logic        [191:0] tf_din;

    always_comb begin
        acc_px = dv_px[3] ? acc1 : acc0;
        for (int o = 0; o < 8; o++)
            acc_sum[24*o +: 24] = dv_first[3] ? mac_acc[o]
                                              : 24'(acc_px[24*o +: 24])
                                                + 24'(mac_acc[o]);
        tf_din = acc_sum;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc0 <= '0;
            acc1 <= '0;
        end else if (start) begin
            acc0 <= '0;
            acc1 <= '0;
        end else if (mac_done) begin
            if (!dv_px[3]) acc0 <= acc_sum;
            else           acc1 <= acc_sum;
        end
    end

    // ---------------------------------------------------------- tile FIFO
    logic [191:0] tf_acc [TILE_DEPTH];
    logic [6:0]   tf_tag [TILE_DEPTH];
    wire          tf_wr = mac_done && dv_last[3];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tf_wp <= '0;
        end else if (start) begin
            tf_wp <= '0;
        end else if (tf_wr) begin
            tf_acc[tf_wp[TF_AW-1:0]] <= tf_din;
            tf_tag[tf_wp[TF_AW-1:0]] <= dv_tag[3];
            tf_wp <= tf_wp + 1'(1);
        end
    end

    // ------------------------------------------------------------- drain
    // No idle state: the head tile of the FIFO is fed to the lanes as soon as
    // it is there, first half and then second half.  A tile is popped when its
    // second half has been issued, so dr_phase is back at 0 for the next one.
    //
    // The requant words of a tile are the eight words at the tile's first
    // address rq_base + 8*ot, so they are read from the ROM here instead of
    // being carried through the FIFO.  The ROM read is registered, so the
    // address on the port is that of the NEXT beat's tile -- the head tile
    // again for its second half, the next one for a first half.  The pointers
    // only move when there is a tile to feed, so the address, like the beat,
    // repeats while the drain stalls.
    wire [191:0] dr_acc = tf_acc[tf_rp[TF_AW-1:0]];
    wire [6:0]   dr_tag = tf_tag[tf_rp[TF_AW-1:0]];

    wire         dr_half  = dr_phase;
    wire         dr_valid = (tile_occ != '0);
    // the half of the beat the ROM must present next cycle
    wire         nx_half  = dr_valid ? ~dr_phase : dr_phase;
    wire [95:0]  acc_sel  = dr_half ? dr_acc[191:96] : dr_acc[95:0];

    wire [4:0]  dr_g   = {dr_tag[6:3], dr_half};        // output beat of the op

    wire [TF_AW-1:0]  nx_tile = tf_rp[TF_AW-1:0]
                              + TF_AW'((dr_valid && dr_phase) ? 1'b1 : 1'b0);
    // The tile the drain feeds next cycle may be the one being written now:
    // its tag is not in the FIFO yet, the write tag is the same value.
    wire [6:0]        nx_tag  = (tf_wr && (nx_tile == tf_wp[TF_AW-1:0]))
                              ? dv_tag[3] : tf_tag[nx_tile];
    // the tile's first requant word, rq_base + 8*ot; the half is the ROM's
    // word index within the tile, so one read covers one half tile
    wire [10:0]       nx_word = rq_r
                              + 11'({7'd0, nx_tag[6:3]}) * 11'd8
                              + 11'(nx_half ? 11'd4 : 11'd0);

    // four banks of RQ_DEPTH words: a read returns the four channels of one
    // half tile
    logic [3:0][63:0] rq_banks;
    st_rq_rom #(.NB(4), .DEPTH(RQ_DEPTH), .HEX(RQ_HEX)) u_rq_rom (
        .clk  (clk),
        .addr (RQ_AW'(nx_word >> 2)),
        .dout (rq_banks)
    );

    wire [255:0] rq_sel = {rq_banks[3], rq_banks[2], rq_banks[1], rq_banks[0]};

    logic [63:0]        lane_w [4];
    logic signed [24:0] lane_x [4];
    logic signed [31:0] lane_sum [4];
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            lane_w[j]   = rq_sel[64*j +: 64];
            lane_sum[j] = $signed({{8{acc_sel[24*j + 23]}}, acc_sel[24*j +: 24]})
                        + $signed(lane_w[j][31:0]);
            lane_x[j]   = lane_sum[j][24:0];    // |acc + bias| < 2**22
        end
    end

    wire              lane_valid = dr_valid;
    // tag: output beat, pixel parity, sof, eol
    wire [7:0]        lane_tag   = {dr_g, dr_tag[2], dr_tag[1], dr_tag[0]};
    // The four lanes run in lockstep, so only lane 0's handshake is used.
    wire              lane_ovld [4];
    wire signed [9:0] lane_y [4];
    wire [7:0]        lane_otag [4];
    wire              lane_out_valid = lane_ovld[0];
    wire [7:0]        lane_out_tag   = lane_otag[0];

    for (genvar j = 0; j < 4; j++) begin : g_lane
        st_requant #(.XW(25), .TW(8)) u_rq (
            .clk      (clk),
            .rst_n    (rst_n),
            .in_valid (lane_valid),
            .in_x     (lane_x[j]),
            .in_mant  (lane_w[j][55:32]),
            .in_k     (lane_w[j][61:56]),
            .in_lo    (lo_r),
            .in_hi    (hi_r),
            .in_tag   (lane_tag),
            .out_valid(lane_ovld[j]),
            .out_y    (lane_y[j]),
            .out_tag  (lane_otag[j])
        );
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dr_phase <= 1'b0;
            tf_rp    <= '0;
        end else if (start) begin
            dr_phase <= 1'b0;
            tf_rp    <= '0;
        end else if (tile_occ != '0) begin
            dr_phase <= ~dr_phase;
            if (dr_phase) tf_rp <= tf_rp + 1'(1);
        end
    end

    // --------------------------------------------------------- writeback
    wire [4:0] wb_g   = lane_out_tag[7:3];
    wire       wb_px  = lane_out_tag[2];
    wire       wb_sof = lane_out_tag[1];
    wire       wb_eol = lane_out_tag[0];
    wire       wb_keep = (wb_g < g_r);

    // One group beat and one 4-byte vector from the four lanes; channels
    // beyond cout are zero.
    logic [39:0] beat;
    for (genvar j = 0; j < 4; j++) begin : g_pack
        wire [7:0] ch = 8'(4 * int'(wb_g) + j);
        assign beat[10*j +: 10] = (ch < {1'b0, cout_r}) ? lane_y[j] : 10'sd0;
    end

    wire beat_push = lane_out_valid && wb_keep;
    assign of_din  = {wb_sof && (wb_g == 5'd0),
                      wb_eol && (wb_g == (g_r - 5'd1)),
                      (wb_g == (g_r - 5'd1)),
                      beat[38:30], beat[28:20], beat[18:10], beat[8:0]};

    // -------------------------------------------------------- output FIFO
    // One block RAM of OUT_DEPTH words, two regions of REG_DEPTH beats by pixel
    // parity: the drain writes region wb_px and the read side drains region 0
    // for pixel 2q's G beats, then region 1 for pixel 2q+1.  That keeps the
    // output pixel-major although the two pixels of a pair interleave on the
    // array, without holding a pixel's accumulator tiles anywhere.
    wire       rd_avail = (of_wp[rd_reg] != of_rp[rd_reg]);
    wire       do_read  = rd_avail && (!of_rvld || out_ready);

    always_ff @(posedge clk) begin
        if (of_we) of_mem[{wb_px, of_wp[wb_px][R_AW-1:0]}] <= of_din;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            of_wp[0] <= '0;
            of_wp[1] <= '0;
        end else if (start) begin
            of_wp[0] <= '0;
            of_wp[1] <= '0;
        end else if (of_we) begin
            of_wp[wb_px] <= of_wp[wb_px] + 1'(1);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            of_rp[0] <= '0;
            of_rp[1] <= '0;
        end else if (start) begin
            of_rp[0] <= '0;
            of_rp[1] <= '0;
        end else if (do_read) begin
            of_rp[rd_reg] <= of_rp[rd_reg] + 1'(1);
        end
    end

    // The read register is the FIFO's first-word fall-through stage and the
    // stage's output register at once.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            of_rvld <= 1'b0;
        end else if (start) begin
            of_rvld <= 1'b0;
        end else if (do_read) begin
            of_rvld  <= 1'b1;
            of_rdata <= of_mem[{rd_reg, of_rp[rd_reg][R_AW-1:0]}];
        end else if (out_ready) begin
            of_rvld <= 1'b0;
        end
    end

    // Region 0 gives the pair's first pixel its G beats, then region 1 the
    // second; after region 1 the read side is back at region 0 for the next
    // pair, which is also the end of the pair.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_reg <= 1'b0;
            rd_cnt <= 5'd0;
        end else if (start) begin
            rd_reg <= 1'b0;
            rd_cnt <= 5'd0;
        end else if (do_read) begin
            if (rd_cnt == (g_r - 5'd1)) begin
                rd_reg <= ~rd_reg;
                rd_cnt <= 5'd0;
            end else begin
                rd_cnt <= rd_cnt + 5'd1;
            end
        end
    end

    assign {out_sof, out_eol, out_last} = of_rdata[38:36];
    for (genvar j = 0; j < 4; j++) begin : g_unpack
        assign out_data[10*j +: 10] = {of_rdata[9*j + 8], of_rdata[9*j +: 9]};
    end
    assign out_valid = of_rvld;

    // Empty: no word in either region and none on the read port.  The pointers
    // of the FIFO only move when it is written and read, so this is also what
    // the previous pass left behind -- empty, since a pass only ends drained.
    wire [R_AW:0] zero_lvl = '0;
    assign of_empty = (of_lvl[0] == zero_lvl) && (of_lvl[1] == zero_lvl) && !of_rvld;

    // The FIFO takes the beat in the cycle it is offered: the credit scheme
    // reserves a slot before the beat can be produced, so it never overflows.
    assign of_we = beat_push;

`ifndef SYNTHESIS
    always @(posedge clk)
        if (rst_n && of_we && (of_lvl[wb_px] == (R_AW+1)'(REG_DEPTH)))
            $error("st_pw: output FIFO overflow (credit broken)");
`endif

    // output beats reserved by issued pairs, released one per push
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend[0] <= '0;
            pend[1] <= '0;
        end else if (start) begin
            pend[0] <= '0;
            pend[1] <= '0;
        end else begin
            pend[0] <= pend[0] + (R_AW+1)'(take ? g_r : 5'd0)
                               - 1'(beat_push && !wb_px);
            pend[1] <= pend[1] + (R_AW+1)'(take ? g_r : 5'd0)
                               - 1'(beat_push && wb_px);
        end
    end

    // ---------------------------------------------------------------- busy
    logic busy_q;

    wire pipe_empty = !op_act && (tile_used == '0) && (tile_occ == '0)
                   && (dr_phase == 1'b0) && !lane_out_valid && of_empty
                   && (pend[0] == '0) && (pend[1] == '0)
                   && !col_act && (col_pix == p_iss) && (warm == 2'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else if (start) begin
            busy_q <= 1'b1;
        end else if (busy_q && pipe_empty && (pix_left == 18'd0)) begin
            busy_q <= 1'b0;
        end
    end

    assign busy = busy_q;

    // ------------------------------------------------- configuration latches
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wide_r <= 1'b0;
            cin_r  <= 7'd1;
            cout_r <= 7'd1;
            pw_r   <= 10'd0;
            rq_r   <= 11'd0;
            lo_r   <= 10'sd0;
            hi_r   <= 10'sd0;
            pw2_r  <= 11'd0;
        end else if (start) begin
            wide_r <= cfg_wide;
            cin_r  <= cfg_cin;
            cout_r <= cfg_cout;
            pw_r   <= cfg_pw_base;
            rq_r   <= cfg_rq_base;
            lo_r   <= cfg_lo;
            hi_r   <= cfg_hi;
            pw2_r  <= {cfg_pw_base, 1'b0};
        end
    end

    // Configuration bounds.  The ROM addresses are parameterised, so a layer
    // outside the images would wrap an address instead of failing: refuse it
    // here rather than in the data.  A requant read takes four words from four
    // banks, so a layer's first word must be 4-aligned, exactly the rule
    // tools/st_gen_params.py and st_dw keep.
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && start) begin
            int n_lines;
            n_lines = 2 * int'(div8(cfg_cout)) * int'(div16(cfg_cin));
            if (cfg_npix[0] != 1'b0)
                $error("st_pw: cfg_npix %0d is odd, pixels come in pairs", cfg_npix);
            if (cfg_cin < 7'd1 || cfg_cout < 7'd1)
                $error("st_pw: the layer has a zero channel count");
            else if (int'(cfg_cin) > XB || int'(cfg_cout) > 80)
                $error("st_pw: the layer (%0d -> %0d) exceeds 80 channels",
                       cfg_cin, cfg_cout);
            else if (2 * int'(cfg_pw_base) + n_lines > PW_DEPTH)
                $error("st_pw: the layer's %0d ROM lines exceed PW_DEPTH", n_lines);
            else if (cfg_rq_base[1:0] != 2'd0)
                $error("st_pw: the rq base is not a multiple of 4");
            else if (cfg_lo < -10'sd256 || cfg_hi > 10'sd255)
                $error("st_pw: clamp %0d..%0d exceeds the FIFO's 9-bit lanes",
                       cfg_lo, cfg_hi);
            else if (int'(cfg_rq_base) + 8 * int'(div8(cfg_cout)) > 4 * RQ_DEPTH)
                $error("st_pw: the layer's requant words exceed the rq ROM");
        end
    end
`endif

    initial begin
        if (LAT_RQ != 6 || $clog2(OUT_DEPTH) != R_AW + 1)
            $error("st_pw: pipeline constants disagree with the delay lines");
        if (PW_DEPTH < 4 || (1 << PW_AW) != PW_DEPTH)
            $error("st_pw: PW_DEPTH must be a power of two");
        if (RQ_DEPTH < 2 || (1 << RQ_AW) != RQ_DEPTH)
            $error("st_pw: RQ_DEPTH must be a power of two");
        if (OUT_DEPTH < 8 || (1 << (R_AW + 1)) != OUT_DEPTH)
            $error("st_pw: OUT_DEPTH must be a power of two, twice REG_DEPTH");
    end

endmodule
