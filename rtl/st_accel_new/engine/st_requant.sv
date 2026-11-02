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
// Fixed latency LAT = 6 cycles, II = 1, no back-pressure: a beat accepted on
// an in_valid cycle leaves LAT cycles later.  The stages are
//
//   1  input register (the multiplier's operand registers)
//   2  24 x 24 product, exact -- one DSP block
//   3  leading-one detect, shift amount
//   4  round to 24 significant bits, ties to even
//   5  shift back to the 2**k scale of the f32 product
//   6  add the half, shift right by k, sign, clamp to [lo, hi], output register
//
// |x| is smaller than 2**24 (an accumulator, or an add output below 2**10)
// and mant is normalised (bit 23 set), so the unclamped result is under
// 2**33; the saturation at stage 5 keeps the compare at 12 bits -- lo and hi
// are 10 bit, so anything at or above 2048 clamps identically.
module st_requant #(
    parameter int XW = 25,          // in_x: |in_x| < 2**24
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

    localparam int AW = 24;     // |x|
    localparam int PW = 48;     // |x| * mant
    localparam int QW = 25;     // 24-bit significand plus the round-up carry
    localparam int VW = 49;     // significand shifted back: < 2**48 + carry
    localparam int MW = 34;     // quotient before the 12-bit saturation

    // ---------------------------------------------------- stage 1: operands
    logic              neg_s1;
    logic [AW-1:0]     ax_s1;
    logic [23:0]       mant_s1;
    logic [5:0]        k_s1;
    logic signed [9:0] lo_s1, hi_s1;
    logic [TW-1:0]     tag_s1;
    logic              vld_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s1 <= 1'b0;
        end else begin
            vld_s1 <= in_valid;
            if (in_valid) begin
                neg_s1  <= in_x[XW-1];
                ax_s1   <= in_x[XW-1] ? AW'(-in_x) : AW'(in_x);
                mant_s1 <= in_mant;
                k_s1    <= in_k;
                lo_s1   <= in_lo;
                hi_s1   <= in_hi;
                tag_s1  <= in_tag;
            end
        end
    end

    // ------------------------------------------------- stage 2: the product
    logic [PW-1:0]     p_s2;
    logic              neg_s2;
    logic [5:0]        k_s2;
    logic signed [9:0] lo_s2, hi_s2;
    logic [TW-1:0]     tag_s2;
    logic              vld_s2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s2 <= 1'b0;
        end else begin
            vld_s2 <= vld_s1;
            if (vld_s1) begin
                p_s2   <= PW'(ax_s1) * PW'(mant_s1);
                neg_s2 <= neg_s1;
                k_s2   <= k_s1;
                lo_s2  <= lo_s1;
                hi_s2  <= hi_s1;
                tag_s2 <= tag_s1;
            end
        end
    end

    // ---------------------------------------- stage 3: leading one, shift
    // sh = max(lead - 23, 0): the bits the 24-bit significand gives up.  p is
    // zero only for x == 0, where sh = 0 keeps everything at zero.
    logic [PW-1:0]     p_s3;
    logic [4:0]        sh_s3;
    logic              neg_s3;
    logic [5:0]        k_s3;
    logic signed [9:0] lo_s3, hi_s3;
    logic [TW-1:0]     tag_s3;
    logic              vld_s3;

    logic [5:0] lead;
    always_comb begin
        lead = 6'd0;
        for (int i = 0; i < PW; i++)            // highest set bit wins
            if (p_s2[i]) lead = 6'(i);
    end
    wire [4:0] sh_now = (lead > 6'd23) ? 5'(lead - 6'd23) : 5'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s3 <= 1'b0;
        end else begin
            vld_s3 <= vld_s2;
            if (vld_s2) begin
                p_s3   <= p_s2;
                sh_s3  <= sh_now;
                neg_s3 <= neg_s2;
                k_s3   <= k_s2;
                lo_s3  <= lo_s2;
                hi_s3  <= hi_s2;
                tag_s3 <= tag_s2;
            end
        end
    end

    // ------------------------------ stage 4: round to 24 bits, ties to even
    logic [QW-1:0]     q_s4;
    logic [4:0]        sh_s4;
    logic              neg_s4;
    logic [5:0]        k_s4;
    logic signed [9:0] lo_s4, hi_s4;
    logic [TW-1:0]     tag_s4;
    logic              vld_s4;

    wire [QW-1:0] q_keep  = QW'(p_s3 >> sh_s3);                  // < 2**24
    wire [PW-1:0] sh_mask = (48'd1 << sh_s3) - 48'd1;
    wire [PW-1:0] rem     = p_s3 & sh_mask;
    wire [PW-1:0] half    = 48'd1 << (sh_s3 - 5'd1);             // sh > 0 only
    wire          tie_up  = (rem > half) || ((rem == half) && q_keep[0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s4 <= 1'b0;
        end else begin
            vld_s4 <= vld_s3;
            if (vld_s3) begin
                q_s4   <= q_keep + QW'(sh_s3 != 5'd0 && tie_up);
                sh_s4  <= sh_s3;
                neg_s4 <= neg_s3;
                k_s4   <= k_s3;
                lo_s4  <= lo_s3;
                hi_s4  <= hi_s3;
                tag_s4 <= tag_s3;
            end
        end
    end

    // --------------------------- stage 5: f32 product, shifted back to 2**k
    logic [VW-1:0]     v_s5;
    logic              neg_s5;
    logic [5:0]        k_s5;
    logic signed [9:0] lo_s5, hi_s5;
    logic [TW-1:0]     tag_s5;
    logic              vld_s5;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s5 <= 1'b0;
        end else begin
            vld_s5 <= vld_s4;
            if (vld_s4) begin
                v_s5   <= VW'(q_s4) << sh_s4;
                neg_s5 <= neg_s4;
                k_s5   <= k_s4;
                lo_s5  <= lo_s4;
                hi_s5  <= hi_s4;
                tag_s5 <= tag_s4;
            end
        end
    end

    // --------------------- stage 6: half-away rounding, sign, clamp, output
    logic              vld_s6;
    logic signed [9:0] y_s6;
    logic [TW-1:0]     tag_s6;

    wire [VW-1:0] sum  = v_s5 + (49'd1 << (k_s5 - 6'd1));   // k >= 16
    wire [MW-1:0] magw = MW'(sum >> k_s5);
    wire          sat  = |magw[MW-1:11];
    wire [11:0]   mag  = sat ? 12'd2047 : {1'b0, magw[10:0]};
    wire signed [11:0] mags = $signed(mag);
    wire signed [11:0] val  = neg_s5 ? -mags : mags;
    wire signed [11:0] lo12 = {{2{lo_s5[9]}}, lo_s5};
    wire signed [11:0] hi12 = {{2{hi_s5[9]}}, hi_s5};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s6 <= 1'b0;
        end else begin
            vld_s6 <= vld_s5;
            if (vld_s5) begin
                y_s6   <= (val < lo12) ? lo_s5 : (val > hi12) ? hi_s5 : 10'(val);
                tag_s6 <= tag_s5;
            end
        end
    end

    assign out_valid = vld_s6;
    assign out_y     = y_s6;
    assign out_tag   = tag_s6;

    initial begin
        if (XW < 25) $error("st_requant: XW must be at least 25 (|x| < 2**24)");
        if (TW < 1)  $error("st_requant: TW must be at least 1");
    end

endmodule
