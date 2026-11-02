// line_buffer.sv — 3行缓存用于3×3卷积窗口
// 流式输入单个像素（所有通道打包），输出3×3窗口
// 适用于depthwise conv3x3 (每通道独立)

module line_buffer #(
  parameter int IMG_W    = 640,     // 图像宽度
  parameter int CHANNELS = 8,       // 通道数（SIMD）
  parameter int DATA_W   = 8        // 每通道位宽
)(
  input  logic clk,
  input  logic rst_n,

  // 控制
  input  logic                      valid_in,
  input  logic                      frame_start,  // 帧开始：清除缓存
  output logic                      valid_out,    // 输出窗口有效

  // 输入：1像素 × CHANNELS
  input  logic [DATA_W-1:0]         pixel_in [CHANNELS],

  // 输出：3×3窗口 × CHANNELS
  // window[行][列][通道]，行0是最旧的，行2是当前
  output logic [DATA_W-1:0]         window [3][3][CHANNELS]
);

  // ==========================================================================
  // 行缓存 RAM（2行，当前行用寄存器）
  // ==========================================================================

  typedef logic [DATA_W-1:0] pixel_t [CHANNELS];

  pixel_t line_ram [2][IMG_W];  // 2行 × 640像素 × CHANNELS通道

  // 当前处理的行内位置和行号
  logic [15:0] col_cnt;
  logic [1:0]  row_mod;   // 0, 1, 2 (mod 3)
  logic [1:0]  valid_rows;  // 已经填充了几行 (0–3)

  // Shift register for 3×3 window (每行3个tap)
  pixel_t tap [3][3];  // [行][列]

  // ==========================================================================
  // 主状态机
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      col_cnt    <= '0;
      row_mod    <= '0;
      valid_rows <= '0;
      valid_out  <= 1'b0;

      for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
          for (int ch = 0; ch < CHANNELS; ch++)
            tap[r][c][ch] <= '0;

    end else begin

      if (frame_start) begin
        col_cnt    <= '0;
        row_mod    <= '0;
        valid_rows <= '0;
        valid_out  <= 1'b0;
      end

      else if (valid_in) begin

        // ======================================================================
        // 移位窗口（横向）
        // ======================================================================
        for (int r = 0; r < 3; r++) begin
          tap[r][0] <= tap[r][1];
          tap[r][1] <= tap[r][2];
        end

        // 当前像素进入第2列（中间列）
        tap[2][2] <= pixel_in;

        // ======================================================================
        // 读取旧行，写入新行
        // ======================================================================
        if (col_cnt < IMG_W) begin

          // 从RAM读取上2行
          if (valid_rows >= 1)
            tap[0][2] <= line_ram[(row_mod + 1) % 2][col_cnt];

          if (valid_rows >= 2)
            tap[1][2] <= line_ram[row_mod][col_cnt];

          // 当前像素写入RAM（当行结束时，下一行会读回）
          if (col_cnt < IMG_W - 1) begin
            // 提前写入下一列（1-cycle提前）
            line_ram[row_mod][col_cnt + 1] <= pixel_in;
          end

          col_cnt <= col_cnt + 1;

          // 输出有效条件：至少2行 + 当前列 >= 2（有3列窗口）
          if (valid_rows >= 2 && col_cnt >= 2)
            valid_out <= 1'b1;
          else
            valid_out <= 1'b0;

        end

        // ======================================================================
        // 行结束
        // ======================================================================
        if (col_cnt == IMG_W - 1) begin
          col_cnt  <= '0;
          row_mod  <= (row_mod == 2'd1) ? 2'd0 : row_mod + 1;

          if (valid_rows < 3)
            valid_rows <= valid_rows + 1;
        end

      end else begin
        valid_out <= 1'b0;
      end

    end
  end

  // ==========================================================================
  // 输出窗口
  // ==========================================================================

  always_comb begin
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 3; c++)
        for (int ch = 0; ch < CHANNELS; ch++)
          window[r][c][ch] = tap[r][c][ch];
  end

endmodule
