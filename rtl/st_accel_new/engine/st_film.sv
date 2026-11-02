// st_film.sv -- GAP accumulators and the FiLM MLP sequencer of the ST block
// engine (docs/st-guided-adr.md; the arithmetic is tools/st_guided.py
// film_consts / film_coeffs, which is normative).
//
// GAP.  The tap sniffs the group stream into st_pack of the FiLM pass (p17,
// 40 int16 channels, 320x180 pixels): one beat per cycle and never stalled,
// so tap_ready is tied high.  Lane j of the b-th beat of a pixel is channel
// 4b + j, b counting from 0 after tap_last; lane j adds into a 25-bit
// accumulator while b < cfg_g (lanes past the channel count are padding).
// |S| <= 57600 * 254 < 2**24, so 25 bits hold every sum.  gap_clear zeroes
// all 40 sums in one cycle, when a new plane starts.
//
// MLP.  After the pass, mlp_start runs the sequencer of film_coeffs on the
// GAP sums, all integer, `>>>` arithmetic, rshift_round(v, s) = (v + 2**(s-1))
// >>> s:
//
//   Sg_c  = (S_c + 32) >>> 6                             19 bit
//   A_o   = br_o * KB + sum_c Wr[o][c] * Sg_c            o < 10
//   zq_o  = max(0, rshift_round(A_o * Mz_o, SZ))         24 bit, >= 0
//   Gb_c  = bg_c * 256 + sum_o Wg[c][o] * zq_o           c < 40
//   Bb_c  = bb_c * 256 + sum_o Wb[c][o] * zq_o
//   mul_c = clamp(C0 + rshift_round(Gb_c * Mg_c, SG), +-(2**17 - 1))
//   off_c = clamp(rshift_round(Bb_c * Mb_c, SB), +-(2**23 - 1))
//
// then one coefficient write per channel, in channel order: coef_we with
// coef_idx = c, coef_mul = mul_c, coef_off = off_c (st_norm's port, which
// always accepts a write).  mlp_busy is high from mlp_start until the last
// write is issued; mlp_start while busy is ignored.
//
// One serial multiply-accumulate unit does every product: a (36-bit signed)
// times b (18-bit signed) by shift-add over b's bits, 18 steps, into a
// 56-bit signed accumulator.  The widest product is Gb*Mg, under 2**52, and
// the widest folded sum is A, under 2**33.  A product takes 19 cycles and
// the 1290 of the layer take ~24.5k cycles, inside the 50k budget of the
// pass.  No DSP: the multiply is one 56-bit adder and a 54-bit shift
// register, and no scratch RAM is needed either, because A, Gb and Bb are
// consumed in the step that produces them.
//
// Storage.  The GAP sums are 40 registers of 25 bits (1000 FF) read through
// a 40:1 mux; zq is 16 registers of 24 bits.  The parameter ROM is one
// 512x40 array with a registered read: 2 RAM10 blocks in 256x40, 383 words
// used.
//
// ROM image (st_film.hex, one 10-digit hex word per line, written by
// tools/st_gen_film.py, which asserts every field fits):
//
//   word   0             [5:0] SB, [11:6] SG, [17:12] SZ
//   word   1             [18:0] C0, signed
//   word   2             [17:0] KB, signed
//   word   3 + o         [31:0] br_o, signed          (o = 0..9)
//   word  13 + o         [16:0] Mz_o, < 2**17         (o = 0..9)
//   word  23 + c         [31:0] bg_c, signed          (c = 0..39)
//   word  63 + c         [31:0] bb_c, signed          (c = 0..39)
//   word 103 + c         [16:0] Mg_c, [33:17] Mb_c, both < 2**17
//   word 143 + 8o + w    byte 5w + i = Wr[o][5w + i], int8
//   word 223 + 2c + w    byte 5w + i = Wg[c][5w + i], int8
//   word 303 + 2c + w    byte 5w + i = Wb[c][5w + i], int8
//
// Every weight row is a whole number of 40-bit words -- 40 bytes for Wr, 10
// for Wg and Wb -- so a row is a run of words whose bytes are consecutive
// channels (Wr) or hidden units (Wg, Wb).  The sequencer reads one word per
// five products.
module st_film #(
    parameter string HEX = "rtl/st_accel_new/gen/guided/st_film.hex"
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [4:0]  cfg_g,        // group beats per pixel (10)

    input  logic        gap_clear,    // one cycle: zero the sums

    input  logic        tap_valid,    // a group beat was transferred
    output logic        tap_ready,    // always 1: the tap never stalls
    input  logic [39:0] tap_data,     // 4 x 10-bit signed lanes
    input  logic        tap_last,     // last group beat of the pixel

    input  logic        mlp_start,    // one cycle, ignored while busy
    output logic        mlp_busy,

    output logic        coef_we,      // one write per channel, in order
    output logic [6:0]  coef_idx,
    output logic [17:0] coef_mul,
    output logic [23:0] coef_off
);
    localparam int NC    = 40;        // channels of the FiLM plane
    localparam int NO    = 10;        // hidden units of the MLP
    localparam int DEPTH = 512;       // ROM words (383 used)
    localparam int GB    = NC / 4;    // group beats per pixel at most

    // ROM word map, see the header.
    localparam int A_SC = 0;          // SZ, SG, SB
    localparam int A_C0 = 1;
    localparam int A_KB = 2;
    localparam int A_BR = 3;          // + o
    localparam int A_MZ = 13;         // + o
    localparam int A_BG = 23;         // + c
    localparam int A_BB = 63;         // + c
    localparam int A_MM = 103;        // + c
    localparam int A_WR = 143;        // + 8*o + w
    localparam int A_WG = 223;        // + 2*c + w
    localparam int A_WB = 303;        // + 2*c + w

    localparam int MUL_MAX = (1 << 17) - 1;   // mul is 18-bit signed
    localparam int OFF_MAX = (1 << 23) - 1;   // off is 24-bit signed

    // ------------------------------------------------------------ GAP sums
    logic signed [24:0] gap [NC];
    logic        [4:0]  beat;         // group beat of the current pixel
    wire                g_ok = (beat < cfg_g) && (beat < 5'(GB));

    assign tap_ready = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NC; i++) gap[i] <= '0;
            beat <= '0;
        end else if (gap_clear) begin
            for (int i = 0; i < NC; i++) gap[i] <= '0;
            beat <= '0;
        end else if (tap_valid) begin
            if (g_ok)
                for (int j = 0; j < 4; j++)
                    gap[4*beat + j] <= gap[4*beat + j] +
                                       25'(signed'(tap_data[10*j +: 10]));
            beat <= tap_last ? 5'd0 : beat + 5'd1;
        end
    end

    // --------------------------------------------------------------- ROM
    logic [8:0]  rom_addr;
    logic [39:0] rom_dout;
    logic [39:0] rom [DEPTH];

    initial begin
        for (int a = 0; a < DEPTH; a++) rom[a] = '0;
        $readmemh(HEX, rom);
    end

    always_ff @(posedge clk) rom_dout <= rom[rom_addr];

    // ---------------------------------------------------------- serial MAC
    // mac_load starts a product (load, then 18 shift-add steps) and mac_done
    // pulses in the cycle mac_acc holds the finished sum, so the next product
    // may be loaded in that same cycle.
    logic               mac_load, mac_done, mac_run;
    logic signed [35:0] ld_a;
    logic signed [17:0] ld_b;
    logic signed [55:0] ld_init;

    logic        [4:0]  mac_t;
    logic signed [53:0] mac_a;
    logic signed [17:0] mac_b;
    logic signed [55:0] mac_acc;

    // b is a two's complement multiplier: bits 0..16 add a*2**t and bit 17
    // (the sign bit, reached after 17 arithmetic shifts) subtracts a*2**17.
    wire signed [55:0] mac_term = {{2{mac_a[53]}}, mac_a};
    wire signed [55:0] mac_add  = (mac_t == 5'd17) ? -mac_term : mac_term;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_run  <= 1'b0;
            mac_done <= 1'b0;
            mac_t    <= '0;
            mac_a    <= '0;
            mac_b    <= '0;
            mac_acc  <= '0;
        end else begin
            mac_done <= 1'b0;
            if (mac_load) begin
                mac_run  <= 1'b1;
                mac_t    <= 5'd0;
                mac_a    <= {{18{ld_a[35]}}, ld_a};
                mac_b    <= ld_b;
                mac_acc  <= ld_init;
            end else if (mac_run) begin
                mac_acc <= mac_acc + (mac_b[0] ? mac_add : 56'sd0);
                mac_a   <= mac_a <<< 1;
                mac_b   <= {mac_b[17], mac_b[17:1]};
                mac_t   <= mac_t + 5'd1;
                if (mac_t == 5'd17) begin
                    mac_run  <= 1'b0;
                    mac_done <= 1'b1;
                end
            end
        end
    end

    // ----------------------------------------------------- sequencer state
    typedef enum logic [4:0] {
        S_IDLE,
        S_SCAL0, S_SCAL1, S_SCAL2,       // SZ/SG/SB, C0, KB
        S_BR0, S_BR1, S_MZW,             // br_o, Mz_o, br_o*KB
        S_ROW0, S_ROWLOOP, S_ROWDONE,    // one weight row, 5 products per word
        S_ZQ0, S_ZQW,                    // A_o * Mz_o
        S_BG0,                           // bg_c, gamma row
        S_MM0, S_MM1, S_MMW,             // Mg_c/Mb_c, Gb_c * Mg_c
        S_BB0,                           // bb_c, beta row
        S_OFF0, S_OFFW, S_WRITE          // Bb_c * Mb_c, the coefficient
    } state_t;

    state_t             state;
    logic               busy;
    logic        [3:0]  o, wc;
    logic        [5:0]  c;
    logic        [2:0]  bi;           // products done in the current word
    logic        [1:0]  kind;         // 0 reduce, 1 gamma, 2 beta
    logic        [3:0]  nwords;
    logic        [8:0]  row_base;
    logic signed [55:0] acc_hold;     // the bias term of the row's sum

    logic signed [31:0] br;
    logic        [16:0] mz, mg, mb;
    logic signed [17:0] kb;
    logic signed [18:0] c0;
    logic        [5:0]  sz, sg, sb;
    logic signed [17:0] mul;
    logic signed [23:0] off;
    logic        [23:0] zq [16];      // hidden units, 10 used

    // ---------------------------------------------------- product operands
    // bi counts finished products of the current word, so S_ROWLOOP loads
    // product bi+1 and S_ROW0 loads product 0.  The sum of the row is
    // re-associated but not re-ordered (all integer, no rounding inside).
    wire [5:0] k_raw = (state == S_ROW0) ? 6'(wc) * 6'd5
                                         : 6'(wc) * 6'd5 + 6'(bi) + 6'd1;
    // Only products 0..4 of a word are ever loaded, so the clamp never bites;
    // it keeps the array index inside the sums for the unused combination.
    wire [5:0] k_idx = (k_raw > 6'(NC - 1)) ? 6'(NC - 1) : k_raw;
    wire [5:0] widx  = k_idx;         // channel of a reduce row
    wire [3:0] hidx  = 4'(k_idx);     // hidden unit of a gamma or beta row

    wire signed [24:0] gap_sel = gap[widx];
    wire signed [25:0] sg_sel  = ($signed(gap_sel) + 26'sd32) >>> 6;
    wire signed [35:0] a_row   = (kind == 2'd0) ? {{10{sg_sel[25]}}, sg_sel}
                                                : {12'b0, zq[hidx]};

    logic [47:0] wbuf;                // the weight word being consumed
    wire  [7:0]  wbyte = (state == S_ROW0) ? rom_dout[7:0] : wbuf[8*(bi+1) +: 8];

    // The round-up term belongs to the product being started; the shift that
    // finishes a product belongs to the state that holds its result.
    wire [5:0] rnd_sh = (state == S_MM1) ? sg : (state == S_OFF0) ? sb : sz;
    wire [5:0] sh_amt = (state == S_MMW) ? sg : (state == S_OFFW) ? sb : sz;
    wire signed [55:0] rnd = 56'sd1 <<< (rnd_sh - 6'd1);

    always_comb begin
        ld_a    = '0;
        ld_b    = '0;
        ld_init = rnd;
        unique case (state)
            S_BR1:     begin
                ld_a    = $signed({{4{br[31]}}, br});
                ld_b    = kb;
                ld_init = '0;
            end
            S_ROW0,
            S_ROWLOOP: begin
                ld_a    = a_row;
                ld_b    = {{10{wbyte[7]}}, wbyte};
                ld_init = (state == S_ROW0 && wc == 4'd0) ? acc_hold : mac_acc;
            end
            S_ZQ0:     begin ld_a = mac_acc[35:0]; ld_b = {1'b0, mz}; end
            S_MM1:     begin ld_a = mac_acc[35:0]; ld_b = {1'b0, mg}; end
            S_OFF0:    begin ld_a = mac_acc[35:0]; ld_b = {1'b0, mb}; end
            default:   ;
        endcase
    end

    assign mac_load = (state == S_BR1) || (state == S_ROW0) ||
                      ((state == S_ROWLOOP) && mac_done && (bi != 3'd4)) ||
                      (state == S_ZQ0) || (state == S_MM1) || (state == S_OFF0);

    // ------------------------------------------------------------ results
    wire signed [55:0] acc_shr = mac_acc >>> sh_amt;

    // zq = max(0, rshift_round(A*Mz, SZ)): |A*Mz| < 2**50, so the shift
    // leaves 24 bits; the saturation is defensive.
    wire [23:0] zq_new = acc_shr[55] ? 24'd0
                       : (|acc_shr[55:24]) ? 24'hFF_FFFF : acc_shr[23:0];

    wire signed [55:0] mul_sum = $signed({{37{c0[18]}}, c0}) + acc_shr;
    wire signed [17:0] mul_new = (mul_sum > 56'sd131071)  ? 18'sd131071
                               : (mul_sum < -56'sd131071) ? -18'sd131071
                               : 18'(mul_sum);

    wire signed [23:0] off_new = (acc_shr > 56'sd8388607)  ? 24'sd8388607
                               : (acc_shr < -56'sd8388607) ? -24'sd8388607
                               : 24'(acc_shr);

    // --------------------------------------------------------- ROM address
    // rom_dout is one cycle behind rom_addr, so each state presents the
    // address of the word the next state consumes.
    wire [8:0] red_nxt = (o == 4'(NO - 1)) ? 9'(A_BG) : 9'(A_BR + 32'(o) + 1);
    wire [8:0] c_nxt   = 9'(A_BG + 32'(c) + 1);

    always_comb begin
        rom_addr = 9'(A_SC);
        unique case (state)
            S_SCAL0:   rom_addr = 9'(A_C0);
            S_SCAL1:   rom_addr = 9'(A_KB);
            S_SCAL2:   rom_addr = 9'(A_BR);
            S_BR0:     rom_addr = 9'(A_MZ + 32'(o));
            S_BR1:     rom_addr = 9'(A_WR + 32'(8 * o));
            // S_ROW0 captures the word, so the wait states present its address.
            S_MZW:     rom_addr = row_base;
            S_ROW0,
            S_ROWLOOP: rom_addr = row_base + 9'(32'(wc) + 1);
            S_ROWDONE: rom_addr = (kind == 2'd0) ? red_nxt
                               : (kind == 2'd1) ? 9'(A_MM + 32'(c)) : c_nxt;
            S_ZQ0,
            S_ZQW:     rom_addr = red_nxt;
            S_BG0:     rom_addr = 9'(A_WG + 32'(2 * c));
            S_MM0:     rom_addr = 9'(A_MM + 32'(c));
            S_MM1,
            S_MMW:     rom_addr = 9'(A_BB + 32'(c));
            S_BB0:     rom_addr = 9'(A_WB + 32'(2 * c));
            S_OFF0,
            S_OFFW,
            S_WRITE:   rom_addr = c_nxt;
            default:   ;
        endcase
    end

    // ----------------------------------------------------------- sequencer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            o        <= '0;
            c        <= '0;
            wc       <= '0;
            bi       <= '0;
            kind     <= '0;
            nwords   <= '0;
            row_base <= '0;
            acc_hold <= '0;
            br       <= '0;
            mz       <= '0;
            mg       <= '0;
            mb       <= '0;
            kb       <= '0;
            c0       <= '0;
            sz       <= '0;
            sg       <= '0;
            sb       <= '0;
            mul      <= '0;
            off      <= '0;
            for (int i = 0; i < 16; i++) zq[i] <= '0;
        end else begin
            unique case (state)
                S_IDLE: if (mlp_start) begin
                    busy  <= 1'b1;
                    o     <= '0;
                    c     <= '0;
                    state <= S_SCAL0;
                end
                S_SCAL0: begin
                    sb    <= rom_dout[5:0];
                    sg    <= rom_dout[11:6];
                    sz    <= rom_dout[17:12];
                    state <= S_SCAL1;
                end
                S_SCAL1: begin
                    c0    <= $signed(rom_dout[18:0]);
                    state <= S_SCAL2;
                end
                S_SCAL2: begin
                    kb    <= $signed(rom_dout[17:0]);
                    state <= S_BR0;
                end
                S_BR0: begin
                    br    <= $signed(rom_dout[31:0]);
                    state <= S_BR1;
                end
                S_BR1: begin
                    mz       <= rom_dout[16:0];
                    kind     <= 2'd0;
                    nwords   <= 4'd8;
                    wc       <= '0;
                    bi       <= '0;
                    row_base <= 9'(A_WR + 32'(8 * o));
                    state    <= S_MZW;
                end
                S_MZW: if (mac_done) begin
                    acc_hold <= mac_acc;              // br_o * KB
                    state    <= S_ROW0;
                end
                S_ROW0: begin
                    wbuf  <= {8'b0, rom_dout};
                    state <= S_ROWLOOP;
                end
                S_ROWLOOP: if (mac_done) begin
                    if (bi != 3'd4) begin
                        bi <= bi + 3'd1;
                    end else if (wc == nwords - 4'd1) begin
                        state <= S_ROWDONE;
                    end else begin
                        wc    <= wc + 4'd1;
                        bi    <= '0;
                        state <= S_ROW0;
                    end
                end
                S_ROWDONE: state <= (kind == 2'd0) ? S_ZQ0
                                 : (kind == 2'd1) ? S_MM0 : S_OFF0;
                S_ZQ0: state <= S_ZQW;
                S_ZQW: if (mac_done) begin
                    zq[o] <= zq_new;
                    if (o == 4'(NO - 1)) begin
                        c     <= '0;
                        state <= S_BG0;
                    end else begin
                        o     <= o + 4'd1;
                        state <= S_BR0;
                    end
                end
                S_BG0: begin
                    acc_hold <= {{16{rom_dout[31]}}, rom_dout[31:0], 8'b0};
                    kind     <= 2'd1;
                    nwords   <= 4'd2;
                    wc       <= '0;
                    bi       <= '0;
                    row_base <= 9'(A_WG + 32'(2 * c));
                    state    <= S_ROW0;
                end
                S_MM0: begin
                    mg    <= rom_dout[16:0];
                    mb    <= rom_dout[33:17];
                    state <= S_MM1;
                end
                S_MM1: state <= S_MMW;
                S_MMW: if (mac_done) begin
                    mul   <= mul_new;
                    state <= S_BB0;
                end
                S_BB0: begin
                    acc_hold <= {{16{rom_dout[31]}}, rom_dout[31:0], 8'b0};
                    kind     <= 2'd2;
                    nwords   <= 4'd2;
                    wc       <= '0;
                    bi       <= '0;
                    row_base <= 9'(A_WB + 32'(2 * c));
                    state    <= S_ROW0;
                end
                S_OFF0: state <= S_OFFW;
                S_OFFW: if (mac_done) begin
                    off   <= off_new;
                    state <= S_WRITE;
                end
                S_WRITE: begin
                    if (c == 6'(NC - 1)) begin
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end else begin
                        c     <= c + 6'd1;
                        state <= S_BG0;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    assign mlp_busy = busy;
    assign coef_we  = (state == S_WRITE);
    assign coef_idx = 7'(c);
    assign coef_mul = mul;
    assign coef_off = off;

`ifndef SYNTHESIS
    // rst_done gates the checks: with --x-initial unique the state bits are
    // random before the first reset edge.
    logic rst_done;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) rst_done <= 1'b0;
        else        rst_done <= 1'b1;

    // The folded sums are 36-bit signed by the ADR's value ranges; a wider
    // one would silently truncate at the multiply.
    always @(posedge clk)
        if (rst_done && ((state == S_ZQ0) || (state == S_MM1) || (state == S_OFF0)) &&
            mac_acc[55:35] != {21{mac_acc[35]}})
            $error("st_film: folded sum %0d does not fit 36 bits", mac_acc);
    // A tap beat while the sums are being cleared would lose it.
    always @(posedge clk)
        if (rst_done && gap_clear && tap_valid)
            $error("st_film: gap_clear and tap_valid in the same cycle");
    // The sums are indexed by 4*beat + j, so cfg_g must stay inside NC/4.
    always @(posedge clk)
        if (rst_done && tap_valid && cfg_g > 5'(GB))
            $error("st_film: cfg_g %0d exceeds %0d groups", cfg_g, GB);
`endif
endmodule
