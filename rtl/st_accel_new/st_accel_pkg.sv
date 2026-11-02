// st_accel_pkg.sv — Style Transfer Accelerator Package
// 公共类型定义和参数

package st_accel_pkg;

  // ============================================================================
  // 算子类型
  // ============================================================================

  typedef enum logic [2:0] {
    OP_CONV3x3_DW  = 3'b000,  // 3×3 depthwise
    OP_CONV1x1     = 3'b001,  // 1×1 pointwise
    OP_CONV3x3     = 3'b010,  // 3×3 普通卷积
    OP_ADD         = 3'b011,  // 逐元素加法（残差）
    OP_UPSAMPLE    = 3'b100,  // 最近邻上采样
    OP_IDENTITY    = 3'b101   // 直通
  } op_type_t;

  typedef enum logic [1:0] {
    ACT_NONE  = 2'b00,
    ACT_RELU  = 2'b01,
    ACT_RELU6 = 2'b10
  } activation_t;

  // ============================================================================
  // 层描述符（64字节，可放BRAM）
  // ============================================================================

  typedef struct packed {
    // 算子类型和激活
    op_type_t      op_type;
    activation_t   activation;
    logic          fuse_next;      // 与下一层融合（DW→PW）
    logic [2:0]    stride;         // 1, 2, 4
    logic [1:0]    padding;        // 0=none 1=reflect

    // 输入形状
    logic [15:0]   in_h;
    logic [15:0]   in_w;
    logic [15:0]   in_c;

    // 输出形状
    logic [15:0]   out_h;
    logic [15:0]   out_w;
    logic [15:0]   out_c;

    // 量化参数
    // bias_int32已在Rust侧per-channel写入BRAM，bias_bram_word_addr指向起始字地址
    logic [15:0]   bias_bram_addr;   // bias BRAM起始字地址（int32, MAC_ROWS个字一组）
    // requant: per-channel int16乘法因子（= round(requant_fp * 2^16)）
    // >> 16后饱和到int8；存入BRAM，requant_bram_addr指向起始字
    logic [15:0]   requant_bram_addr;
    logic [15:0]   weight_bram_addr; // 权重BRAM字地址

    // DDR地址（tile DMA用）
    logic [31:0]   in_ddr_addr;
    logic [31:0]   out_ddr_addr;

  } layer_desc_t;

  // ============================================================================
  // 硬件参数
  // ============================================================================

  // MAC阵列尺寸
  parameter int MAC_ROWS    = 8;   // 输出通道并行度
  parameter int MAC_COLS    = 8;   // 输入通道SIMD度
  parameter int MAC_ARRAY   = MAC_ROWS * MAC_COLS;  // 64 MAC

  // Tile尺寸（空间维度，用于行缓存）
  parameter int TILE_H_MAX  = 32;  // 最大tile高度
  parameter int TILE_W_MAX  = 640; // 最大tile宽度（一般就是图像宽）

  // 行缓存（3×3 DW需要3行，最大640宽×16通道×8bit = 15360 byte）
  parameter int LINE_BUF_DEPTH = 640 * 16;

  // DDR突发
  parameter int AXI_BURST_LEN = 16;  // AXI burst length
  parameter int AXI_DATA_W    = 64;  // 64-bit DDR数据宽度

  // ============================================================================
  // 工具函数
  // ============================================================================

  // 饱和裁剪到int8 [-128, 127]
  function automatic logic signed [7:0] saturate_i8(logic signed [31:0] val);
    if (val > 127)
      return 8'sd127;
    else if (val < -128)
      return -8'sd128;
    else
      return val[7:0];
  endfunction

  // ReLU
  function automatic logic signed [7:0] relu(logic signed [7:0] val);
    return (val[7]) ? 8'sd0 : val;
  endfunction

  // ReLU6 (假设输入已经量化，6对应的int8值为scale相关)
  function automatic logic signed [7:0] relu6(logic signed [7:0] val, logic [7:0] threshold);
    if (val[7])
      return 8'sd0;
    else if (val > $signed(threshold))
      return $signed(threshold);
    else
      return val;
  endfunction

endpackage
