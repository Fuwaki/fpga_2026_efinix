// isp_stats.sv -- per-frame statistics of the raw stream, for exposure and
// white balance by hand today and by firmware later.  Registers only, no RAM.
//
// sum[2 * row parity + column parity] over the frame, and how many pixels are
// clipped (>= 1020) or near black (< 80).  Results are latched when the next
// frame starts.
module isp_stats
    import vid_pkg::*;
(
    vpush_if.snk          i,         // raw10_t x 2
    output logic [3:0][31:0] st_sum,
    output logic [31:0]   st_clip,
    output logic [31:0]   st_dark
);
    wire clk = i.clk, rst_n = i.rst_n;

    logic        row_p;
    logic [3:0][31:0] acc;
    logic [31:0] clip, dark;
    wire         p_now = i.sof ? 1'b0 : row_p;

    function automatic logic [1:0] n_if(input logic [9:0] a, input logic [9:0] b, input bit hi);
        return hi ? 2'(a >= 10'd1020) + 2'(b >= 10'd1020)
                  : 2'(a <  10'd80)   + 2'(b <  10'd80);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_p   <= 1'b0;
            acc     <= '0;
            clip    <= '0;
            dark    <= '0;
            st_sum  <= '0;
            st_clip <= '0;
            st_dark <= '0;
        end else if (i.valid) begin
            if (i.eol) row_p <= !p_now;
            else       row_p <= p_now;
            if (i.sof) begin
                st_sum  <= acc;
                st_clip <= clip;
                st_dark <= dark;
                for (int k = 0; k < 4; k++) acc[k] <= '0;
                acc[0] <= 32'(i.data[0]);
                acc[1] <= 32'(i.data[1]);
                clip   <= 32'(n_if(i.data[0], i.data[1], 1));
                dark   <= 32'(n_if(i.data[0], i.data[1], 0));
            end else begin
                acc[{p_now, 1'b0}] <= acc[{p_now, 1'b0}] + 32'(i.data[0]);
                acc[{p_now, 1'b1}] <= acc[{p_now, 1'b1}] + 32'(i.data[1]);
                clip <= clip + 32'(n_if(i.data[0], i.data[1], 1));
                dark <= dark + 32'(n_if(i.data[0], i.data[1], 0));
            end
        end
    end
endmodule
