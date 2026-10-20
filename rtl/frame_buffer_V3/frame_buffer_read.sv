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
    parameter int unsigned FIFO_DEPTH = 2048,
    // Geometry of the captured layer, in words (2 px) horizontally and lines
    // vertically.  The raster is 1080p regardless; the layer is placed at the
    // centre and the surround renders black.
    //
    // Both offsets must be EVEN in pixels, because Bayer phase repeats every
    // two pixels and every two lines: an odd offset would rotate the CFA and
    // turn green into magenta.
    parameter int unsigned LAYER_W_WORDS = 640,   // 1280 px
    parameter int unsigned LAYER_H_LINES = 720
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
    output logic [11:0]       level,

    // Per-frame diagnostics, latched at each flush and stable for a frame:
    // stall cycles (raster wanted a word, FIFO empty), FIFO level just before
    // the flush (words the frame produced but never showed), and words pushed.
    output logic [15:0]       dbg_stall,
    output logic [11:0]       dbg_left,
    output logic [23:0]       dbg_push,
    // Sequence checker for the counter test pattern, on the words leaving
    // layer_fetch toward debayer: {pops per frame, input-side break count
    // (saturating), output break count, index of first output break, word at
    // it, word before it}.
    output logic [111:0]      dbg_seq,
    // Raw statistics over the words shown inside the layer, per frame:
    // {sum[row even][hi byte], sum[even][lo], sum[odd][hi], sum[odd][lo]},
    // each sum >> 10, so a channel mean is value * 1024 / (pixels per channel).
    output logic [63:0]       dbg_sum4,
    // {min, max, pixels >= 0xF8 >> 12, pixels <= 0x10 >> 12}, all saturating.
    output logic [31:0]       dbg_mm
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

    logic              lf_stall;

    // The captured layer sits at the centre of the raster.  h_active and
    // v_active arrive in video clocks (960 x 1080) and words respectively:
    // horizontally one word is two pixels while one clock is two pixels, so
    // the units already match.
    wire [12:0] LAYER_X = (h_active > LAYER_W_WORDS) ? ((h_active - LAYER_W_WORDS) >> 1) : 13'd0;
    wire [12:0] LAYER_Y = (v_active > LAYER_H_LINES) ? ((v_active - LAYER_H_LINES) >> 1) : 13'd0;

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
        .layer_x   (LAYER_X[11:0]),
        .layer_y   (LAYER_Y[11:0]),
        .layer_w   (LAYER_W_WORDS[11:0]),
        .layer_h   (LAYER_H_LINES[11:0]),
        .layer_en  (1'b1),
        .in_valid  (in_valid),
        .in_data   (in_data),
        .out_data  (vout),
        .out_valid (lf_out_valid),
        .stall     (lf_stall),
        .level     (level)
    );

    logic        lf_out_valid;
    logic [15:0] oq_prev, oq_bval, oq_bprev;
    logic [23:0] oq_idx, oq_breaks, oq_bidx;
    logic        oq_seen;
    logic [15:0] sq_prev, sq_w0, sq_w1, sq_bval, sq_bprev;
    logic [23:0] sq_idx, sq_breaks, sq_bidx;
    logic        sq_seen;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq_prev <= '0; sq_w0 <= '0; sq_w1 <= '0; sq_bval <= '0; sq_bprev <= '0;
            sq_idx <= '0; sq_breaks <= '0; sq_bidx <= '0; sq_seen <= 1'b0;
        end else if (ras_vline0 & ~vline0_d) begin
            sq_idx    <= '0;
            sq_breaks <= '0;
            sq_seen   <= 1'b0;
        end else if (in_valid) begin
            sq_prev <= in_data[15:0];
            sq_idx  <= sq_idx + 24'd1;
            if (sq_idx == 24'd0) sq_w0 <= in_data[15:0];
            if (sq_idx == 24'd1) sq_w1 <= in_data[15:0];
            if (sq_idx != 24'd0 && in_data[15:0] != sq_prev + 16'd1) begin
                sq_breaks <= sq_breaks + 24'd1;
                if (!sq_seen) begin
                    sq_seen  <= 1'b1;
                    sq_bidx  <= sq_idx;
                    sq_bval  <= in_data[15:0];
                    sq_bprev <= sq_prev;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            oq_prev <= '0; oq_bval <= '0; oq_bprev <= '0;
            oq_idx <= '0; oq_breaks <= '0; oq_bidx <= '0; oq_seen <= 1'b0;
            dbg_seq <= '0;
        end else if (ras_vline0 & ~vline0_d) begin
            dbg_seq   <= {oq_idx,
                          (sq_breaks > 24'd255) ? 8'd255 : sq_breaks[7:0],
                          oq_breaks, oq_bidx, oq_bval, oq_bprev};
            oq_idx    <= '0;
            oq_breaks <= '0;
            oq_seen   <= 1'b0;
        end else if (lf_out_valid) begin
            oq_prev <= vout[15:0];
            oq_idx  <= oq_idx + 24'd1;
            if (oq_idx != 24'd0 && vout[15:0] != oq_prev + 16'd1) begin
                oq_breaks <= oq_breaks + 24'd1;
                if (!oq_seen) begin
                    oq_seen  <= 1'b1;
                    oq_bidx  <= oq_idx;
                    oq_bval  <= vout[15:0];
                    oq_bprev <= oq_prev;
                end
            end
        end
    end

    // Row parity of the word now leaving layer_fetch.  ras_y is one clock
    // ahead of the RAM output, and the layer starts on an even raster line,
    // so the delayed raster parity is the layer's Bayer row parity.
    logic        st_row_odd;
    logic [25:0] st_sum [4];
    logic [7:0]  st_min, st_max;
    logic [19:0] st_sat, st_dark;
    wire  [7:0]  st_hi = vout[15:8];
    wire  [7:0]  st_lo = vout[7:0];
    wire  [7:0]  st_wmin = (st_hi < st_lo) ? st_hi : st_lo;
    wire  [7:0]  st_wmax = (st_hi > st_lo) ? st_hi : st_lo;
    wire  [1:0]  st_nsat  = (st_hi >= 8'hF8) + (st_lo >= 8'hF8);
    wire  [1:0]  st_ndark = (st_hi <= 8'h10) + (st_lo <= 8'h10);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_row_odd <= 1'b0;
            for (int i = 0; i < 4; i++) st_sum[i] <= '0;
            st_min <= 8'hFF; st_max <= 8'h00; st_sat <= '0; st_dark <= '0;
            dbg_sum4 <= '0; dbg_mm <= '0;
        end else begin
            st_row_odd <= ras_y[0];
            if (ras_vline0 & ~vline0_d) begin
                dbg_sum4 <= {st_sum[0][25:10], st_sum[1][25:10],
                             st_sum[2][25:10], st_sum[3][25:10]};
                dbg_mm   <= {st_min, st_max, st_sat[19:12], st_dark[19:12]};
                for (int i = 0; i < 4; i++) st_sum[i] <= '0;
                st_min <= 8'hFF; st_max <= 8'h00; st_sat <= '0; st_dark <= '0;
            end else if (lf_out_valid) begin
                st_sum[{st_row_odd, 1'b0}] <= st_sum[{st_row_odd, 1'b0}] + st_hi;
                st_sum[{st_row_odd, 1'b1}] <= st_sum[{st_row_odd, 1'b1}] + st_lo;
                if (st_wmin < st_min) st_min <= st_wmin;
                if (st_wmax > st_max) st_max <= st_wmax;
                if (st_sat  != 20'hFFFFF) st_sat  <= st_sat  + st_nsat;
                if (st_dark != 20'hFFFFF) st_dark <= st_dark + st_ndark;
            end
        end
    end

    logic        vline0_d;
    logic [15:0] stall_cnt;
    logic [23:0] push_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vline0_d  <= 1'b0;
            stall_cnt <= '0;
            push_cnt  <= '0;
            dbg_stall <= '0;
            dbg_left  <= '0;
            dbg_push  <= '0;
        end else begin
            vline0_d <= ras_vline0;
            if (ras_vline0 & ~vline0_d) begin
                dbg_stall <= stall_cnt;
                dbg_left  <= level;
                dbg_push  <= push_cnt;
                stall_cnt <= '0;
                push_cnt  <= '0;
            end else begin
                if (lf_stall && stall_cnt != 16'hFFFF)
                    stall_cnt <= stall_cnt + 16'd1;
                if (in_valid)
                    push_cnt <= push_cnt + 24'd1;
            end
        end
    end

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
