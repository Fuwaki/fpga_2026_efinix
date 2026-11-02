// pw_conv1x1.sv — Pointwise 1×1 Convolution
// 使用mac_array做输入通道×输出通道的矩阵乘法
// 输入：流式像素 [in_c]，输出：[out_c]
// in_c必须是MAC_COLS的倍数，out_c必须是MAC_ROWS的倍数

module pw_conv1x1
  import st_accel_pkg::*;
#(
  parameter int IN_CHANNELS  = 16,   // 输入通道
  parameter int OUT_CHANNELS = 16    // 输出通道
)(
  input  logic clk,
  input  logic rst_n,

  // 配置
  input  logic        frame_start,
  input  logic [31:0] num_pixels,     // 这一层的像素总数

  // 输入流：每周期1个像素 × IN_CHANNELS
  input  logic                  valid_in,
  input  logic signed [7:0]     pixel_in [IN_CHANNELS],

  // 权重：[OUT_CHANNELS][IN_CHANNELS] (从BRAM加载，分tile复用mac_array)
  input  logic signed [7:0]     weight [OUT_CHANNELS][IN_CHANNELS],

  // Bias + requant参数
  input  logic signed [31:0]    bias [OUT_CHANNELS],
  input  activation_t           activation,
  input  logic [5:0]            requant_shift,

  // 输出：量化后的int8
  output logic                  valid_out,
  output logic signed [7:0]     pixel_out [OUT_CHANNELS]
);

  // ==========================================================================
  // Tile参数
  // ==========================================================================

  localparam int IN_TILES  = (IN_CHANNELS + MAC_COLS - 1) / MAC_COLS;
  localparam int OUT_TILES = (OUT_CHANNELS + MAC_ROWS - 1) / MAC_ROWS;

  // ==========================================================================
  // 输入通道tile循环
  // ==========================================================================

  logic [7:0] in_tile_id;
  logic [7:0] out_tile_id;
  logic [31:0] pixel_cnt;

  logic signed [7:0]  mac_act [MAC_COLS];
  logic signed [7:0]  mac_weight [MAC_ROWS][MAC_COLS];
  logic               mac_valid_in;
  logic               mac_acc_clear;

  // 每个像素分IN_TILES次喂入mac_array（累加输入通道）
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_tile_id    <= '0;
      out_tile_id   <= '0;
      pixel_cnt     <= '0;
      mac_valid_in  <= 1'b0;
      mac_acc_clear <= 1'b0;
    end else begin

      mac_valid_in  <= 1'b0;
      mac_acc_clear <= 1'b0;

      if (frame_start) begin
        in_tile_id  <= '0;
        out_tile_id <= '0;
        pixel_cnt   <= '0;
      end

      else if (valid_in) begin

        // 当前tile的输入通道切片
        for (int i = 0; i < MAC_COLS; i++) begin
          int idx = in_tile_id * MAC_COLS + i;
          if (idx < IN_CHANNELS)
            mac_act[i] <= pixel_in[idx];
          else
            mac_act[i] <= 8'sd0;  // padding
        end

        // 当前tile的权重切片
        for (int r = 0; r < MAC_ROWS; r++) begin
          for (int c = 0; c < MAC_COLS; c++) begin
            int out_idx = out_tile_id * MAC_ROWS + r;
            int in_idx  = in_tile_id * MAC_COLS + c;

            if (out_idx < OUT_CHANNELS && in_idx < IN_CHANNELS)
              mac_weight[r][c] <= weight[out_idx][in_idx];
            else
              mac_weight[r][c] <= 8'sd0;
          end
        end

        mac_valid_in  <= 1'b1;
        mac_acc_clear <= (in_tile_id == 0);  // 第一个输入tile时清累加器

        // Tile循环
        if (in_tile_id == IN_TILES - 1) begin
          in_tile_id <= '0;

          if (out_tile_id == OUT_TILES - 1) begin
            out_tile_id <= '0;
            pixel_cnt   <= pixel_cnt + 1;
          end else begin
            out_tile_id <= out_tile_id + 1;
          end

        end else begin
          in_tile_id <= in_tile_id + 1;
        end

      end
    end
  end

  // ==========================================================================
  // MAC Array
  // ==========================================================================

  logic               mac_valid_out;
  logic signed [31:0] mac_acc [MAC_ROWS];

  mac_array u_mac_array (
    .clk       (clk),
    .rst_n     (rst_n),
    .valid_in  (mac_valid_in),
    .acc_clear (mac_acc_clear),
    .valid_out (mac_valid_out),
    .act_in    (mac_act),
    .weight    (mac_weight),
    .acc_out   (mac_acc)
  );

  // ==========================================================================
  // Requant（输入通道累加完成后）
  // ==========================================================================

  logic                   rq_valid_in;
  logic signed [31:0]     rq_bias [MAC_ROWS];
  logic signed [7:0]      rq_out [MAC_ROWS];
  logic                   rq_valid_out;

  // 只有最后一个输入tile完成时才送入requant
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rq_valid_in <= 1'b0;
    end else begin
      rq_valid_in <= mac_valid_out && (in_tile_id == 0);  // in_tile刚回卷
    end
  end

  // Bias切片
  always_comb begin
    for (int r = 0; r < MAC_ROWS; r++) begin
      int out_idx = out_tile_id * MAC_ROWS + r;
      if (out_idx < OUT_CHANNELS)
        rq_bias[r] = bias[out_idx];
      else
        rq_bias[r] = 32'sd0;
    end
  end

  requant u_requant (
    .clk          (clk),
    .rst_n        (rst_n),
    .valid_in     (rq_valid_in),
    .activation   (activation),
    .right_shift  (requant_shift),
    .valid_out    (rq_valid_out),
    .acc_in       (mac_acc),
    .bias         (rq_bias),
    .data_out     (rq_out)
  );

  // ==========================================================================
  // 输出收集（OUT_TILES个tile拼接）
  // ==========================================================================

  logic signed [7:0] output_buf [OUT_CHANNELS];
  logic [7:0]        out_tile_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_out     <= 1'b0;
      out_tile_done <= '0;
      for (int i = 0; i < OUT_CHANNELS; i++)
        output_buf[i] <= 8'sd0;
    end else begin

      valid_out <= 1'b0;

      if (frame_start) begin
        out_tile_done <= '0;
      end

      else if (rq_valid_out) begin
        // 写入当前output tile
        for (int r = 0; r < MAC_ROWS; r++) begin
          int out_idx = out_tile_id * MAC_ROWS + r;
          if (out_idx < OUT_CHANNELS)
            output_buf[out_idx] <= rq_out[r];
        end

        out_tile_done <= out_tile_done + 1;

        // 所有output tile完成
        if (out_tile_done == OUT_TILES - 1) begin
          valid_out     <= 1'b1;
          out_tile_done <= '0;
        end
      end

    end
  end

  always_comb begin
    for (int i = 0; i < OUT_CHANNELS; i++)
      pixel_out[i] = output_buf[i];
  end

endmodule
