// st_post.sv -- pass 14 (head) output -> the whole PROC slot.
//
// Input: the engine's group stream from the PW stage, head layer: one group
// beat per pixel, 320x240 pixels in raster order, lanes 0..2 = R, G, B as
// 0..255 in a 10-bit lane, `last` on every beat, `sof` on the first beat of
// the frame, `eol` on the last beat of every line.
// Output: 128-bit beats for tile_dma_wr, one AXI beat per 8 pixels:
//
//   base = slot, 160 beats per line, 720 lines, stride LINE_STRIDE
//   line 3*sy + d, d = 0..2: source line sy with every pixel repeated 4 times
//   px = vid_pkg::pack565(rgb), pixel 0 in bits [15:0]
//   sof on the first beat of the frame, eol on the last beat of every line
//
// That is exactly st_golden.post(), the proc.bin of `--frame --dump`: the
// inverse of st_pre's 4x3 box, so the PROC slot lines up pixel for pixel with
// the ISP slot it came from.
//
// Design.  Two line buffers of 80 x 64 bits, ping-pong: word w of a buffer
// holds source pixels 4w..4w+3 as RGB565.  Output beat b of a line shows
// source pixels 2b and 2b+1, each four times: word b/2, half b mod 2.  Line
// sy fills buffer sy mod 2 while line sy-1 is emitted three times.
//
// Fill and emit stay within one source line of each other, so the bank being
// written is never the bank being read: the fill may only run on line e_sy+1
// while the emitter reads line e_sy, and the emitter leaves line e_sy with the
// issue (and read) of its last beat, before the fill can start line e_sy+2 in
// the same bank.  The fill needs 320 input beats per source line and the
// emission 480 output beats, so the emission sets the rate: about 116k cycles
// per frame without back-pressure.
//
// Resources: the line buffers at 2 x 80 x 64 bits are 1 RAM10; the output
// register and the 4-pixel gather register.  No multiply.
module st_post
    import vid_pkg::*;
#(
    parameter int W     = 320,      // source pixels per line
    parameter int H     = 240,      // source lines
    parameter int REP_X = 4,        // output pixels per source pixel
    parameter int REP_Y = 3         // output lines per source line
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
    localparam int SPB  = BEAT_PIX / REP_X;       // source pixels per output beat, 2
    localparam int OBP  = W * REP_X / BEAT_PIX;   // output beats per line, 160
    localparam int WB   = $clog2(PW4);            // buffer word address
    localparam int OW   = $clog2(OBP);            // beat within the output line
    localparam int SW   = $clog2(W);              // pixel within the source line
    localparam int HW   = $clog2(H + 1);          // source line, 0..H
    localparam int NACC = H * REP_Y * OBP;        // output beats in a frame

    initial begin
        if (W % 4 != 0)
            $error("st_post: W must be a multiple of 4");
        if (REP_X != 4 || SPB != 2)
            $error("st_post: one output beat must be two source pixels x 4");
        if (REP_Y < 2 || REP_Y > 3)
            $error("st_post: REP_Y must be 2 or 3");
    end

    // ---------------------------------------------------------- line buffer
    logic [63:0]   lbuf [2][PW4];
    logic [HW-1:0] e_sy;                // source line being emitted
    logic [OW-1:0] e_beat;              // beat within the output line
    wire           rd_bank = e_sy[0];
    wire [WB-1:0]  rd_addr = WB'(e_beat >> 1);
    logic [63:0]   rd_word;

    // ------------------------------------------------------------- control
    typedef enum logic { ST_IDLE, ST_RUN } state_e;
    state_e state;

    logic          running;
    logic [HW-1:0] fill_line;           // source line being filled, 0..H
    logic [SW-1:0] fill_col;            // pixel within it
    logic [63:0]   stage;               // pixels gathered for the next word
    logic          wr_en;
    logic          wr_bank;
    logic [WB-1:0] wr_addr;
    logic [63:0]   wr_word;

    logic [1:0]    e_rep;               // copy of the source line, 0..REP_Y-1
    logic [16:0]   n_iss;               // output beats issued this frame
    logic [16:0]   n_acc;               // output beats accepted this frame

    assign busy = running;

    // ------------------------------------------------------- emitter address
    wire stall  = out_valid && !out_ready;
    wire src_ok = (fill_line > e_sy);   // that source line is in
    wire issue  = (state == ST_RUN) && !stall && src_ok && (n_iss < 17'(NACC));
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

    // RGB565 of the beat: lanes 0..2 are R, G, B.  Lane 3 is unused (the head
    // layer has C = 3; the stream guarantees it is zero).
    /* verilator lint_off UNUSEDSIGNAL */
    wire [9:0] r10 = in_data[9:0], g10 = in_data[19:10], b10 = in_data[29:20];
    wire [9:0] c3  = in_data[39:30];
    /* verilator lint_on UNUSEDSIGNAL */
    wire [15:0] px_in = 16'(pack565('{r: r10[7:0], g: g10[7:0], b: b10[7:0]}));

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
                stage[16*fill_col[1:0] +: 16] <= px_in;
                if (fill_col[1:0] == 2'd3) begin
                    wr_en   <= 1'b1;
                    wr_bank <= fill_line[0];
                    wr_addr <= fill_col[SW-1:2];
                    wr_word <= {px_in, stage[47:0]};
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
    logic        s1_v, s1_half, s1_sof, s1_eol;
    logic        s2_v, s2_half, s2_sof, s2_eol;
    logic [63:0] s2_word;

    // 2 source pixels of the word's half -> 8 output pixels, each 4 times.
    always_comb
        for (int q = 0; q < BEAT_PIX; q++)
            out_data[16*q +: 16] = s2_word[16*(SPB*int'(s2_half) + q / REP_X) +: 16];

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
            s1_half  <= 1'b0;
            s1_sof   <= 1'b0;
            s1_eol   <= 1'b0;
            s2_v     <= 1'b0;
            s2_half  <= 1'b0;
            s2_sof   <= 1'b0;
            s2_eol   <= 1'b0;
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
                n_acc <= n_acc + 17'(1);

            if (!stall) begin
                s1_v    <= issue;
                s1_half <= e_beat[0];
                s1_sof  <= issue && (e_sy == '0) && (e_rep == '0) && (e_beat == '0);
                s1_eol  <= issue && e_eol;
                if (issue) begin
                    n_iss <= n_iss + 17'(1);
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
                s2_half <= s1_half;
                s2_sof  <= s1_sof;
                s2_eol  <= s1_eol;
                s2_word <= rd_word;
            end

            if (last_xfer && (n_acc == 17'(NACC - 1))) begin
                running <= 1'b0;
                state   <= ST_IDLE;
            end
        end
    end
endmodule
