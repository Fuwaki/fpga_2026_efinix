// rgb2yc.sv — beat-streaming RGB565 → Y/C dual-plane converter.
//
// One 128-bit AXI beat carries 8 RGB565 pixels (16 b each).  This module
// converts them to two 8-byte half-words per beat:
//
//   out_data[127:64]  — Y bytes, pixel 7..0 (Y7 at [127:120])
//   out_data[ 63: 0]  — C bytes, pixel 7..0 (C7 at [ 63: 56])
//
// Y = BT.601 luma:   (77*R + 150*G + 29*B) >> 8
// C = colour angle at 135° (Cr–Cb rotated):
//       Cb = (-43*R - 85*G + 128*B + 32768) >> 8
//       Cr = (128*R - 107*G -  21*B + 32768) >> 8
//       C_diff = Cr - Cb, scaled by 181/256 ≈ 1/√2, offset +128
//
// The conversion is fully combinatorial (zero pipeline latency).  Ready/valid
// pass through unchanged — the sink can back-pressure us freely.

module rgb2yc #(
    parameter int IMG_W = 640,
    parameter int IMG_H = 480
)(
    input  logic        clk,
    input  logic        rst_n,

    // Input: AXI beat stream, 8 × RGB565 per beat
    input  logic        in_valid,
    input  logic [127:0] in_data,   // pix[0]=[15:0], pix[1]=[31:16], …
    input  logic        in_sof,
    input  logic        in_eol,
    output logic        in_ready,

    // Output: same beat framing, data = {Y[127:64], C[63:0]}
    output logic        out_valid,
    output logic [127:0] out_data,
    output logic        out_sof,
    output logic        out_eol,
    input  logic        out_ready
);

    localparam int PIXELS = 8;  // beats_per_pixel = AXI_DW/16

    // ── Per-pixel conversion ──────────────────────────────────────────────────
    logic [7:0] y_out [PIXELS];
    logic [7:0] c_out [PIXELS];

    genvar i;
    generate
        for (i = 0; i < PIXELS; i++) begin : g_pix
            logic [4:0] r5;
            logic [5:0] g6;
            logic [4:0] b5;
            logic [7:0] r8, g8, b8;

            // unpack RGB565
            assign r5 = in_data[i*16 + 15 -: 5];
            assign g6 = in_data[i*16 + 10 -: 6];
            assign b5 = in_data[i*16 +  4 -: 5];

            // expand to 8-bit
            assign r8 = {r5, r5[4:2]};
            assign g8 = {g6, g6[5:4]};
            assign b8 = {b5, b5[4:2]};

            // BT.601 luma
            logic signed [15:0] y_tmp;
            assign y_tmp  = 16'(77  * {1'b0, r8}
                              + 150 * {1'b0, g8}
                              +  29 * {1'b0, b8});
            assign y_out[i] = y_tmp[15:8];

            // Cb, Cr
            logic signed [15:0] cb_tmp, cr_tmp;
            assign cb_tmp = 16'(-43  * $signed({1'b0, r8})
                               -  85 * $signed({1'b0, g8})
                               + 128 * $signed({1'b0, b8})
                               + 16'sd32768);
            assign cr_tmp = 16'(128  * $signed({1'b0, r8})
                               - 107 * $signed({1'b0, g8})
                               -  21 * $signed({1'b0, b8})
                               + 16'sd32768);

            // C = (Cr - Cb) * 181/256 + 128, saturated to [64,191]
            logic signed [8:0]  c_diff;
            logic signed [16:0] c_scaled;
            logic signed [7:0]  c_s8;
            assign c_diff   = $signed({1'b0, cr_tmp[15:8]})
                            - $signed({1'b0, cb_tmp[15:8]});
            assign c_scaled = c_diff * 17'sd181;
            assign c_s8     = c_scaled[15:8];
            assign c_out[i] = (c_s8 >  8'sd63)  ? 8'd191 :
                              (c_s8 < -8'sd64) ? 8'd64  :
                              8'($unsigned(c_s8 + 8'sd128));
        end
    endgenerate

    // ── Pack output beat ──────────────────────────────────────────────────────
    always_comb begin
        out_data = '0;
        for (int p = 0; p < PIXELS; p++) begin
            // Y in high half: pix0 at [127:120], pix7 at [64:57]  (high-to-low)
            out_data[127 - p*8 -: 8] = y_out[p];
            // C in low  half: pix0 at [ 63: 56]
            out_data[ 63 - p*8 -: 8] = c_out[p];
        end
    end

    // ── Flow-through handshake (zero latency) ─────────────────────────────────
    assign out_valid = in_valid;
    assign out_sof   = in_sof;
    assign out_eol   = in_eol;
    assign in_ready  = out_ready;

endmodule
