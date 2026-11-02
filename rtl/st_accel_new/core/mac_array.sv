// mac_array.sv — 8×8 INT8 MAC Array (DSP48-optimized, fully unrolled)
//
// Rewritten for Efinity DSP48 inference:
//   - Fully unroll the 8×8 MACs into 64 independent multiply-add operations
//   - Each row computes: acc[r] = acc_clear ? new_sum : (acc[r] + new_sum)
//   - new_sum = Σ(act[c] * weight[r][c]) for c=0..7
//   - Avoid nested loops that confuse the DSP inference heuristic
//
// Target: 32 EFX_DSP48 (each DSP handles 2× int8 MAC in dual 18×18 mode)

module mac_array
  import st_accel_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  input  logic valid_in,
  input  logic acc_clear,
  output logic valid_out,

  input  logic signed [7:0] act_in [MAC_COLS],
  input  logic signed [7:0] weight [MAC_ROWS][MAC_COLS],
  output logic signed [31:0] acc_out [MAC_ROWS]
);

  // Internal accumulator registers (one per output channel)
  logic signed [31:0] acc [MAC_ROWS];
  logic               valid_d1, valid_d2;

  // Combinational partial products (unrolled to help DSP inference)
  logic signed [15:0] prod [MAC_ROWS][MAC_COLS];
  always_comb begin
    for (int r = 0; r < MAC_ROWS; r++)
      for (int c = 0; c < MAC_COLS; c++)
        prod[r][c] = $signed(act_in[c]) * $signed(weight[r][c]);
  end

  // Per-row reduction trees (8 products → 1 sum per row)
  logic signed [31:0] row_sum [MAC_ROWS];
  always_comb begin
    for (int r = 0; r < MAC_ROWS; r++) begin
      row_sum[r] = $signed(prod[r][0]) + $signed(prod[r][1])
                 + $signed(prod[r][2]) + $signed(prod[r][3])
                 + $signed(prod[r][4]) + $signed(prod[r][5])
                 + $signed(prod[r][6]) + $signed(prod[r][7]);
    end
  end

  // Accumulate: acc[r] = acc_clear ? row_sum[r] : acc[r] + row_sum[r]
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_d1 <= 1'b0;
      for (int r = 0; r < MAC_ROWS; r++)
        acc[r] <= 32'sd0;
    end else begin
      valid_d1 <= valid_in;
      if (valid_in) begin
        for (int r = 0; r < MAC_ROWS; r++)
          acc[r] <= acc_clear ? row_sum[r] : (acc[r] + row_sum[r]);
      end
    end
  end

  // Output register (1 cycle delay for timing)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_d2  <= 1'b0;
      valid_out <= 1'b0;
      for (int r = 0; r < MAC_ROWS; r++)
        acc_out[r] <= 32'sd0;
    end else begin
      valid_d2  <= valid_d1;
      valid_out <= valid_d2;
      if (valid_d2) begin
        for (int r = 0; r < MAC_ROWS; r++)
          acc_out[r] <= acc[r];
      end
    end
  end

endmodule
