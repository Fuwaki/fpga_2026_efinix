// frame_buffer_read.sv -- the read half of the frame store.
//
// Replaces data_tx, which conflated three jobs: generating HDMI sync,
// pacing the DDR read engine, and unpacking pixels.  Those responsibilities
// are now separate:
//
//   raster_gen   owns all sync.  No input but clock/reset.
//   frame_sync   derives one read-start pulse per displayed frame.  This is
//                what the old code got from its own h/v state machine, which
//                is why the read rate was pinned to the pixel rate.
//   layer_fetch  buffers the incoming words and hands one to the raster per
//                clock, inside the active window.
//
// The upstream contract is deliberately the loosest one that still works:
// a valid/data pair whose producer may stall but never needs a ready.  That
// matches par2ser, which pushes at its own rate.
module frame_buffer_read
  import video_contract_pkg::*;
#(
    parameter int unsigned DATA_W     = 16,
    parameter int unsigned FIFO_DEPTH = 2048
) (
    input  logic              clk,
    input  logic              rst_n,

    // timing for the current mode, in video clocks / lines
    input  logic [12:0]       h_active,
    input  logic [12:0]       h_fp,
    input  logic [12:0]       h_sync,
    input  logic [12:0]       h_bp,
    input  logic [12:0]       v_active,
    input  logic [12:0]       v_fp,
    input  logic [12:0]       v_sync,
    input  logic [12:0]       v_bp,

    // upstream: words pushed by the frame store, no back-pressure needed
    input  logic              in_valid,
    input  logic [DATA_W-1:0] in_data,

    // to the DDR read engine: start a frame at the base address
    output logic              frame_period,

    // to the display pipeline
    output logic [DATA_W-1:0] vout,
    output logic              o_hs,
    output logic              o_vs,
    output logic              o_de,

    // FIFO occupancy, so the producer can be throttled
    output logic [11:0]       level
);

    logic        ras_de, ras_hs, ras_vs, ras_sof, ras_vline0;
    logic [11:0] ras_x, ras_y;

    raster_gen u_raster (
        .clk     (clk),
        .rst_n   (rst_n),
        .h_active(h_active),
        .h_fp    (h_fp),
        .h_sync  (h_sync),
        .h_bp    (h_bp),
        .v_active(v_active),
        .v_fp    (v_fp),
        .v_sync  (v_sync),
        .v_bp    (v_bp),
        .hs      (ras_hs),
        .vs      (ras_vs),
        .de      (ras_de),
        .x       (ras_x),
        .y       (ras_y),
        .sof     (ras_sof),
        .vline_zero(ras_vline0)
    );

    frame_sync u_frame_sync (
        .clk         (clk),
        .rst_n       (rst_n),
        .vline_zero  (ras_vline0),
        .frame_period(frame_period)
    );

    // One layer covering the whole active area.  A CSR block would drive these
    // later; the point of keeping them as ports is that nothing in the timing
    // path depends on the layer's size.
    wire [11:0] LAYER_X = h_active[11:0];
    wire [11:0] LAYER_Y = 12'd0;

    logic              lf_stall;

    layer_fetch #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .DATA_W    (DATA_W)
    ) u_layer_fetch (
        .clk       (clk),
        .rst_n     (rst_n),
        .flush     (ras_vline0),
        .de        (ras_de),
        .x         (ras_x),
        .y         (ras_y),
        .layer_x   (12'd0),
        .layer_y   (12'd0),
        .layer_w   (h_active[11:0]),
        .layer_h   (v_active[11:0]),
        .layer_en  (1'b1),
        .in_valid  (in_valid),
        .in_data   (in_data),
        .out_data  (vout),
        .out_valid (),
        .stall     (lf_stall),
        .level     (level)
    );

    logic unused_stall;
    assign unused_stall = lf_stall;

    // layer_fetch's RAM has a one-clock registered read, so the word and its
    // valid flag both appear one clock after the raster position that asked
    // for them.  The accompanying sync is delayed by that same single clock;
    // adding a second stage would leave de one clock ahead of the data.
    logic hs_d1, vs_d1, de_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_d1 <= 1'b0;
            vs_d1 <= 1'b0;
            de_d1 <= 1'b0;
        end else begin
            hs_d1 <= ras_hs;
            vs_d1 <= ras_vs;
            de_d1 <= ras_de;
        end
    end

    assign o_hs = hs_d1;
    assign o_vs = vs_d1;
    assign o_de = de_d1;

endmodule
