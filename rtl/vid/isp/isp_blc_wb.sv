// isp_blc_wb.sv -- black level and white balance on the raw Bayer stream.
//
//   d = max(v - blc_level, 0);  w = min((d * gain[c]) >> 8, 1023)
//
// gain[c] (Q4.8, c = R/G/B) comes from firmware AWB/AE at run time; its reset
// value (ui_regs) is (blc_gain * wb[c]) >> 8 of the compile-time cfg.  It
// is taken at sof, so a frame is never split between two white balances.
//
// c is the colour of the site, from the row parity (counted from sof) and the
// column parity (element index: a beat starts on an even column).  Each
// element only ever sees two colours, one per row parity, so stage 1 selects
// the element's gain and stage 2 has one multiplier per element, registered
// before the clamp in stage 3 (a full 10x12 product, no DSP).  Latency 3.
module isp_blc_wb
    import vid_pkg::*;
(
    vpush_if.snk     i,      // raw10_t x 2
    vpush_if.src     o,      // raw10_t x 2
    input isp_cfg_t  cfg,
    input isp_gain_t gain
);
    wire clk = i.clk, rst_n = i.rst_n;

    // Colour of element e on a row of parity p: 0 = R, 1 = G, 2 = B.
    function automatic logic [1:0] colour(input logic p, input logic e, input logic [1:0] cfa_r);
        if (p == cfa_r[1] && e == cfa_r[0]) return 2'd0;
        if (p != cfa_r[1] && e != cfa_r[0]) return 2'd2;
        return 2'd1;
    endfunction

    // Gain of this frame: the input at sof, held until the next sof.  Every
    // pixel follows a sof, so the reset value is never used (and a computed
    // one is not constant-folded by Efinity: it took a DSP).
    isp_gain_t gain_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                  gain_q <= '0;
        else if (i.valid && i.sof)   gain_q <= gain;
    isp_gain_t gain_f;
    assign gain_f = (i.valid && i.sof) ? gain : gain_q;

    // Row parity of the line at the input.
    logic row_p;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                  row_p <= 1'b0;
        else if (i.valid && i.eol)   row_p <= i.sof ? 1'b1 : !row_p;
        else if (i.valid && i.sof)   row_p <= 1'b0;
    wire p_now = i.sof ? 1'b0 : row_p;

    // ---------------------------------------------------------- stage 1
    logic        v1, sof1, eol1;
    logic [9:0]  d1 [2];
    logic [11:0] g1 [2];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {v1, sof1, eol1} <= '0;
            d1 <= '{default: '0};
            g1 <= '{default: '0};
        end else begin
            v1   <= i.valid;
            sof1 <= i.valid && i.sof;
            eol1 <= i.valid && i.eol;
            for (int e = 0; e < 2; e++) begin
                d1[e] <= (i.data[e] > cfg.blc_level) ? i.data[e] - cfg.blc_level : '0;
                g1[e] <= gain_f[colour(p_now, e[0], cfg.cfa_r)];
            end
        end
    end

    // ---------------------------------------------------------- stage 2
    logic [21:0] prod [2];
    for (genvar e = 0; e < 2; e++) begin : g_e
        mul_nodsp #(.AW(10), .BW(12)) u_mul (.a(d1[e]), .b(g1[e]), .p(prod[e]));
    end

    logic        v2, sof2, eol2;
    logic [13:0] s2 [2];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {v2, sof2, eol2} <= '0;
            s2 <= '{default: '0};
        end else begin
            v2   <= v1;
            sof2 <= sof1;
            eol2 <= eol1;
            for (int e = 0; e < 2; e++) s2[e] <= prod[e][21:8];
        end
    end

    // ---------------------------------------------------------- stage 3

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o.valid <= 1'b0;
            o.sof   <= 1'b0;
            o.eol   <= 1'b0;
            o.data  <= '0;
        end else begin
            o.valid <= v2;
            o.sof   <= sof2;
            o.eol   <= eol2;
            for (int e = 0; e < 2; e++)
                o.data[e] <= (s2[e] > 14'd1023) ? 10'd1023 : s2[e][9:0];
        end
    end

endmodule
