// isp_dither565.sv -- 8-bit RGB to RGB565 with a 2x2 ordered dither, so the
// gray ramps and skies do not band.
//
//   t = [[0, 2], [3, 1]][y & 1][x & 1]
//   r5 = min(R + 2t + 1, 255) >> 3,  g6 = min(G + t, 255) >> 2,  b5 like r5
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

    function automatic logic [7:0] add_sat(input logic [7:0] v, input logic [2:0] t);
        logic [8:0] s;
        s = 9'(v) + 9'(t);
        return s[8] ? 8'd255 : s[7:0];
    endfunction

    function automatic rgb565_t dither(input rgb888_t p, input logic [1:0] t, input logic en);
        rgb888_t q;
        if (!en) return pack565(p);
        q.r = add_sat(p.r, {t, 1'b1});
        q.g = add_sat(p.g, {1'b0, t});
        q.b = add_sat(p.b, {t, 1'b1});
        return pack565(q);
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
