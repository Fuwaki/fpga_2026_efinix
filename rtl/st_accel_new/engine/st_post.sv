// st_post.sv -- pass 14 (head) output -> the whole PROC slot.
//
// Input: the engine's group stream from the PW stage, head layer: one group
// beat per pixel, W x H pixels in raster order, lanes 0..2 = R, G, B as
// 0..255 in a 10-bit lane, `last` on every beat, `sof` on the first beat of
// the frame, `eol` on the last beat of every line.
// Output: 128-bit beats for tile_dma_wr, one AXI beat per 8 pixels:
//
//   base = slot, 160 beats per line, 720 lines, stride LINE_STRIDE
//   line REP_Y*sy + d, d = 0..REP_Y-1: source line sy with every pixel
//   repeated REP_X times
//   px = RGB565 with a 2x2 ordered dither on the output pixel (x, y),
//   pixel 0 in bits [15:0]:
//     t  = [[0, 2], [3, 1]][y & 1][x & 1]
//     r5 = (31 R + 32 + 64 t) >> 8
//     g6 = (63 G + 64 + 128 (t >> 1)) >> 8,  b5 = (31 B + 64 + 128 (t >> 1)) >> 8
//   R has a quarter-step dither, G and B a half-step one (a checkerboard).
//   A source pixel's REP_X x REP_Y copies cover all four t, so over a 2x2
//   copy the unpacked levels average to the 8-bit value within a quarter
//   step for R and half a step for G and B, instead of banding at 32 / 64
//   levels.
//   sof on the first beat of the frame, eol on the last beat of every line
//
// With the guided net's defaults (W = 640, H = 360, REP_X = REP_Y = 2) that is
// exactly st_guided.post(), the PROC slot of `--frame --dump`: the inverse of
// st_pre's 2x2 box, so the PROC slot lines up pixel for pixel with the ISP
// slot it came from.  The tiny_dw engine used W = 320, H = 240, REP = 4x3,
// the 4:3 network input stretched over the 16:9 slot.
//
// Design.  Two line buffers of W/4 x 80 bits, ping-pong: word w of a buffer
// holds source pixels 4w..4w+3, 20 bits each: the codes for t = 0 and the
// dither fraction, {b5, bf, g6, gf, r5, rf[1:0]} with r5 = a >> 8 and
// rf = a[7:6] for a = 31 R + 32, g6, gf = a >> 8, a[7] for a = 63 G + 64,
// b5, bf likewise.  The emitter adds one where rf + t >= 4 (R) or the
// fraction is set and t >= 2 (G, B): the same codes as the formula above,
// without carrying the 8-bit pixel (80 bits is two 256x40 RAM10, as 64 was).  An output beat carries SPB =
// 8/REP_X source pixels, each REP_X times: SPB = 4 (REP_X = 2) is one whole
// word, SPB = 2 (REP_X = 4) is half a word.  Line sy fills buffer sy mod 2
// while line sy-1 is emitted REP_Y times.
//
// Fill and emit stay within one source line of each other, so the bank being
// written is never the bank being read: the fill may only run on line e_sy+1
// while the emitter reads line e_sy, and the emitter leaves line e_sy with the
// issue (and read) of its last beat, before the fill can start line e_sy+2 in
// the same bank.  The fill needs W input beats per source line and the
// emission REP_Y*W*REP_X/8 output beats per line.  With REP_X = REP_Y = 2 and
// W = 640 the fill is the slower of the two (640 vs 320), so the frame takes
// about H*W = 230k cycles without back-pressure; with REP_X = 4, REP_Y = 3 the
// emission dominates (960 vs 640) and it is about 3*W*H/2 = 346k.  Measured:
// 234 820 and 350 340 cycles.
//
// Resources: the line buffers at 2 x (W/4) x 80 bits (2 x 160 x 80 = 4 RAM10
// for W = 640, as at 64 bits); the output register and the 4-pixel gather
// register.  No multiply: 31 v = 32 v - v, 63 v = 64 v - v.
module st_post
    import vid_pkg::*;
#(
    parameter int W     = 640,      // source pixels per line
    parameter int H     = 360,      // source lines
    parameter int REP_X = 2,        // output pixels per source pixel, 2 or 4
    parameter int REP_Y = 2         // output lines per source line, 2 or 3
) (
    input  logic         clk,
    input  logic         rst_n,

    // Input: group beats, one pixel each.
    input  logic         in_valid,
    output logic         in_ready,
    input  logic [39:0]  in_data,   // lane j = bits [10j+9:10j]
    input  logic         in_last,
    input  logic         in_sof,
    input  logic         in_eol,

    // Output: PROC slot beats.
    output logic         out_valid,
    input  logic         out_ready,
    output logic [127:0] out_data,
    output logic         out_sof,
    output logic         out_eol,

    input  logic         start,      // one cycle, while idle
    output logic         busy,       // until the last output beat is accepted
    output logic         err         // input framing mismatch, sticky
);
    localparam int PW4  = W / 4;                  // buffer words per line
    localparam int SPB  = BEAT_PIX / REP_X;       // source pixels per beat, 4 or 2
    localparam int OBP  = W * REP_X / BEAT_PIX;   // output beats per line
    localparam int WB   = $clog2(PW4);            // buffer word address
    localparam int OW   = $clog2(OBP);            // beat within the output line
    localparam int SW   = $clog2(W);              // pixel within the source line
    localparam int HW   = $clog2(H + 1);          // source line, 0..H
    localparam int NACC = H * REP_Y * OBP;        // output beats in a frame
    localparam int AW   = $clog2(NACC + 1);       // beat counter width
    localparam int LB   = $clog2(4 / SPB);        // beats per buffer word: 0 or 1
    localparam int BPW  = 4 / SPB;                // buffer words per 4 pixels

    initial begin
        if (W % 4 != 0)
            $error("st_post: W must be a multiple of 4");
        if (REP_X != 2 && REP_X != 4)
            $error("st_post: REP_X must be 2 or 4");
        if (REP_Y < 2 || REP_Y > 3)
            $error("st_post: REP_Y must be 2 or 3");
        if (W * REP_X % BEAT_PIX != 0)
            $error("st_post: a line must be a whole number of output beats");
        if (SPB * REP_X != BEAT_PIX)
            $error("st_post: one output beat must be 8 pixels of source");
    end

    // ---------------------------------------------------------- line buffer
    localparam int PB = 20;                       // buffer bits per pixel
    logic [4*PB-1:0] lbuf [2][PW4];
    logic [HW-1:0] e_sy;                // source line being emitted
    logic [OW-1:0] e_beat;              // beat within the output line
    wire           rd_bank = e_sy[0];
    wire [WB-1:0]  rd_addr = WB'(e_beat >> LB);
    wire [0:0]     e_off   = (BPW == 2) ? e_beat[0] : 1'b0;  // beat in the word
    logic [4*PB-1:0] rd_word;

    // ------------------------------------------------------------- control
    typedef enum logic { ST_IDLE, ST_RUN } state_e;
    state_e state;

    logic          running;
    logic [HW-1:0] fill_line;           // source line being filled, 0..H
    logic [SW-1:0] fill_col;            // pixel within it
    logic [3*PB-1:0] stage;             // pixels gathered for the next word
    logic          wr_en;
    logic          wr_bank;
    logic [WB-1:0] wr_addr;
    logic [4*PB-1:0] wr_word;

    logic [1:0]    e_rep;               // copy of the source line, 0..REP_Y-1
    logic [AW-1:0] n_iss;               // output beats issued this frame
    logic [AW-1:0] n_acc;               // output beats accepted this frame

    assign busy = running;

    // ------------------------------------------------------- emitter address
    wire stall  = out_valid && !out_ready;
    wire src_ok = (fill_line > e_sy);   // that source line is in
    wire issue  = (state == ST_RUN) && !stall && src_ok && (n_iss < AW'(NACC));
    wire last_xfer = out_valid && out_ready;
    wire e_eol  = (e_beat == OW'(OBP - 1));

    // The read is gated by the issue: the word is captured for the beat being
    // issued and held while the output stalls.  Without the gate a stall right
    // after a line's last beat would latch the next line's word 0 instead of
    // the beat's own.
    always_ff @(posedge clk)
        if (issue) rd_word <= lbuf[rd_bank][rd_addr];

    // --------------------------------------------------------------- fill
    // At most one source line ahead of the emitter.
    wire fill_room = (fill_line < HW'(H)) && (fill_line <= e_sy + HW'(1));
    assign in_ready = (state == ST_RUN) && fill_room;
    wire   accept   = in_ready && in_valid;

    // The beat's buffer pixel: lanes 0..2 are R, G, B.  Lane 3 is unused (the
    // head layer has C = 3; the stream guarantees it is zero).
    /* verilator lint_off UNUSEDSIGNAL */
    wire [9:0] r10 = in_data[9:0], g10 = in_data[19:10], b10 = in_data[29:20];
    wire [9:0] c3  = in_data[39:30];
    wire [12:0] a_r = {r10[7:0], 5'd0} - 13'(r10[7:0]) + 13'd32;
    wire [13:0] a_g = {g10[7:0], 6'd0} - 14'(g10[7:0]) + 14'd64;
    wire [12:0] a_b = {b10[7:0], 5'd0} - 13'(b10[7:0]) + 13'd64;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [PB-1:0] px_in = {a_b[12:8], a_b[7], a_g[13:8], a_g[7], a_r[12:8], a_r[7:6]};

    wire exp_sof = (fill_line == '0) && (fill_col == '0);
    wire exp_eol = (fill_col == SW'(W - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_line <= '0;
            fill_col  <= '0;
            stage     <= '0;
            wr_en     <= 1'b0;
            wr_bank   <= 1'b0;
            wr_addr   <= '0;
            wr_word   <= '0;
            err       <= 1'b0;
        end else if (start && state == ST_IDLE) begin
            fill_line <= '0;
            fill_col  <= '0;
            wr_en     <= 1'b0;
            err       <= 1'b0;
        end else begin
            wr_en <= 1'b0;
            if (accept) begin
                // Pixels land little-endian: pixel 4w+k at bits [16k +: 16].
                if (fill_col[1:0] != 2'd3)
                    stage[PB*fill_col[1:0] +: PB] <= px_in;
                if (fill_col[1:0] == 2'd3) begin
                    wr_en   <= 1'b1;
                    wr_bank <= fill_line[0];
                    wr_addr <= fill_col[SW-1:2];
                    wr_word <= {px_in, stage};
                end
                if (!in_last || in_sof !== exp_sof || in_eol !== exp_eol) err <= 1'b1;
                if (exp_eol) begin
                    fill_col  <= '0;
                    fill_line <= fill_line + HW'(1);
                end else begin
                    fill_col <= fill_col + SW'(1);
                end
            end
        end
    end

    always_ff @(posedge clk)
        if (wr_en) lbuf[wr_bank][wr_addr] <= wr_word;

    // --------------------------------------------------------------- emit
    // Emission pipeline: stage 1 carries the tags of the beat being issued
    // (the line-buffer address is combinational), stage 2 holds its word and
    // drives the output register.
    logic        s1_v, s1_off, s1_sof, s1_eol, s1_yp;
    logic        s2_v, s2_off, s2_sof, s2_eol, s2_yp;
    logic [4*PB-1:0] s2_word;

    // Parity of the output line REP_Y*e_sy + e_rep.
    wire e_yp = (REP_Y % 2 == 1) ? (e_sy[0] ^ e_rep[0]) : e_rep[0];

    // t = [[0, 2], [3, 1]][y & 1][x & 1]
    function automatic logic [1:0] thr(input logic yp, input logic xp);
        return yp ? (xp ? 2'd1 : 2'd3) : (xp ? 2'd2 : 2'd0);
    endfunction

    // A buffer pixel and its t -> RGB565.  Pixel 8b + q of a beat has x & 1 =
    // q & 1, a beat being 8 pixels.
    function automatic logic [15:0] emit_px(input logic [PB-1:0] p, input logic [1:0] t);
        logic [4:0] r5, b5;
        logic [5:0] g6;
        logic [2:0] rs;
        rs = {1'b0, p[1:0]} + {1'b0, t};
        r5 = p[6:2]   + 5'(rs[2]);
        g6 = p[13:8]  + 6'(p[7]  & t[1]);
        b5 = p[19:15] + 5'(p[14] & t[1]);
        return {r5, g6, b5};
    endfunction

    // SPB source pixels of the word's slice -> 8 output pixels, each REP_X
    // times.  s2_off is the pixel offset of the beat within the word.
    always_comb
        for (int q = 0; q < BEAT_PIX; q++)
            out_data[16*q +: 16] = emit_px(s2_word[PB*(SPB*int'(s2_off) + q / REP_X) +: PB],
                                           thr(s2_yp, q[0]));

    assign out_valid = s2_v;
    assign out_sof   = s2_sof;
    assign out_eol   = s2_eol;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            running  <= 1'b0;
            e_sy     <= '0;
            e_rep    <= '0;
            e_beat   <= '0;
            n_iss    <= '0;
            n_acc    <= '0;
            s1_v     <= 1'b0;
            s1_off   <= 1'b0;
            s1_sof   <= 1'b0;
            s1_eol   <= 1'b0;
            s1_yp    <= 1'b0;
            s2_v     <= 1'b0;
            s2_off   <= 1'b0;
            s2_sof   <= 1'b0;
            s2_eol   <= 1'b0;
            s2_yp    <= 1'b0;
            s2_word  <= '0;
        end else begin
            if (start && state == ST_IDLE) begin
                running <= 1'b1;
                state   <= ST_RUN;
                e_sy    <= '0;
                e_rep   <= '0;
                e_beat  <= '0;
                n_iss   <= '0;
                n_acc   <= '0;
            end

            if (last_xfer)
                n_acc <= n_acc + AW'(1);

            if (!stall) begin
                s1_v    <= issue;
                s1_off  <= e_off;
                s1_sof  <= issue && (e_sy == '0) && (e_rep == '0) && (e_beat == '0);
                s1_eol  <= issue && e_eol;
                s1_yp   <= e_yp;
                if (issue) begin
                    n_iss <= n_iss + AW'(1);
                    if (e_eol) begin
                        e_beat <= '0;
                        if (e_rep == 2'(REP_Y - 1)) begin
                            e_rep <= '0;
                            e_sy  <= e_sy + HW'(1);
                        end else begin
                            e_rep <= e_rep + 2'd1;
                        end
                    end else begin
                        e_beat <= e_beat + OW'(1);
                    end
                end
                s2_v    <= s1_v;
                s2_off  <= s1_off;
                s2_sof  <= s1_sof;
                s2_eol  <= s1_eol;
                s2_yp   <= s1_yp;
                s2_word <= rd_word;
            end

            if (last_xfer && (n_acc == AW'(NACC - 1))) begin
                running <= 1'b0;
                state   <= ST_IDLE;
            end
        end
    end
endmodule
