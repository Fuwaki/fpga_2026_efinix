// isp_gray_stats.sv -- near-gray pixel statistics for firmware AWB.
//
// Taps the linear RGB after the demosaic, so after the current white balance.
// A pixel counts when it is neither dark nor clipped and its R and B are
// within 3/16 of its G:
//
//   g >= 64,  max(r, g, b) < 1000,  |r - g| < g*3/16,  |b - g| < g*3/16
//
// The sums of r>>2, g>>2, b>>2 over those pixels are latched when the next
// frame starts.  A gray surface under a correct white balance has equal sums;
// their ratios are the residual colour cast, and coloured objects (skin, wood)
// never qualify, unlike a gray-world mean of the whole frame.  The G sum also
// tells how much of the frame qualified.  Only element 0 of each beat (the
// even columns) is counted, and only the top 8 bits: narrow adders, the same
// statistics.  Registers only, no RAM, no DSP.
module isp_gray_stats
    import vid_pkg::*;
(
    vpush_if.snk               i,        // rgb10_t x 2
    output logic [2:0][26:0]   st_sum    // R, G, B (>> 2) of the near-gray pixels
);
    wire clk = i.clk, rst_n = i.rst_n;

    function automatic logic [9:0] absd(input logic [9:0] a, input logic [9:0] b);
        return (a > b) ? a - b : b - a;
    endfunction

    // ---------------------------------------------------------- stage 1
    rgb10_t     p;
    assign p = i.data[0];
    wire [9:0]  tol  = 10'(p.g >> 3) + 10'(p.g >> 4);
    wire        gray = (p.g >= 10'd64) && (p.r < 10'd1000) && (p.g < 10'd1000) && (p.b < 10'd1000)
                    && (absd(p.r, p.g) < tol) && (absd(p.b, p.g) < tol);

    logic       v1, sof1;
    logic [2:0][7:0] p1;             // B, G, R >> 2, or 0
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            {v1, sof1} <= '0;
            p1 <= '0;
        end else begin
            v1   <= i.valid;
            sof1 <= i.valid && i.sof;
            p1   <= gray ? {p.b[9:2], p.g[9:2], p.r[9:2]} : '0;
        end

    // ---------------------------------------------------------- stage 2
    logic [2:0][26:0] acc;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            acc    <= '0;
            st_sum <= '0;
        end else if (v1) begin
            if (sof1) begin
                st_sum <= acc;
                for (int c = 0; c < 3; c++) acc[c] <= 27'(p1[c]);
            end else begin
                for (int c = 0; c < 3; c++) acc[c] <= acc[c] + 27'(p1[c]);
            end
        end
endmodule
