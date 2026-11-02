// tile_engine.sv — Tile Engine Top
// 整合mac_array, dw_conv3x3, pw_conv1x1, requant
// 串行执行layer descriptor表里的每一层

module tile_engine
  import st_accel_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // 控制
  input  logic        start,          // 启动一帧推理
  output logic        done,           // 一帧推理完成
  output logic        busy,

  // Layer descriptor接口 (从BRAM)
  input  logic [7:0]  layer_id,
  input  layer_desc_t desc,
  input  logic [7:0]  num_layers,

  // 输入流 (tile数据从DMA来)
  input  logic                   in_valid,
  input  logic signed [7:0]      in_data [MAC_COLS],
  output logic                   in_ready,
  input  logic                   in_frame_start,
  input  logic                   in_last,

  // 输出流 (推理结果到DMA)
  output logic                   out_valid,
  output logic signed [7:0]      out_data [MAC_ROWS],
  input  logic                    out_ready,
  output logic                    out_last,

  // 权重接口 (从BRAM, 每层切换)
  input  logic signed [7:0]      weight_mem [4096]  // 权重ROM (简化)
);

  // ==========================================================================
  // 状态机
  // ==========================================================================

  typedef enum logic [3:0] {
    IDLE      = 4'd0,
    LOAD_DESC = 4'd1,
    EXEC_DW   = 4'd2,
    EXEC_PW   = 4'd3,
    EXEC_CONV = 4'd4,
    EXEC_ADD  = 4'd5,
    EXEC_UP   = 4'd6,
    NEXT_LAYER= 4'd7,
    FINISH    = 4'd8
  } state_t;

  state_t state;
  logic [7:0]  cur_layer;
  logic [15:0] pixel_cnt;
  logic [15:0] pixel_total;

  // ==========================================================================
  // 算子单元实例（共享weight_mem）
  // ==========================================================================

  logic        dw_valid_out;
  logic signed [15:0] dw_conv_out [MAC_COLS];

  dw_conv3x3 #(
    .IMG_W    (TILE_W_MAX),
    .CHANNELS (MAC_COLS)
  ) u_dw_conv (
    .clk         (clk),
    .rst_n       (rst_n),
    .stride      (desc.stride[1:0]),
    .padding     (desc.padding[1:0]),
    .frame_start (in_frame_start),
    .valid_in    (in_valid && in_ready && (state == EXEC_DW)),
    .pixel_in    (in_data),
    .weight      (/* 从weight_mem切片 */),
    .valid_out   (dw_valid_out),
    .conv_out    (dw_conv_out)
  );

  // PW conv
  logic        pw_valid_out;
  logic signed [7:0] pw_out [MAC_ROWS];

  pw_conv1x1 #(
    .IN_CHANNELS  (MAC_COLS),
    .OUT_CHANNELS (MAC_ROWS)
  ) u_pw_conv (
    .clk            (clk),
    .rst_n          (rst_n),
    .frame_start    (in_frame_start),
    .num_pixels     (pixel_total),
    .valid_in       (in_valid && in_ready && (state == EXEC_PW)),
    .pixel_in       (in_data),
    .weight         (/* 切片 */),
    .bias           (/* 切片 */),
    .activation     (desc.activation),
    .requant_shift  (desc.out_scale_shift[5:0]),
    .valid_out      (pw_valid_out),
    .pixel_out      (pw_out)
  );

  // ==========================================================================
  // 主控制
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= IDLE;
      cur_layer   <= '0;
      pixel_cnt   <= '0;
      pixel_total <= '0;
      busy        <= 1'b0;
      done        <= 1'b0;

    end else begin

      done <= 1'b0;

      case (state)

        IDLE: begin
          busy <= 1'b0;
          if (start) begin
            state     <= LOAD_DESC;
            cur_layer <= '0;
            busy      <= 1'b1;
          end
        end

        LOAD_DESC: begin
          // 根据算子类型跳转
          pixel_total <= desc.out_h * desc.out_w;

          case (desc.op_type)
            OP_CONV3x3_DW: state <= EXEC_DW;
            OP_CONV1x1:    state <= EXEC_PW;
            OP_CONV3x3:    state <= EXEC_CONV;
            OP_ADD:        state <= EXEC_ADD;
            OP_UPSAMPLE:   state <= EXEC_UP;
            default:       state <= NEXT_LAYER;
          endcase
        end

        EXEC_DW: begin
          if (in_valid && in_ready) begin
            pixel_cnt <= pixel_cnt + 1;
            if (in_last) begin
              state <= NEXT_LAYER;
              pixel_cnt <= '0;
            end
          end
        end

        EXEC_PW: begin
          if (pw_valid_out) begin
            pixel_cnt <= pixel_cnt + 1;
            if (pixel_cnt == pixel_total - 1) begin
              state <= NEXT_LAYER;
              pixel_cnt <= '0;
            end
          end
        end

        EXEC_CONV: begin
          // 普通3×3卷积：输入通道循环 + mac_array
          // 简化版，复用dw path但做通道累加
          state <= NEXT_LAYER;
        end

        EXEC_ADD: begin
          // 残差加：逐像素
          if (in_valid && in_ready) begin
            pixel_cnt <= pixel_cnt + 1;
            if (in_last) begin
              state <= NEXT_LAYER;
              pixel_cnt <= '0;
            end
          end
        end

        EXEC_UP: begin
          // 上采样：像素重复
          if (in_valid && in_ready) begin
            pixel_cnt <= pixel_cnt + 1;
            if (in_last) begin
              state <= NEXT_LAYER;
              pixel_cnt <= '0;
            end
          end
        end

        NEXT_LAYER: begin
          if (cur_layer == num_layers - 1) begin
            state <= FINISH;
          end else begin
            cur_layer <= cur_layer + 1;
            state     <= LOAD_DESC;
          end
        end

        FINISH: begin
          done  <= 1'b1;
          busy  <= 1'b0;
          state <= IDLE;
        end

      endcase
    end
  end

  // ==========================================================================
  // 输出路由（根据当前state选择数据源）
  // ==========================================================================

  always_comb begin
    // 默认
    in_ready  = 1'b0;
    out_valid = 1'b0;
    out_last  = 1'b0;
    for (int i = 0; i < MAC_ROWS; i++)
      out_data[i] = 8'sd0;

    case (state)
      EXEC_DW: begin
        in_ready  = 1'b1;
        out_valid = dw_valid_out;
        for (int i = 0; i < MAC_ROWS; i++)
          out_data[i] = (i < MAC_COLS) ? dw_conv_out[i][7:0] : 8'sd0;
      end

      EXEC_PW: begin
        in_ready  = 1'b1;
        out_valid = pw_valid_out;
        for (int i = 0; i < MAC_ROWS; i++)
          out_data[i] = pw_out[i];
      end

      EXEC_ADD: begin
        in_ready  = 1'b1;
        out_valid = in_valid;
        for (int i = 0; i < MAC_ROWS; i++)
          out_data[i] = in_data[i];
      end

      EXEC_UP: begin
        in_ready  = 1'b1;
        out_valid = in_valid;
        for (int i = 0; i < MAC_ROWS; i++)
          out_data[i] = in_data[i];
      end

      default: ;
    endcase

    if (out_valid && pixel_cnt == pixel_total - 1)
      out_last = 1'b1;
  end

endmodule
