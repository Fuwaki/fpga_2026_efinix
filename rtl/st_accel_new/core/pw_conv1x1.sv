// pw_conv1x1.sv — Pointwise 1×1 Convolution
// Uses mac_array for an in_c × out_c matrix multiply.
// Channel counts are runtime-configurable up to MAX_IN_C / MAX_OUT_C.
// Weights, bias, and per-channel requant multipliers are preloaded by the
// caller into the array ports before frame_start.

module pw_conv1x1
  import st_accel_pkg::*;
#(
  parameter int MAX_IN_C  = 32,
  parameter int MAX_OUT_C = 32
)(
  input  logic clk,
  input  logic rst_n,

  // Runtime channel counts (must be multiples of MAC_COLS / MAC_ROWS)
  input  logic [15:0]  in_c,
  input  logic [15:0]  out_c,

  // One-shot start and per-frame total pixel count
  input  logic         frame_start,
  input  logic [31:0]  num_pixels,

  // Input stream: one pixel per cycle, MAX_IN_C channels (unused channels 0)
  input  logic                    valid_in,
  input  logic signed [7:0]       pixel_in [MAX_IN_C],

  // Weight: [MAX_OUT_C][MAX_IN_C] row-major, preloaded at layer start
  input  logic signed [7:0]       weight [MAX_OUT_C][MAX_IN_C],

  // Bias and requant multiplier (per output channel)
  input  logic signed [31:0]      bias   [MAX_OUT_C],
  input  logic [15:0]             mult   [MAX_OUT_C],
  input  activation_t             activation,

  // Output: quantised int8, out_c channels per pixel
  output logic                    valid_out,
  output logic signed [7:0]       pixel_out [MAX_OUT_C]
);

  localparam int MAX_IN_TILES  = MAX_IN_C  / MAC_COLS;  // 4
  localparam int MAX_OUT_TILES = MAX_OUT_C / MAC_ROWS;  // 4

  // Rounded-up tile counts driven by runtime in_c / out_c
  logic [7:0] in_tiles;
  logic [7:0] out_tiles;
  always_comb begin
    in_tiles  = (in_c  + MAC_COLS - 1) / MAC_COLS;
    out_tiles = (out_c + MAC_ROWS - 1) / MAC_ROWS;
  end

  // ─── Tile counters ────────────────────────────────────────────────────────
  logic [7:0]  in_tile_id;
  logic [7:0]  out_tile_id;
  logic [31:0] pixel_cnt;

  logic signed [7:0]  mac_act    [MAC_COLS];
  logic signed [7:0]  mac_weight [MAC_ROWS][MAC_COLS];
  logic               mac_valid_in;
  logic               mac_acc_clear;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_tile_id   <= '0;
      out_tile_id  <= '0;
      pixel_cnt    <= '0;
      mac_valid_in <= 1'b0;
      mac_acc_clear<= 1'b0;
    end else begin
      mac_valid_in  <= 1'b0;
      mac_acc_clear <= 1'b0;

      if (frame_start) begin
        in_tile_id  <= '0;
        out_tile_id <= '0;
        pixel_cnt   <= '0;
      end else if (valid_in) begin
        // Select input channel slice for this in_tile
        for (int i = 0; i < MAC_COLS; i++) begin
          mac_act[i] <= ((in_tile_id * MAC_COLS + i) < MAX_IN_C)
                        ? pixel_in[in_tile_id * MAC_COLS + i] : 8'sd0;
        end
        // Select weight slice for current out_tile × in_tile
        for (int r = 0; r < MAC_ROWS; r++) begin
          for (int c = 0; c < MAC_COLS; c++) begin
            mac_weight[r][c] <= ((out_tile_id * MAC_ROWS + r) < MAX_OUT_C &&
                                 (in_tile_id  * MAC_COLS + c) < MAX_IN_C)
                                 ? weight[out_tile_id * MAC_ROWS + r]
                                         [in_tile_id  * MAC_COLS + c]
                                 : 8'sd0;
          end
        end
        mac_valid_in  <= 1'b1;
        mac_acc_clear <= (in_tile_id == 0);

        if (in_tile_id == in_tiles - 1) begin
          in_tile_id <= '0;
          if (out_tile_id == out_tiles - 1) begin
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

  // ─── MAC array ────────────────────────────────────────────────────────────
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

  // ─── Requant: fire when the last in_tile of an out_tile completes ─────────
  // in_tile_id has already wrapped back to 0 when mac_valid_out arrives for
  // the last in-tile of a given out-tile.  Track out_tile_id through the
  // 3-cycle mac pipeline to pick the right bias/mult slice.
  logic [7:0] ot_delay [3];   // out_tile_id delayed 3 cycles (mac latency)
  logic       last_in  [3];   // whether this was the last in_tile

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 3; i++) begin
        ot_delay[i] <= '0;
        last_in[i]  <= 1'b0;
      end
    end else begin
      ot_delay[0] <= out_tile_id;
      last_in[0]  <= mac_valid_in && mac_acc_clear; // acc_clear delayed 0→1
      for (int i = 1; i < 3; i++) begin
        ot_delay[i] <= ot_delay[i-1];
        last_in[i]  <= last_in[i-1];
      end
    end
  end

  // Requant fires only when the last in_tile output emerges from mac_array.
  // acc_clear marks the FIRST in_tile of a new out_tile; the last in_tile
  // is the beat just before the next acc_clear (or before next pixel).
  // Simpler: fire requant every time in_tile_id wrapped back to 0 and
  // mac_valid_out is high — detected by last_in[2] delayed pipeline.
  logic               rq_valid_in;
  logic signed [31:0] rq_bias [MAC_ROWS];
  logic [15:0]        rq_mult [MAC_ROWS];
  logic signed [7:0]  rq_out  [MAC_ROWS];
  logic               rq_valid_out;

  assign rq_valid_in = mac_valid_out && last_in[2];

  always_comb begin
    for (int r = 0; r < MAC_ROWS; r++) begin
      rq_bias[r] = ((ot_delay[2] * MAC_ROWS + r) < MAX_OUT_C)
                   ? bias[ot_delay[2] * MAC_ROWS + r] : 32'sd0;
      rq_mult[r] = ((ot_delay[2] * MAC_ROWS + r) < MAX_OUT_C)
                   ? mult[ot_delay[2] * MAC_ROWS + r] : 16'd0;
    end
  end

  requant u_requant (
    .clk       (clk),
    .rst_n     (rst_n),
    .valid_in  (rq_valid_in),
    .activation(activation),
    .valid_out (rq_valid_out),
    .acc_in    (mac_acc),
    .bias      (rq_bias),
    .mult      (rq_mult),
    .data_out  (rq_out)
  );

  // ─── Output collect: accumulate out_tiles into pixel_out ─────────────────
  logic signed [7:0] out_buf [MAX_OUT_C];
  logic [7:0]        tiles_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_out  <= 1'b0;
      tiles_done <= '0;
      for (int i = 0; i < MAX_OUT_C; i++)
        out_buf[i] <= 8'sd0;
    end else begin
      valid_out <= 1'b0;

      if (frame_start) begin
        tiles_done <= '0;
      end else if (rq_valid_out) begin
        for (int r = 0; r < MAC_ROWS; r++) begin
          if ((ot_delay[2] * MAC_ROWS + r) < MAX_OUT_C)
            out_buf[ot_delay[2] * MAC_ROWS + r] <= rq_out[r];
        end
        tiles_done <= tiles_done + 1;
        if (tiles_done == out_tiles - 1) begin
          valid_out  <= 1'b1;
          tiles_done <= '0;
        end
      end
    end
  end

  always_comb begin
    for (int i = 0; i < MAX_OUT_C; i++)
      pixel_out[i] = out_buf[i];
  end


endmodule
