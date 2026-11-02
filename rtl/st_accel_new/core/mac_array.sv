// mac_array.sv — 8×8 INT8 MAC Array
// 输出通道×输入通道的二维MAC阵列
// 资源：64 MAC → 映射到32个EFX_DSP48 (每个DSP做2个int8 MAC)

module mac_array
  import st_accel_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // 控制
  input  logic valid_in,            // 输入有效
  input  logic acc_clear,           // 清累加器（新的空间位置）
  output logic valid_out,           // 输出有效（延迟3拍）

  // 输入激活 [MAC_COLS] (8个int8)
  input  logic signed [7:0] act_in [MAC_COLS],

  // 权重 [MAC_ROWS][MAC_COLS] (8×8 = 64个int8)
  input  logic signed [7:0] weight [MAC_ROWS][MAC_COLS],

  // 累加输出 [MAC_ROWS] (8个int32)
  output logic signed [31:0] acc_out [MAC_ROWS]
);

  // ==========================================================================
  // Pipeline Stage 1: Multiply
  // ==========================================================================

  logic signed [15:0] prod [MAC_ROWS][MAC_COLS];
  logic               valid_s1;
  logic               acc_clear_s1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1     <= 1'b0;
      acc_clear_s1 <= 1'b0;
      for (int r = 0; r < MAC_ROWS; r++)
        for (int c = 0; c < MAC_COLS; c++)
          prod[r][c] <= 16'sd0;
    end else begin
      valid_s1     <= valid_in;
      acc_clear_s1 <= acc_clear;

      if (valid_in) begin
        for (int r = 0; r < MAC_ROWS; r++)
          for (int c = 0; c < MAC_COLS; c++)
            prod[r][c] <= act_in[c] * weight[r][c];
      end
    end
  end

  // ==========================================================================
  // Pipeline Stage 2: Reduce (sum across input channels)
  // ==========================================================================

  logic signed [19:0] sum_s2 [MAC_ROWS];  // log2(256*256*8) = 19 bits
  logic               valid_s2;
  logic               acc_clear_s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s2     <= 1'b0;
      acc_clear_s2 <= 1'b0;
      for (int r = 0; r < MAC_ROWS; r++)
        sum_s2[r] <= 20'sd0;
    end else begin
      valid_s2     <= valid_s1;
      acc_clear_s2 <= acc_clear_s1;

      if (valid_s1) begin
        for (int r = 0; r < MAC_ROWS; r++) begin
          logic signed [19:0] tmp;
          tmp = 20'sd0;
          for (int c = 0; c < MAC_COLS; c++)
            tmp += prod[r][c];
          sum_s2[r] <= tmp;
        end
      end
    end
  end

  // ==========================================================================
  // Pipeline Stage 3: Accumulate
  // ==========================================================================

  logic signed [31:0] acc_reg [MAC_ROWS];
  logic               valid_s3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s3 <= 1'b0;
      for (int r = 0; r < MAC_ROWS; r++)
        acc_reg[r] <= 32'sd0;
    end else begin
      valid_s3 <= valid_s2;

      if (valid_s2) begin
        for (int r = 0; r < MAC_ROWS; r++) begin
          if (acc_clear_s2)
            acc_reg[r] <= $signed(sum_s2[r]);  // 新位置：直接赋值
          else
            acc_reg[r] <= acc_reg[r] + $signed(sum_s2[r]);  // 累加
        end
      end
    end
  end

  // ==========================================================================
  // Output
  // ==========================================================================

  assign valid_out = valid_s3;

  always_comb begin
    for (int r = 0; r < MAC_ROWS; r++)
      acc_out[r] = acc_reg[r];
  end

endmodule
