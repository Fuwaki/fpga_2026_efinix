// frame_sync.sv -- one frame marker per displayed frame, in the video clock.
//
// Consumers and their edge convention:
//   * vid_par2ser: frame_start_w = {frame_period_r0, frame_period} == 2'b01,
//     which clears its shift counters and its read-enable request.
//   * ddr_rd_buffer: pos_start = start_sync[1:0] == 2'b01, restarting the DDR
//     burst at the frame base address.
//
// Both are RISING-EDGE detectors, so the DUTY CYCLE is part of the contract,
// not just the edge.  All three properties below come from the original
// data_tx implementation:
//
//   Polarity: original drove ~(v_state == S_V_SYNC && v_cnt == 0), i.e. HIGH
//   with a LOW interval at the frame boundary.
//
//   Phase: the low interval covers vertical-sync line 0, which the raster
//   generator supplies as vline_zero (vc == 0).
//
//   Width: THE LOW INTERVAL LASTS A WHOLE LINE, not a single clock.  v_cnt
//   stays 0 for every clock of that line, so the original held LOW for
//   H_TOTAL clocks (1100 in 1080p60).
//
//   The width is what actually matters here.  par2ser keeps its last AXI beat
//   latched in `data_buffer` after a frame ends.  A one-clock marker is long
//   enough to fire the edge but not long enough to drain that latch, so the
//   stale beat from the previous frame is emitted as the first beat of the new
//   one.  Every following beat is then one position early: a strip of the
//   right edge appears at the left edge, exactly one AXI beat wide
//   (8 words / 16 pixels out of 1920).
//
// Letting the low interval span the whole line gives par2ser the time it needs
// to re-arm against an empty pipe, which is what the original relied on.
module frame_sync (
    input  logic clk,
    input  logic rst_n,

    input  logic vline_zero,  // high during line 0 of the frame (vc == 0)

    output logic frame_period // HIGH, LOW for one full line at the boundary
);

    // Registered copy of the line-active window, matching the original's
    // one-clock-delayed assignment.  The rising edge at the end of the line is
    // the frame marker both consumers detect.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_period <= 1'b1;
        else
            frame_period <= ~vline_zero;
    end

endmodule
