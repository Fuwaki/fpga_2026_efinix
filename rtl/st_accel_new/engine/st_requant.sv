// st_requant.sv -- one requantisation lane of the ST block engine.
//
// Computes exactly clamp(f32_mul_round(x, mant, 24 - k), lo, hi), the integer
// emulation of round_away(f32(x) * f32(r)) defined by tools/st_golden.py
// (docs/st-accel-engine-adr.md):
//
//   r = mant * 2**(exp - 24), k = 24 - exp      (in_k is 16..47)
//   p = |x| * mant                              exact, < 2**48
//   sh = max(lead(p) - 23, 0)                   round p to 24 significant
//   q  = p >> sh                                  bits, nearest even
//   v  = (q + up) << sh                         f32 product, scaled by 2**k
//   y  = (v + 2**(k-1)) >> k                    round half away from zero
//   y  = -y if x < 0
//   y  = clamp(y, lo, hi)
//
// The last two shifts of that reference are one: with d = k - sh,
// y = (q + 2**(d-1)) >> d.  The clamp is 10 bit, so only q[23:12] reaches the
// output -- the round-up of the 24-bit step adds one to q, and that carry
// crosses bit 12 only when q[11:0] is all ones, which the tie bit already
// implies.  The lane therefore carries q[23:12], the shift and the clamp, not
// the 48-bit product or the 24-bit significand.  d <= 12 leaves y >= 2048 and
// d >= 27 leaves y = 0; both saturate and are folded into the shift clamp.
//
// Fixed latency LAT = 6 cycles, II = 1, no back-pressure: a beat accepted on
// an in_valid cycle leaves LAT cycles later.  The stages are
//
//   1  operands: |x| and mant, the DSP block's input registers
//   2  24 x 24 product, exact -- the DSP block's output register
//   3  leading one, round to 24 significant bits, ties to even, shift amount
//   4  shift back to the output scale, round half away from zero, sign, clamp
//   5, 6  the beat: the finished code and its tag
//
// The operand stage keeps the caller's input logic (an accumulator add, a
// tile select) off the multiplier path.
//
// |x| is smaller than 2**(XW-1) <= 2**24 (an accumulator, or an add output
// below 2**10); size XW to the source, the multiplier is (XW-1) x 24 bits.
// mant is normalised (bit 23 set), so the unclamped result is under 2**33;
// lo and hi are 10 bit, so the clamp at stage 4 compares at 12 bits and
// anything at or above 2047 clamps identically.
module st_requant #(
    parameter int XW = 25,          // in_x: |in_x| < 2**(XW-1), at most 25
    parameter int TW = 1            // in_tag width, carried with the beat
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 in_valid,
    input  logic signed [XW-1:0] in_x,      // |x| < 2**24
    input  logic        [23:0]   in_mant,   // msb set (normalised)
    input  logic        [5:0]    in_k,      // fraction bits = 24 - exp, 16..47
    input  logic signed [9:0]    in_lo,
    input  logic signed [9:0]    in_hi,
    input  logic        [TW-1:0] in_tag,

    output logic                 out_valid,
    output logic signed [9:0]    out_y,
    output logic        [TW-1:0] out_tag
);
    // Cycles from in_valid to out_valid; an input beat's result appears
    // exactly LAT posedges later.
    localparam int LAT = 6;

    localparam int AW = XW - 1; // |x|: a narrower lane maps to fewer DSP blocks
    localparam int PW = 48;     // |x| * mant
    localparam int NW = 25;     // q[23:12] with the tie and round bits below
    localparam int QW = 13;     // q[23:12] plus the carry out of q[11:0]
    localparam int SW = 4;      // the trailing shift k - sh - 12, 0..15

    // ---------------------------------------------------- stage 1: operands
    // Registers are named after the stage before them (s0 = stage 1).  The
    // operand and product registers have no reset, so they sit in the
    // DSP block.
    logic [AW-1:0]     ax_s0;
    logic [23:0]       mant_s0;
    logic              neg_s0;
    logic [4:0]        k_s0;    // in_k - 16: the 16..47 range in five bits
    logic signed [9:0] lo_s0, hi_s0;
    logic [TW-1:0]     tag_s0;
    logic              vld_s0;

    wire [AW-1:0] ax = in_x[XW-1] ? AW'(-in_x) : AW'(in_x);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vld_s0 <= 1'b0;
        else        vld_s0 <= in_valid;
    end

    always_ff @(posedge clk) begin
        if (in_valid) begin
            ax_s0   <= ax;
            mant_s0 <= in_mant;
            neg_s0  <= in_x[XW-1];
            k_s0    <= 5'(in_k - 6'd16);
            lo_s0   <= in_lo;
            hi_s0   <= in_hi;
            tag_s0  <= in_tag;
        end
    end

    // ----------------------------------------------------- stage 2: product
    logic [PW-1:0]     p_s1;
    logic              neg_s1;
    logic [4:0]        k_s1;
    logic signed [9:0] lo_s1, hi_s1;
    logic [TW-1:0]     tag_s1;
    logic              vld_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vld_s1 <= 1'b0;
        else        vld_s1 <= vld_s0;
    end

    always_ff @(posedge clk) begin
        if (vld_s0) begin
            p_s1   <= PW'(ax_s0) * PW'(mant_s0);
            neg_s1 <= neg_s0;
            k_s1   <= k_s0;
            lo_s1  <= lo_s0;
            hi_s1  <= hi_s0;
            tag_s1 <= tag_s0;
        end
    end

    // ------------------------------ stage 3: leading one, round to 24 bits
    logic [QW-1:0]     wq_s2;
    logic [SW-1:0]     shf_s2;
    logic              neg_s2;
    logic signed [9:0] lo_s2, hi_s2;
    logic [TW-1:0]     tag_s2;
    logic              vld_s2;

    // sh = max(lead - 23, 0): the bits the 24-bit significand gives up.  p is
    // zero only for x == 0, where sh = 0 keeps everything at zero.
    logic [5:0] lead;
    always_comb begin
        lead = 6'd0;
        for (int i = 0; i < PW; i++)            // highest set bit wins
            if (p_s1[i]) lead = 6'(i);
    end
    wire [4:0] sh = (lead > 6'd23) ? 5'(lead - 6'd23) : 5'd0;

    // win = {p, 1'b0} >> sh: bit j is p[sh-1+j], so win[0] is the round bit,
    // win[12:1] is q[11:0] and win[24:13] is q[23:12] (the leading one of p
    // sits at 23 + sh by construction, so nothing above win[24] is lost).
    wire [NW-1:0] win = NW'({p_s1, 1'b0} >> sh);

    // Round to nearest even: up needs the round bit and, on an exact tie, an
    // odd q[0] = win[1].  Only a carry out of q[11:0] is visible at stage 4,
    // and that carry already implies the tie bit (all twelve bits set), so
    // the p bits below the round bit never affect the result.
    wire          carry = win[0] & (&win[12:1]);
    wire [QW-1:0] wq    = QW'({1'b0, win[NW-1:13]}) + QW'(carry);

    // Stage 4 shifts q[23:12], so its amount is d - 12 with d = k - sh and k
    // = k_s1 + 16.  An amount of 0 (d <= 12, y >= 2048) or 15 (d >= 27, y =
    // 0) covers the two saturated ends.
    wire signed [6:0] e   = $signed({2'b0, k_s1}) + 7'sd4 - $signed({2'b0, sh});
    wire [SW-1:0]     shf = (e <= 7'sd0) ? 4'd0 : (e >= 7'sd15) ? 4'd15 : 4'(e);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s2 <= 1'b0;
        end else begin
            vld_s2 <= vld_s1;
            if (vld_s1) begin
                wq_s2   <= wq;
                shf_s2  <= shf;
                neg_s2  <= neg_s1;
                lo_s2   <= lo_s1;
                hi_s2   <= hi_s1;
                tag_s2  <= tag_s1;
            end
        end
    end

    // ---- stage 4: shift back, round half away from zero, sign, clamp
    // {wq, 1'b0} >> shf is q >> (shf - 1): bit 0 is the round bit and the
    // rest is q >> shf, so rounding half away from zero is one increment.
    // q[11:0] never moves the result (see the header), so only its all ones
    // case -- the carry already folded in at stage 3 -- was kept.
    wire [QW:0]   wsh = (QW+1)'({wq_s2, 1'b0} >> shf_s2);
    wire [QW:0]   yv  = {1'b0, wsh[QW:1]} + (QW+1)'(wsh[0]);
    wire          sat = |yv[QW:11];         // >= 2048: past every clamp hi
    wire [10:0]   mag = sat ? 11'd2047 : yv[10:0];

    logic              vld_s3;
    logic signed [9:0] y_s3;
    logic [TW-1:0]     tag_s3;

    wire signed [11:0] mags = $signed({1'b0, mag});
    wire signed [11:0] val  = neg_s2 ? -mags : mags;
    wire signed [11:0] lo12 = {{2{lo_s2[9]}}, lo_s2};
    wire signed [11:0] hi12 = {{2{hi_s2[9]}}, hi_s2};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s3 <= 1'b0;
        end else begin
            vld_s3 <= vld_s2;
            if (vld_s2) begin
                y_s3   <= (val < lo12) ? lo_s2 : (val > hi12) ? hi_s2 : 10'(val);
                tag_s3 <= tag_s2;
            end
        end
    end

    // --------------------------------------------------- stages 5, 6: beat
    logic              vld_s4;
    logic signed [9:0] y_s4;
    logic [TW-1:0]     tag_s4;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s4 <= 1'b0;
        end else begin
            vld_s4 <= vld_s3;
            if (vld_s3) begin
                y_s4   <= y_s3;
                tag_s4 <= tag_s3;
            end
        end
    end

    logic              vld_s5;
    logic signed [9:0] y_s5;
    logic [TW-1:0]     tag_s5;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s5 <= 1'b0;
        end else begin
            vld_s5 <= vld_s4;
            if (vld_s4) begin
                y_s5   <= y_s4;
                tag_s5 <= tag_s4;
            end
        end
    end

    assign out_valid = vld_s5;
    assign out_y     = y_s5;
    assign out_tag   = tag_s5;

    initial begin
        if (XW < 2 || XW > 25) $error("st_requant: XW must be 2..25 (|x| < 2**24)");
        if (TW < 1)  $error("st_requant: TW must be at least 1");
    end

endmodule
