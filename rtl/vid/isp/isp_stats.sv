// isp_stats.sv -- per-frame statistics of the raw stream, for firmware AE
// (rtl/ui_regs.sv).  Registers only, no RAM.
//
// sum[2 * row parity + column parity] over the frame, and how many pixels are
// clipped (>= 1020).  Results are latched when the next frame starts, and
// st_frames counts the latches so firmware can tell a new frame's numbers from
// the last one's.  The counters are as wide as a 1280x720 frame needs (a phase
// sum < 2^28, the clip count < 2^20); st_dark is no longer counted (reads 0).
module isp_stats
    import vid_pkg::*;
(
    vpush_if.snk          i,         // raw10_t x 2
    output logic [3:0][31:0] st_sum,
    output logic [31:0]   st_clip,
    output logic [31:0]   st_dark,
    output logic [7:0]    st_frames
);
    wire clk = i.clk, rst_n = i.rst_n;

    localparam int SW = 28, CW = 20;

    logic             row_p;
    logic [3:0][SW-1:0] acc, sum_q;
    logic [CW-1:0]    clip, clip_q;
    wire              p_now = i.sof ? 1'b0 : row_p;
    wire [1:0]        n_clip = 2'(i.data[0] >= 10'd1020) + 2'(i.data[1] >= 10'd1020);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_p     <= 1'b0;
            acc       <= '0;
            clip      <= '0;
            sum_q     <= '0;
            clip_q    <= '0;
            st_frames <= '0;
        end else if (i.valid) begin
            if (i.eol) row_p <= !p_now;
            else       row_p <= p_now;
            if (i.sof) begin
                sum_q     <= acc;
                clip_q    <= clip;
                st_frames <= st_frames + 8'd1;
                for (int k = 0; k < 4; k++) acc[k] <= '0;
                acc[0] <= SW'(i.data[0]);
                acc[1] <= SW'(i.data[1]);
                clip   <= CW'(n_clip);
            end else begin
                acc[{p_now, 1'b0}] <= acc[{p_now, 1'b0}] + SW'(i.data[0]);
                acc[{p_now, 1'b1}] <= acc[{p_now, 1'b1}] + SW'(i.data[1]);
                clip <= clip + CW'(n_clip);
            end
        end
    end

    always_comb
        for (int k = 0; k < 4; k++) st_sum[k] = 32'(sum_q[k]);
    assign st_clip = 32'(clip_q);
    assign st_dark = '0;
endmodule
