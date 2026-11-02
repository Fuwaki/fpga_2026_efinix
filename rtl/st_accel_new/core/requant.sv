// requant.sv — INT32 accumulator → INT8 quantised output
// Formula per channel: y = saturate_i8((acc + bias_i32) * mult_i16 >> 16)
// mult_i16 = round(requant_fp * 2^16); values for this model: 64..3775, fits uint16
//
// Pipeline: 4 stages
//   Stage 1: acc + bias
//   Stage 2: (sum * mult) — int32 × uint16 → int48 (held in int64 reg)
//   Stage 3: >> 16 arithmetic
//   Stage 4: saturate_i8 + activation

module requant
  import st_accel_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // Control
  input  logic             valid_in,
  input  activation_t      activation,
  output logic             valid_out,

  // Inputs
  input  logic signed [31:0] acc_in  [MAC_ROWS],
  input  logic signed [31:0] bias    [MAC_ROWS],   // bias_int32 from manifest
  input  logic [15:0]        mult    [MAC_ROWS],   // requant * 2^16, per output channel

  // Output
  output logic signed [7:0]  data_out [MAC_ROWS]
);

  // ─── Stage 1: add bias ────────────────────────────────────────────────────

  logic signed [31:0] sum_s1   [MAC_ROWS];
  logic [15:0]        mult_s1  [MAC_ROWS];
  logic               valid_s1;
  activation_t        act_s1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1 <= 1'b0;
      act_s1   <= ACT_NONE;
      for (int i = 0; i < MAC_ROWS; i++) begin
        sum_s1[i]  <= 32'sd0;
        mult_s1[i] <= 16'd0;
      end
    end else begin
      valid_s1 <= valid_in;
      act_s1   <= activation;
      if (valid_in) begin
        for (int i = 0; i < MAC_ROWS; i++) begin
          sum_s1[i]  <= acc_in[i] + bias[i];
          mult_s1[i] <= mult[i];
        end
      end
    end
  end

  // ─── Stage 2: multiply (int32 × uint16 → int64) ──────────────────────────

  logic signed [47:0] prod_s2  [MAC_ROWS];   // 32+16 = 48 bits sufficient
  logic               valid_s2;
  activation_t        act_s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s2 <= 1'b0;
      act_s2   <= ACT_NONE;
      for (int i = 0; i < MAC_ROWS; i++)
        prod_s2[i] <= 48'sd0;
    end else begin
      valid_s2 <= valid_s1;
      act_s2   <= act_s1;
      if (valid_s1) begin
        for (int i = 0; i < MAC_ROWS; i++)
          prod_s2[i] <= $signed(sum_s1[i]) * $signed({1'b0, mult_s1[i]});
      end
    end
  end

  // ─── Stage 3: arithmetic right shift >> 16 ────────────────────────────────

  logic signed [31:0] shifted_s3 [MAC_ROWS];
  logic               valid_s3;
  activation_t        act_s3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s3 <= 1'b0;
      act_s3   <= ACT_NONE;
      for (int i = 0; i < MAC_ROWS; i++)
        shifted_s3[i] <= 32'sd0;
    end else begin
      valid_s3 <= valid_s2;
      act_s3   <= act_s2;
      if (valid_s2) begin
        for (int i = 0; i < MAC_ROWS; i++)
          shifted_s3[i] <= prod_s2[i] >>> 16;
      end
    end
  end

  // ─── Stage 4: saturate + activation ───────────────────────────────────────

  logic signed [7:0] out_s4  [MAC_ROWS];
  logic              valid_s4;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s4 <= 1'b0;
      for (int i = 0; i < MAC_ROWS; i++)
        out_s4[i] <= 8'sd0;
    end else begin
      valid_s4 <= valid_s3;
      if (valid_s3) begin
        for (int i = 0; i < MAC_ROWS; i++) begin
          automatic logic signed [7:0] sat = saturate_i8(shifted_s3[i]);
          case (act_s3)
            ACT_RELU:  out_s4[i] <= relu(sat);
            ACT_RELU6: out_s4[i] <= relu6(sat, 8'd48);
            default:   out_s4[i] <= sat;
          endcase
        end
      end
    end
  end

  // ─── Output ───────────────────────────────────────────────────────────────

  assign valid_out = valid_s4;

  always_comb begin
    for (int i = 0; i < MAC_ROWS; i++)
      data_out[i] = out_s4[i];
  end

endmodule
