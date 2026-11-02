// st_film.sv -- GAP accumulators and the FiLM MLP sequencer of the ST block
// engine (docs/st-guided-adr.md; the arithmetic is tools/st_guided.py
// film_consts / film_coeffs, which is normative).
//
// GAP.  The tap sniffs the group stream into st_pack of the FiLM pass (p17,
// 40 int16 channels, 320x180 pixels): one beat per cycle and never stalled,
// so tap_ready is tied high.  Lane j of the b-th beat of a pixel is channel
// 4b + j, b counting from 0 at the pixel's first beat; lane j adds into a
// 25-bit accumulator while b < cfg_g (lanes past the channel count are
// padding).  |S| <= 57600 * 254 < 2**24, so 25 bits hold every sum.  gap_clear
// zeroes all 40 sums in one cycle, when a new plane starts.
//
// The sums are a 40-word shift register that turns by four on every tapped
// beat: lane j of beat b is channel 4b + j, so a beat adds its four lanes
// into the tail and the array rotates, which brings the next beat's group to
// the head.  Ten beats are a whole turn, so the array is in channel order at
// every pixel boundary.  Neither side needs an address mux -- the rotation is
// pure rewiring -- and a flat 40-word array with an indexed read and write
// measured three times the logic.
//
// The MLP reads the same head.  A reduce row sums over channels 0..39, and
// the sum is exact integer arithmetic, so the order is free: product k reads
// gap[k mod 4] (a 4:1 mux) and the array turns by four after every fourth
// product, on the tap's own rotation.  Forty products are ten turns, so the
// array is back in channel order after every row, and the read costs a 4:1
// mux and nothing else.
//
// The tap must therefore be a whole number of pixels of NC/4 beats: cfg_g is
// 10 for the FiLM plane of the net, which the assertions check.
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
// then one coefficient write per group of four channels, in channel order:
// coef_we with coef_grp = c/4, coef_mul[j] = mul_(4c/4+j) and coef_off[j] =
// off_(4c/4+j) (st_norm's port, which always accepts a write).  Ten writes
// per pass.  mlp_busy is high from mlp_start until the last write is issued;
// mlp_start while busy is ignored.
//
// SZ, SG, SB, C0 and KB are per-network constants, so they are parameters
// rather than ROM words: the shift is then a wiring shift, the rounding term
// a constant, and the whole barrel shifter and its variable round-off
// disappear.  tools/st_gen_film.py prints the localparams the package wants
// (ST_FILM_SZ / SG / SB / C0 / KB); the defaults are the p90_ln_w8a8 net's.
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
// Storage.  The GAP sums are 40 registers of 25 bits (1000 FF) with a
// four-lane adder and no address mux; zq is 10 registers of 24 bits; the
// four (mul, off) pairs of the group being filled are 4 x 42 bits.  The
// parameter ROM is one 512x40 array with a registered read: 2 RAM10 blocks in
// 512x20, 380 words used.
//
// ROM image (st_film.hex, one 10-digit hex word per line, written by
// tools/st_gen_film.py, which asserts every field fits):
//
//   word   0 + o         [31:0] br_o, signed          (o = 0..9)
//   word  10 + o         [16:0] Mz_o, < 2**17         (o = 0..9)
//   word  20 + c         [31:0] bg_c, signed          (c = 0..39)
//   word  60 + c         [31:0] bb_c, signed          (c = 0..39)
//   word 100 + c         [16:0] Mg_c, [33:17] Mb_c, both < 2**17
//   word 140 + 8o + w    byte 5w + i = Wr[o][5w + i], int8
//   word 220 + 2c + w    byte 5w + i = Wg[c][5w + i], int8
//   word 300 + 2c + w    byte 5w + i = Wb[c][5w + i], int8
//
// Every weight row is a whole number of 40-bit words -- 40 bytes for Wr, 10
// for Wg and Wb -- so a row is a run of words whose bytes are consecutive
// channels (Wr) or hidden units (Wg, Wb).  The sequencer reads one word per
// five products and holds the address for the whole word, so the read data
// is the byte source directly (no word buffer).
module st_film #(
    parameter int    SZ  = 26,        // zq  = (A*Mz + 2**(SZ-1)) >>> SZ
    parameter int    SG  = 23,        // mul = C0 + (Gb*Mg + 2**(SG-1)) >>> SG
    parameter int    SB  = 20,        // off = (Bb*Mb + 2**(SB-1)) >>> SB
    parameter int    C0  = 26755,     // affine offset, 19-bit signed
    parameter int    KB  = 900,       // reduce bias scale, br_o * KB
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

    output logic        coef_we,      // one write per group of four channels
    output logic [3:0]  coef_grp,     // group: channels 4*grp .. 4*grp + 3
    output logic [17:0] coef_mul [4], // mul of lane j = channel 4*grp + j
    output logic [23:0] coef_off [4]
);
    localparam int NC    = 40;        // channels of the FiLM plane
    localparam int NO    = 10;        // hidden units of the MLP
    localparam int GB    = NC / 4;    // group beats per pixel
    localparam int DEPTH = 512;       // ROM words (380 used)
    localparam int GS    = 6;         // Sg = (S + 2**(GS-1)) >>> GS
    localparam int F     = 8;         // bg_c * 2**F  (golden FILM_F)

    // ROM word map, see the header.
    localparam int A_BR = 0;          // + o
    localparam int A_MZ = 10;         // + o
    localparam int A_BG = 20;         // + c
    localparam int A_BB = 60;         // + c
    localparam int A_MM = 100;        // + c
    localparam int A_WR = 140;        // + 8*o + w
    localparam int A_WG = 220;        // + 2*c + w
    localparam int A_WB = 300;        // + 2*c + w

    localparam signed [55:0] RND_Z = 56'sd1 <<< (SZ - 1);
    localparam signed [55:0] RND_G = 56'sd1 <<< (SG - 1);
    localparam signed [55:0] RND_B = 56'sd1 <<< (SB - 1);
    localparam signed [55:0] C0_EXT = 56'(C0);

    // ------------------------------------------------------------ GAP sums
    // Channel 4*b + j of beat b is always at gap[j] when the beat arrives:
    // a beat adds its four lanes into the tail and rotates the array by four,
    // so the next beat's group comes to the head.  Ten beats are a whole
    // turn.  The MLP turns the same array by four every fourth product, so it
    // reads the head too (see the header).  |S| <= 57600 * 254 < 2**24.
    // The array is one packed vector so that the rotation is a slice and a
    // concatenation, not 36 separate assignments: Efinity maps the first form
    // as a shift register and the second as a 40-way decoder (measured).
    logic [NC-1:0][24:0] gapv;
    wire  [24:0]         gap [NC];    // the same words, for the read mux
    wire                 gap_rot;     // the MLP consumed four sums

    for (genvar i = 0; i < NC; i++) begin : g_gapv
        assign gap[i] = gapv[i];
    end

    assign tap_ready = 1'b1;

    // gap_clear makes the next pixel's beat write each sum instead of adding
    // to it.  Ten beats turn the whole array, so after one pixel every word
    // holds the new pass's sum and nothing of the last pass is left -- the
    // sums are zero at the start of the pass, in the one cycle the port
    // promises, and the array keeps no clear path at all.  A wide
    // synchronous clear would cost 800 FF by taking the array out of the
    // SRLs (measured); the whole array maps to 100 SRLs and 200 FF this way.
    logic fresh;                      // the next pixel's beats overwrite

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gapv  <= '0;
            fresh <= 1'b1;
        end else if (tap_valid || gap_rot) begin
            if (gap_clear) fresh <= 1'b1;
            else if (tap_valid && tap_last) fresh <= 1'b0;
            gapv <= {gapv[3:0], gapv[NC-1:4]};
            for (int j = 0; j < 4; j++)
                gapv[NC - 4 + j] <= fresh
                    ? 25'(signed'(tap_data[10*j +: 10]))
                    : gapv[j] + (tap_valid ? 25'(signed'(tap_data[10*j +: 10]))
                                           : 25'sd0);
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
    // One DSP block, 18x18 signed, in two steps.  a is 36-bit signed and
    // splits into a_lo = a[17:0] and a_hi = a[35:18], with
    //     a = a_hi * 2**18 + a_lo,   a_lo in [0, 2**18)
    // so a_lo is unsigned while the DSP port is signed.  Multiplying the
    // signed reading of a_lo is off by 2**18*b exactly when a_lo[17] is set,
    // and that correction is a shift of b -- no second product:
    //
    //     a*b = a_hi*b*2**18 + a_lo_s*b + (a_lo[17] ? b*2**18 : 0)
    //
    // A product takes three cycles (load, low half, high half) and mac_done
    // pulses in the cycle mac_acc holds the finished sum, so the next product
    // may be loaded in that same cycle -- the row's running sum is chained
    // through ld_init = mac_acc.  The 1290 products of the layer take ~3.9k
    // cycles, well inside the 50k budget of the pass.  No scratch RAM: A, Gb
    // and Bb are consumed in the step that produces them.
    logic               mac_load, mac_done;
    logic signed [35:0] ld_a;
    logic signed [17:0] ld_b;
    logic signed [55:0] ld_init;

    logic signed [17:0] mac_lo, mac_hi, mac_b;
    logic               mac_corr;     // a_lo[17]: add b*2**18 in the low step
    logic        [1:0]  mac_ph;       // 0 idle, 1 low half, 2 high half
    logic signed [55:0] mac_acc;

    wire signed [17:0] mac_op  = (mac_ph == 2'd1) ? mac_lo : mac_hi;
    wire signed [35:0] mac_p   = mac_op * mac_b;          // the DSP
    wire signed [55:0] mac_term = 56'(mac_p);
    wire signed [55:0] mac_corrt = 56'(mac_b) <<< 18;
    wire signed [55:0] mac_low  = mac_term + (mac_corr ? mac_corrt : 56'sd0);
    wire signed [55:0] mac_high = mac_term <<< 18;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_done <= 1'b0;
            mac_ph   <= 2'd0;
            mac_lo   <= '0;
            mac_hi   <= '0;
            mac_b    <= '0;
            mac_corr <= 1'b0;
            mac_acc  <= '0;
        end else begin
            mac_done <= (mac_ph == 2'd2);
            if (mac_load) begin
                mac_ph   <= 2'd1;
                mac_lo   <= ld_a[17:0];
                mac_hi   <= ld_a[35:18];
                mac_b    <= ld_b;
                mac_corr <= ld_a[17];
                mac_acc  <= ld_init;
            end else if (mac_ph == 2'd1) begin
                mac_ph  <= 2'd2;
                mac_acc <= mac_acc + mac_low;
            end else if (mac_ph == 2'd2) begin
                mac_ph  <= 2'd0;
                mac_acc <= mac_acc + mac_high;
            end
        end
    end

    // ----------------------------------------------------- sequencer state
    typedef enum logic [4:0] {
        S_IDLE,
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
    logic        [23:0] zq [NO];      // hidden units

    // ---------------------------------------------------- product operands
    // bi counts finished products of the current word, so S_ROWLOOP loads
    // product bi+1 and S_ROW0 loads product 0.  The sum of the row is
    // re-associated but not re-ordered (all integer, no rounding inside).
    wire [5:0] k_raw = (state == S_ROW0) ? 6'(wc) * 6'd5
                                         : 6'(wc) * 6'd5 + 6'(bi) + 6'd1;
    wire [5:0] k_idx = (k_raw > 6'(NC - 1)) ? 6'(NC - 1) : k_raw;
    // Only products 0..9 of a gamma or beta row are ever loaded, so the clamp
    // never bites; it keeps the zq index inside the array.
    wire [3:0] hidx  = (k_idx > 6'(NO - 1)) ? 4'(NO - 1) : 4'(k_idx);

    // Product k of a reduce row is channel k, and the head holds channels
    // 4*(k/4) .. 4*(k/4)+3, so the read is a 4:1 mux of the lane.
    wire [5:0]         pj      = {4'd0, 2'(k_raw)};
    wire signed [24:0] gap_sel = gap[pj];
    wire signed [25:0] sg_sel  = ($signed(gap_sel) + 26'sd32) >>> GS;
    wire signed [35:0] a_row   = (kind == 2'd0) ? {{10{sg_sel[25]}}, sg_sel}
                                                : {12'b0, zq[hidx]};

    // The ROM holds the row's word for the whole word, so the byte of the
    // product being started is a slice of rom_dout; the address only moves
    // on in the cycle the word's last product finishes.
    wire        row_last = (state == S_ROWLOOP) && mac_done && (bi == 3'd4);
    wire [2:0]  bidx     = (state == S_ROW0) ? 3'd0
                         : (bi == 3'd4)      ? 3'd4 : 3'(bi) + 3'd1;
    wire [7:0]  wbyte    = rom_dout[8*bidx +: 8];

    always_comb begin
        ld_a    = '0;
        ld_b    = '0;
        ld_init = '0;
        unique case (state)
            S_BR1:     begin
                ld_a    = $signed({{4{br[31]}}, br});
                ld_b    = 18'(KB);
                ld_init = '0;
            end
            S_ROW0,
            S_ROWLOOP: begin
                ld_a    = a_row;
                ld_b    = {{10{wbyte[7]}}, wbyte};
                ld_init = ((state == S_ROW0) && (wc == 4'd0)) ? acc_hold
                                                             : mac_acc;
            end
            S_ZQ0:     begin ld_a = mac_acc[35:0]; ld_b = {1'b0, mz};
                             ld_init = RND_Z; end
            S_MM1:     begin ld_a = mac_acc[35:0]; ld_b = {1'b0, mg};
                             ld_init = RND_G; end
            S_OFF0:    begin ld_a = mac_acc[35:0]; ld_b = {1'b0, mb};
                             ld_init = RND_B; end
            default:   ;
        endcase
    end

    assign mac_load = (state == S_BR1) || (state == S_ROW0) ||
                      ((state == S_ROWLOOP) && mac_done && (bi != 3'd4)) ||
                      (state == S_ZQ0) || (state == S_MM1) || (state == S_OFF0);

    // A reduce-row product consumes one of the four head sums; after every
    // fourth the array turns by four, which is the tap's own rotation.
    wire row_load = mac_load && ((state == S_ROW0) || (state == S_ROWLOOP));
    assign gap_rot = row_load && (kind == 2'd0) && (pj == 6'd3);


    // ------------------------------------------------------------ results
    // The shifts are by parameters, so each is a wiring shift; only the
    // state that consumes a product shifts it.
    wire signed [55:0] acc_z = mac_acc >>> SZ;    // A_o * Mz_o
    wire signed [55:0] acc_g = mac_acc >>> SG;    // Gb_c * Mg_c
    wire signed [55:0] acc_b = mac_acc >>> SB;    // Bb_c * Mb_c

    // zq = max(0, rshift_round(A*Mz, SZ)): |A*Mz| < 2**50, so the shift
    // leaves 24 bits; the saturation is defensive.
    wire [23:0] zq_new = acc_z[55] ? 24'd0
                       : (|acc_z[55:24]) ? 24'hFF_FFFF : acc_z[23:0];

    wire signed [55:0] mul_sum = C0_EXT + acc_g;
    wire signed [17:0] mul_new = (mul_sum > 56'sd131071)  ? 18'sd131071
                               : (mul_sum < -56'sd131071) ? -18'sd131071
                               : 18'(mul_sum);

    wire signed [23:0] off_new = (acc_b > 56'sd8388607)  ? 24'sd8388607
                               : (acc_b < -56'sd8388607) ? -24'sd8388607
                               : 24'(acc_b);

    // --------------------------------------------------------- ROM address
    // rom_dout is one cycle behind rom_addr, so each state presents the
    // address of the word the next state consumes.
    wire [8:0] red_nxt = (o == 4'(NO - 1)) ? 9'(A_BG) : 9'(A_BR + 32'(o) + 1);
    wire [8:0] c_nxt   = 9'(A_BG + 32'(c) + 1);

    always_comb begin
        rom_addr = 9'(A_BR);
        unique case (state)
            S_BR0:     rom_addr = 9'(A_MZ + 32'(o));
            S_BR1:     rom_addr = 9'(A_WR + 32'(8 * o));
            S_MZW:     rom_addr = row_base;
            S_ROW0,
            S_ROWLOOP: rom_addr = row_base + 9'(32'(wc)) + 9'(row_last);
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
            for (int i = 0; i < NO; i++) zq[i] <= '0;
        end else begin
            unique case (state)
                S_IDLE: if (mlp_start) begin
                    busy  <= 1'b1;
                    o     <= '0;
                    c     <= '0;
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
                S_ROW0: state <= S_ROWLOOP;
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
                S_MMW: if (mac_done) state <= S_BB0;
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
                S_OFFW: if (mac_done) state <= S_WRITE;
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

    // ------------------------------------------------- coefficient writes
    // One write per group: the four (mul, off) pairs of channels 4g..4g+3
    // are staged in mul_q/off_q as they are computed, and the write goes out
    // in the cycle the fourth channel's off is in its register.
    logic signed [17:0] mul_q [4];
    logic signed [23:0] off_q [4];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < 4; j++) begin
                mul_q[j] <= '0;
                off_q[j] <= '0;
            end
        end else begin
            if ((state == S_MMW) && mac_done) mul_q[c[1:0]] <= mul_new;
            if ((state == S_OFFW) && mac_done) off_q[c[1:0]] <= off_new;
        end
    end

    assign mlp_busy = busy;
    assign coef_we  = (state == S_WRITE) && (c[1:0] == 2'd3);
    assign coef_grp = c[5:2];
    for (genvar j = 0; j < 4; j++) begin : g_coef
        assign coef_mul[j] = mul_q[j];
        assign coef_off[j] = off_q[j];
    end

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

    // The sums are a rotating shift register: the tap must be a whole number
    // of pixels of NC/4 beats, or the array is not in channel order when the
    // MLP reads it.
    always @(posedge clk)
        if (rst_done && tap_valid && (cfg_g != 5'(GB)))
            $error("st_film: cfg_g %0d, the GAP tap needs %0d groups", cfg_g, GB);
    // The tap and the MLP share the rotation.
    always @(posedge clk)
        if (rst_done && gap_rot && (tap_valid || !busy))
            $error("st_film: MLP rotation outside the MLP pass");
    // Beat structure of the tapped stream: tap_last closes a pixel of GB beats.
    logic [3:0] beat_chk;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)               beat_chk <= '0;
        else if (gap_clear)       beat_chk <= '0;
        else if (tap_valid)       beat_chk <= tap_last ? 4'd0 : beat_chk + 4'd1;
    always @(posedge clk)
        if (rst_done && tap_valid && (tap_last !== (beat_chk == 4'(GB - 1))))
            $error("st_film: tap_last on beat %0d of a %0d-beat pixel",
                   beat_chk, GB);

    initial begin
        if (SZ < 1 || SG < 1 || SB < 1 || SZ > 55 || SG > 55 || SB > 55)
            $error("st_film: SZ/SG/SB must be in 1..55 (got %0d/%0d/%0d)",
                   SZ, SG, SB);
        if (C0 < -(1 << 18) || C0 > (1 << 18) - 1)
            $error("st_film: C0 %0d does not fit 19-bit signed", C0);
        if (KB < -(1 << 17) || KB > (1 << 17) - 1)
            $error("st_film: KB %0d does not fit 18-bit signed", KB);
    end
`endif
endmodule
