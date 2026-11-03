// isp_dither565.sv -- 8-bit RGB to RGB565 with a 2x2 ordered dither, so the
// gray ramps and skies do not band.
//
//   t = [[0, 2], [3, 1]][y & 1][x & 1]
//   r5 = (31 R + 32 + 64t) >> 8,  g6 = (63 G + 32 + 64t) >> 8,  b5 like r5
//
// The codes are scaled by 31/255 (63/255), not shifted, so the readers'
// bit-replicating unpack565 gets the level back: over a 2x2 cell the four
// unpacked values average to within -2..+1 of the 8-bit input on every level.
// The earlier min(R + 2t + 1, 255) >> 3 rounded up and then replicated the top
// bits on top of that, a bias growing with the level to +6 at 192.
//
// y counts lines from sof, x parity is the element index.  Latency 1.
module isp_dither565
    import vid_pkg::*;
(
    vpush_if.snk     i,      // rgb888_t x 2
    vpush_if.src     o,      // rgb565_t x 2
    input isp_cfg_t  cfg
);
    wire clk = i.clk, rst_n = i.rst_n;

    logic row_p;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                  row_p <= 1'b0;
        else if (i.valid && i.eol)   row_p <= i.sof ? 1'b1 : !row_p;
        else if (i.valid && i.sof)   row_p <= 1'b0;
    wire p_now = i.sof ? 1'b0 : row_p;

    // (31 v + 32 + 64t) >> 8 is at most (7905 + 224) >> 8 = 31, and the 63
    // form at most 63: no saturation.  31 v = 32 v - v, 63 v = 64 v - v.
    function automatic logic [4:0] q5(input logic [7:0] v, input logic [1:0] t);
        logic [12:0] a;
        a = {v, 5'd0} - 13'(v) + 13'd32 + {5'd0, t, 6'd0};
        return a[12:8];
    endfunction

    function automatic logic [5:0] q6(input logic [7:0] v, input logic [1:0] t);
        logic [13:0] a;
        a = {v, 6'd0} - 14'(v) + 14'd32 + {6'd0, t, 6'd0};
        return a[13:8];
    endfunction

    function automatic rgb565_t dither(input rgb888_t p, input logic [1:0] t, input logic en);
        rgb565_t q;
        if (!en) return pack565(p);
        q.r = q5(p.r, t);
        q.g = q6(p.g, t);
        q.b = q5(p.b, t);
        return q;
    endfunction

    // t for (row parity, column parity): [[0, 2], [3, 1]].
    function automatic logic [1:0] thr(input logic yp, input logic xp);
        return yp ? (xp ? 2'd1 : 2'd3) : (xp ? 2'd2 : 2'd0);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o.valid <= 1'b0;
            o.sof   <= 1'b0;
            o.eol   <= 1'b0;
            o.data  <= '0;
        end else begin
            o.valid   <= i.valid;
            o.sof     <= i.valid && i.sof;
            o.eol     <= i.valid && i.eol;
            o.data[0] <= dither(i.data[0], thr(p_now, 1'b0), cfg.dither_en);
            o.data[1] <= dither(i.data[1], thr(p_now, 1'b1), cfg.dither_en);
        end
    end

endmodule
