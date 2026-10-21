// isp_blc_wb.sv -- black level and white balance on the raw Bayer stream.
//
//   d = max(v - blc_level, 0);  w = min((d * gain[c]) >> 8, 1023)
//   gain[c] = (blc_gain * wb[c]) >> 8
//
// c is the colour of the site, from the row parity (counted from sof) and the
// column parity (element index: a beat starts on an even column).  Each
// element only ever sees two colours, one per row parity, so both products
// are formed and one is selected: with cfg constant, each multiplier has a
// constant operand and reduces to adders.  Latency 2.
module isp_blc_wb
    import vid_pkg::*;
(
    vpush_if.snk     i,      // raw10_t x 2
    vpush_if.src     o,      // raw10_t x 2
    input isp_cfg_t  cfg
);
    wire clk = i.clk, rst_n = i.rst_n;

    // Colour of element e on a row of parity p: 0 = R, 1 = G, 2 = B.
    function automatic logic [1:0] colour(input logic p, input logic e, input logic [1:0] cfa_r);
        if (p == cfa_r[1] && e == cfa_r[0]) return 2'd0;
        if (p != cfa_r[1] && e != cfa_r[0]) return 2'd2;
        return 2'd1;
    endfunction

    logic [19:0] g_prod [3];
    mul_nodsp #(.AW(10), .BW(10)) u_gr (.a(cfg.blc_gain), .b(cfg.wb_r), .p(g_prod[0]));
    mul_nodsp #(.AW(10), .BW(10)) u_gg (.a(cfg.blc_gain), .b(cfg.wb_g), .p(g_prod[1]));
    mul_nodsp #(.AW(10), .BW(10)) u_gb (.a(cfg.blc_gain), .b(cfg.wb_b), .p(g_prod[2]));

    logic [11:0] gain [2][2];        // [row parity][element]
    always_comb
        for (int p = 0; p < 2; p++)
            for (int e = 0; e < 2; e++)
                gain[p][e] = g_prod[colour(p[0], e[0], cfg.cfa_r)][19:8];

    // Row parity of the line at the input.
    logic row_p;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                  row_p <= 1'b0;
        else if (i.valid && i.eol)   row_p <= i.sof ? 1'b1 : !row_p;
        else if (i.valid && i.sof)   row_p <= 1'b0;
    wire p_now = i.sof ? 1'b0 : row_p;

    // ---------------------------------------------------------- stage 1
    logic        v1, sof1, eol1, p1;
    logic [9:0]  d1 [2];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {v1, sof1, eol1, p1} <= '0;
            d1 <= '{default: '0};
        end else begin
            v1   <= i.valid;
            sof1 <= i.valid && i.sof;
            eol1 <= i.valid && i.eol;
            p1   <= p_now;
            for (int e = 0; e < 2; e++)
                d1[e] <= (i.data[e] > cfg.blc_level) ? i.data[e] - cfg.blc_level : '0;
        end
    end

    // ---------------------------------------------------------- stage 2
    logic [21:0] prod [2][2];        // [row parity][element]
    for (genvar p = 0; p < 2; p++) begin : g_p
        for (genvar e = 0; e < 2; e++) begin : g_e
            mul_nodsp #(.AW(10), .BW(12)) u_mul (.a(d1[e]), .b(gain[p][e]), .p(prod[p][e]));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o.valid <= 1'b0;
            o.sof   <= 1'b0;
            o.eol   <= 1'b0;
            o.data  <= '0;
        end else begin
            o.valid <= v1;
            o.sof   <= sof1;
            o.eol   <= eol1;
            for (int e = 0; e < 2; e++) begin
                logic [13:0] s;
                s = prod[p1][e][21:8];
                o.data[e] <= (s > 14'd1023) ? 10'd1023 : s[9:0];
            end
        end
    end

endmodule
