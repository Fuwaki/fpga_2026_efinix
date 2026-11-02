// tile_engine.sv — Single-layer DDR executor
//
// Caller (st_accel_wrapper) sets `desc` with populated DDR addresses and
// asserts `start`.  Engine preloads weights/bias/requant from BRAM into
// register files, then streams pixels from tile_dma_rd through the operator
// (dw_conv3x3 or pw_conv1x1), writes to tile_dma_wr, and asserts `done`.
//
// DW: weight reg file [3][3][MAX_CH] (288 int8 max).
// PW: weight reg file [MAX_CH][MAX_CH] (1024 int8 max with MAX_CH=32).
//
// Beat unpacking: AXI 128-bit beats arrive packed as in_c bytes per pixel
// repeated.  For in_c ≤ 16 one beat = one pixel worth of channels, padded.
// The engine handles one pixel per cycle once the beat is captured.

module tile_engine
  import st_accel_pkg::*;
#(
  parameter int MAX_CH  = 32,   // max channels (in and out)
  parameter int IMG_W   = 480,
  parameter int IMG_H   = 480
)(
  input  logic clk,
  input  logic rst_n,

  // ─── Control ────────────────────────────────────────────────────────────
  input  logic          start,
  output logic          done,
  output logic          busy,

  // Layer descriptor (fully populated by wrapper before start)
  input  layer_desc_t   desc,

  // ─── Input beat stream (from tile_dma_rd via wrapper) ───────────────────
  input  logic          in_valid,
  input  logic [127:0]  in_beat,
  output logic          in_ready,
  input  logic          in_sof,
  input  logic          in_eol,

  // ─── Output beat stream (to tile_dma_wr via wrapper) ────────────────────
  output logic          out_valid,
  output logic [127:0]  out_beat,
  input  logic          out_ready,
  output logic          out_sof,
  output logic          out_eol,

  // ─── BRAM ports (1-cycle read latency) ──────────────────────────────────
  output logic [15:0]   w_addr,
  input  logic [7:0]    w_rdata,   // int8 weight

  output logic [15:0]   b_addr,
  input  logic [31:0]   b_rdata,   // int32 bias

  output logic [15:0]   q_addr,
  input  logic [15:0]   q_rdata    // uint16 requant mult
);

  localparam int BEAT_BYTES = 16;

  // ─── Register files ──────────────────────────────────────────────────────
  logic signed [7:0]  wt_dw  [3][3][MAX_CH];
  logic signed [7:0]  wt_pw  [MAX_CH][MAX_CH];
  logic signed [31:0] bias_rf [MAX_CH];
  logic [15:0]        mult_rf [MAX_CH];

  // ─── State machine ───────────────────────────────────────────────────────
  typedef enum logic [3:0] {
    IDLE      = 4'd0,
    LOAD_W    = 4'd1,
    LOAD_BQ   = 4'd2,
    RUN_DW    = 4'd3,
    RUN_PW    = 4'd4,
    DONE_ST   = 4'd5
  } state_t;
  state_t state;

  logic [15:0] load_cnt;

  // Total weight count for current layer
  logic [15:0] wt_total;
  always_comb begin
    case (desc.op_type)
      OP_CONV3x3_DW, OP_CONV3x3: wt_total = 9 * desc.out_c;
      OP_CONV1x1:                 wt_total = desc.out_c * desc.in_c;
      default:                    wt_total = 16'd0;
    endcase
  end

  // ─── BRAM address: switch between weight and bias/requant phases ─────────
  always_comb begin
    w_addr = desc.weight_bram_addr  + load_cnt;
    b_addr = desc.bias_bram_addr    + load_cnt;
    q_addr = desc.requant_bram_addr + load_cnt;
  end

  // ─── Preload FSM ─────────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= IDLE;
      load_cnt <= '0;
      done     <= 1'b0;
      busy     <= 1'b0;
    end else begin
      done <= 1'b0;

      case (state)
        IDLE: begin
          busy <= 1'b0;
          if (start) begin
            load_cnt <= '0;
            busy     <= 1'b1;
            case (desc.op_type)
              OP_CONV3x3_DW, OP_CONV3x3, OP_CONV1x1: state <= LOAD_W;
              default: state <= DONE_ST;
            endcase
          end
        end

        LOAD_W: begin
          // BRAM has 1-cycle latency: data for (load_cnt-1) valid now
          if (load_cnt > 0) begin
            if (desc.op_type == OP_CONV1x1) begin
              // PW: [out_c][in_c] row-major
              if (((load_cnt-1) / MAX_CH) < MAX_CH && ((load_cnt-1) % MAX_CH) < MAX_CH)
                wt_pw[(load_cnt-1) / MAX_CH][(load_cnt-1) % MAX_CH] <= $signed(w_rdata);
            end else begin
              // DW/CONV3x3: [kh][kw][ch], layout: idx = kh*3*MAX_CH + kw*MAX_CH + ch
              if (((load_cnt-1) % MAX_CH) < MAX_CH &&
                  (((load_cnt-1) / MAX_CH) % 3) < 3 &&
                  (((load_cnt-1) / MAX_CH) / 3) < 3)
                wt_dw[((load_cnt-1) / MAX_CH) / 3]
                     [((load_cnt-1) / MAX_CH) % 3]
                     [(load_cnt-1) % MAX_CH] <= $signed(w_rdata);
            end
          end
          if (load_cnt == wt_total) begin
            load_cnt <= '0;
            state    <= LOAD_BQ;
          end else begin
            load_cnt <= load_cnt + 1;
          end
        end

        LOAD_BQ: begin
          if (load_cnt > 0) begin
            if ((load_cnt - 1) < MAX_CH) begin
              bias_rf[load_cnt - 1] <= $signed(b_rdata);
              mult_rf[load_cnt - 1] <= q_rdata;
            end
          end
          if (load_cnt == desc.out_c) begin
            load_cnt <= '0;
            case (desc.op_type)
              OP_CONV3x3_DW, OP_CONV3x3: state <= RUN_DW;
              OP_CONV1x1:                state <= RUN_PW;
              default:                   state <= DONE_ST;
            endcase
          end else begin
            load_cnt <= load_cnt + 1;
          end
        end

        RUN_DW: begin
          if (dw_done) state <= DONE_ST;
        end

        RUN_PW: begin
          if (pw_done) state <= DONE_ST;
        end

        DONE_ST: begin
          done  <= 1'b1;
          busy  <= 1'b0;
          state <= IDLE;
        end

      endcase
    end
  end

  // ─── Beat → per-pixel deserialiser ───────────────────────────────────────
  // One beat = BEAT_BYTES bytes.  For in_c ≤ 16 channels: one pixel per beat
  // (unused channel bytes are zero-padded by the DMA packer).
  // Output: px_valid pulses for one cycle per pixel.

  logic signed [7:0] px_buf [MAX_CH];
  logic              px_valid;
  logic              px_sof, px_eol;

  logic run = (state == RUN_DW || state == RUN_PW);

  assign in_ready = run && !px_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      px_valid <= 1'b0;
      px_sof   <= 1'b0;
      px_eol   <= 1'b0;
      for (int i = 0; i < MAX_CH; i++)
        px_buf[i] <= '0;
    end else begin
      if (!run) begin
        px_valid <= 1'b0;
      end else if (in_valid && in_ready) begin
        for (int i = 0; i < BEAT_BYTES && i < MAX_CH; i++)
          px_buf[i] <= $signed(in_beat[8*i +: 8]);
        for (int i = BEAT_BYTES; i < MAX_CH; i++)
          px_buf[i] <= 8'sd0;
        px_valid <= 1'b1;
        px_sof   <= in_sof;
        px_eol   <= in_eol;
      end else begin
        px_valid <= 1'b0;
      end
    end
  end

  // ─── DW conv datapath ────────────────────────────────────────────────────
  logic              dw_valid_out;
  logic signed [15:0] dw_conv_out [MAX_CH];
  logic              dw_frame_start;
  logic              dw_done;
  logic [31:0]       dw_px_out;    // output pixels produced

  assign dw_frame_start = run && px_valid && px_sof;

  // Requant tile loop over DW output channels
  logic [7:0]        dw_tile_id;
  logic              dw_rq_valid;
  logic signed [31:0] dw_rq_acc  [MAC_ROWS];
  logic signed [31:0] dw_rq_bias [MAC_ROWS];
  logic [15:0]       dw_rq_mult [MAC_ROWS];
  logic signed [7:0] dw_rq_out  [MAC_ROWS];
  logic              dw_rq_vout;

  logic [7:0]        dw_out_tiles;  // ceildiv(out_c, MAC_ROWS)
  assign dw_out_tiles = (desc.out_c + MAC_ROWS - 1) / MAC_ROWS;

  dw_conv3x3 #(
    .IMG_W    (IMG_W),
    .CHANNELS (MAX_CH)
  ) u_dw_conv (
    .clk         (clk),
    .rst_n       (rst_n),
    .stride      (desc.stride[1:0]),
    .padding     (desc.padding[1:0]),
    .frame_start (dw_frame_start),
    .valid_in    (px_valid && (state == RUN_DW)),
    .pixel_in    (px_buf),
    .weight      (wt_dw),
    .valid_out   (dw_valid_out),
    .conv_out    (dw_conv_out)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dw_tile_id <= '0;
      dw_rq_valid<= 1'b0;
      dw_px_out  <= '0;
    end else begin
      dw_rq_valid <= 1'b0;
      if (state == RUN_DW) begin
        if (dw_valid_out) begin
          for (int r = 0; r < MAC_ROWS; r++) begin
            dw_rq_acc[r]  <= ((dw_tile_id * MAC_ROWS + r) < MAX_CH)
                              ? {{16{dw_conv_out[dw_tile_id * MAC_ROWS + r][15]}},
                                 dw_conv_out[dw_tile_id * MAC_ROWS + r]}
                              : 32'sd0;
            dw_rq_bias[r] <= ((dw_tile_id * MAC_ROWS + r) < MAX_CH)
                              ? bias_rf[dw_tile_id * MAC_ROWS + r] : 32'sd0;
            dw_rq_mult[r] <= ((dw_tile_id * MAC_ROWS + r) < MAX_CH)
                              ? mult_rf[dw_tile_id * MAC_ROWS + r] : 16'd0;
          end
          dw_rq_valid <= 1'b1;
          if (dw_tile_id == dw_out_tiles - 1) begin
            dw_tile_id <= '0;
            dw_px_out  <= dw_px_out + 1;
          end else begin
            dw_tile_id <= dw_tile_id + 1;
          end
        end
      end else begin
        dw_tile_id <= '0;
        dw_px_out  <= '0;
      end
    end
  end

  requant u_dw_rq (
    .clk       (clk),
    .rst_n     (rst_n),
    .valid_in  (dw_rq_valid),
    .activation(desc.activation),
    .valid_out (dw_rq_vout),
    .acc_in    (dw_rq_acc),
    .bias      (dw_rq_bias),
    .mult      (dw_rq_mult),
    .data_out  (dw_rq_out)
  );

  // Count completed output pixels (after requant, tile 0 = last tile)
  logic [7:0]  dw_rq_tile_del [4];  // track tile_id through requant pipeline
  always_ff @(posedge clk) begin
    dw_rq_tile_del[0] <= dw_tile_id;
    for (int i = 1; i < 4; i++) dw_rq_tile_del[i] <= dw_rq_tile_del[i-1];
  end

  logic [31:0] dw_out_total;
  assign dw_out_total = desc.out_h * desc.out_w;
  assign dw_done = dw_rq_vout && (dw_rq_tile_del[3] == dw_out_tiles - 1)
                   && (dw_px_out >= dw_out_total);

  // ─── PW conv datapath ────────────────────────────────────────────────────
  logic              pw_valid_out;
  logic signed [7:0] pw_pixel_out [MAX_CH];
  logic              pw_frame_start;
  logic              pw_done;

  assign pw_frame_start = run && px_valid && px_sof;

  pw_conv1x1 #(
    .MAX_IN_C  (MAX_CH),
    .MAX_OUT_C (MAX_CH)
  ) u_pw_conv (
    .clk         (clk),
    .rst_n       (rst_n),
    .in_c        (desc.in_c),
    .out_c       (desc.out_c),
    .frame_start (pw_frame_start),
    .num_pixels  (desc.out_h * desc.out_w),
    .valid_in    (px_valid && (state == RUN_PW)),
    .pixel_in    (px_buf),
    .weight      (wt_pw),
    .bias        (bias_rf),
    .mult        (mult_rf),
    .activation  (desc.activation),
    .valid_out   (pw_valid_out),
    .pixel_out   (pw_pixel_out)
  );

  logic [31:0] pw_out_total;
  logic [31:0] pw_px_out;
  assign pw_out_total = desc.out_h * desc.out_w;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pw_px_out <= '0;
    else if (state != RUN_PW) pw_px_out <= '0;
    else if (pw_valid_out) pw_px_out <= pw_px_out + 1;
  end

  assign pw_done = pw_valid_out && (pw_px_out == pw_out_total - 1);

  // ─── Output beat packing ──────────────────────────────────────────────────
  logic        out_valid_r;
  logic [127:0] out_beat_r;
  logic        out_sof_r, out_eol_r;

  // Track sof/eol for output side based on pixel count
  logic [31:0] out_px_cnt;
  logic [15:0] out_px_per_row;
  assign out_px_per_row = desc.out_w;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid_r <= 1'b0;
      out_px_cnt  <= '0;
    end else begin
      out_valid_r <= 1'b0;
      out_sof_r   <= 1'b0;
      out_eol_r   <= 1'b0;

      if (state != RUN_DW && state != RUN_PW)
        out_px_cnt <= '0;

      // DW: pack 8 channels per beat (after requant, tile completes full pixel)
      if (state == RUN_DW && dw_rq_vout && dw_rq_tile_del[3] == dw_out_tiles - 1) begin
        for (int i = 0; i < BEAT_BYTES; i++)
          out_beat_r[8*i +: 8] <= (i < MAC_ROWS) ? dw_rq_out[i] : 8'd0;
        out_valid_r <= 1'b1;
        out_sof_r   <= (out_px_cnt == 0);
        out_eol_r   <= ((out_px_cnt + 1) % out_px_per_row == 0);
        out_px_cnt  <= out_px_cnt + 1;
      end

      // PW: pack out_c bytes, one pixel per beat (out_c ≤ BEAT_BYTES)
      if (state == RUN_PW && pw_valid_out) begin
        for (int i = 0; i < BEAT_BYTES; i++)
          out_beat_r[8*i +: 8] <= (i < MAX_CH) ? pw_pixel_out[i] : 8'sd0;
        out_valid_r <= 1'b1;
        out_sof_r   <= (out_px_cnt == 0);
        out_eol_r   <= ((out_px_cnt + 1) % out_px_per_row == 0);
        out_px_cnt  <= out_px_cnt + 1;
      end
    end
  end

  assign out_valid = out_valid_r && out_ready;
  assign out_beat  = out_beat_r;
  assign out_sof   = out_sof_r;
  assign out_eol   = out_eol_r;

endmodule
