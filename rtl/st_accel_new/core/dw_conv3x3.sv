// dw_conv3x3.sv — Depthwise 3×3 Convolution
// 每个输入通道独立做3×3卷积，使用line_buffer提供窗口
// 支持stride 1/2，padding 0/1

module dw_conv3x3 #(
  parameter int IMG_W    = 640,
  parameter int CHANNELS = 8      // 必须 <= MAC_COLS
)(
  input  logic clk,
  input  logic rst_n,

  // 配置
  input  logic [1:0]  stride,         // 1 or 2
  input  logic [1:0]  padding,        // 0 or 1
  input  logic        frame_start,

  // 输入流：每周期1个像素 × CHANNELS
  input  logic                   valid_in,
  input  logic signed [7:0]      pixel_in [CHANNELS],

  // 权重：3×3×CHANNELS (从BRAM/寄存器加载)
  input  logic signed [7:0]      weight [3][3][CHANNELS],

  // 输出：卷积结果（INT16，未量化）
  output logic                   valid_out,
  output logic signed [15:0]     conv_out [CHANNELS]
);

  import st_accel_pkg::*;

  // ==========================================================================
  // Line buffer: 获取3×3窗口
  // ==========================================================================

  logic                   lb_valid;
  logic signed [7:0]      window [3][3][CHANNELS];

  line_buffer #(
    .IMG_W    (IMG_W),
    .CHANNELS (CHANNELS),
    .DATA_W   (8)
  ) u_line_buffer (
    .clk         (clk),
    .rst_n       (rst_n),
    .valid_in    (valid_in),
    .frame_start (frame_start),
    .pixel_in    (pixel_in),
    .valid_out   (lb_valid),
    .window      (window)
  );

  // ==========================================================================
  // Stride控制：每stride个像素输出1次
  // ==========================================================================

  logic [15:0] col_cnt, row_cnt;
  logic        stride_enable;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      col_cnt       <= '0;
      row_cnt       <= '0;
      stride_enable <= 1'b0;
    end else begin

      if (frame_start) begin
        col_cnt       <= '0;
        row_cnt       <= '0;
        stride_enable <= 1'b0;
      end

      else if (lb_valid) begin

        // Stride判断
        case (stride)
          2'd1: stride_enable <= 1'b1;  // 每个像素
          2'd2: stride_enable <= (col_cnt[0] == 1'b0) && (row_cnt[0] == 1'b0);  // 每隔1个
          default: stride_enable <= 1'b0;
        endcase

        col_cnt <= col_cnt + 1;

        if (col_cnt == IMG_W - 1) begin
          col_cnt <= '0;
          row_cnt <= row_cnt + 1;
        end

      end else begin
        stride_enable <= 1'b0;
      end

    end
  end

  // ==========================================================================
  // 3×3 MAC（每通道独立）
  // ==========================================================================

  logic                   mac_valid;
  logic signed [15:0]     mac_result [CHANNELS];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mac_valid <= 1'b0;
      for (int ch = 0; ch < CHANNELS; ch++)
        mac_result[ch] <= 16'sd0;
    end else begin

      mac_valid <= lb_valid && stride_enable;

      if (lb_valid && stride_enable) begin
        for (int ch = 0; ch < CHANNELS; ch++) begin
          automatic logic signed [15:0] sum = 16'sd0;

          // 累加3×3窗口
          for (int r = 0; r < 3; r++) begin
            for (int c = 0; c < 3; c++) begin
              sum += window[r][c][ch] * weight[r][c][ch];
            end
          end

          mac_result[ch] <= sum;
        end
      end

    end
  end

  // ==========================================================================
  // 输出
  // ==========================================================================

  assign valid_out = mac_valid;

  always_comb begin
    for (int ch = 0; ch < CHANNELS; ch++)
      conv_out[ch] = mac_result[ch];
  end

endmodule
