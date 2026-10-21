// isp_sat.sv -- saturation around luma, the ac6b658 display-side formula:
//
//   Y = (77 R + 150 G + 29 B) >> 8
//   u = C + 256 - Y,  p = (sat * u) >> 8,  C' = clamp(Y + p - sat, 0, 255)
//
// i.e. C' = Y + sat * (C - Y) / 256 without signed arithmetic.  All
// multipliers have a constant operand (the weights, and sat while it is a
// compile-time setting), so they are adders.  Latency 2.
module isp_sat
    import vid_pkg::*;
(
    vpush_if.snk     i,      // rgb888_t x 2
    vpush_if.src     o,      // rgb888_t x 2
    input isp_cfg_t  cfg
);
    wire clk = i.clk, rst_n = i.rst_n;

    // ---------------------------------------------------------- stage 1: Y
    logic [15:0] wr [2], wg [2], wb [2];
    for (genvar p = 0; p < 2; p++) begin : g_y
        mul_nodsp #(.AW(8), .BW(8)) u_r (.a(i.data[p].r), .b(8'd77),  .p(wr[p]));
        mul_nodsp #(.AW(8), .BW(8)) u_g (.a(i.data[p].g), .b(8'd150), .p(wg[p]));
        mul_nodsp #(.AW(8), .BW(8)) u_b (.a(i.data[p].b), .b(8'd29),  .p(wb[p]));
    end

    logic       v1, sof1, eol1;
    rgb888_t    c1 [2];
    logic [7:0] y1 [2];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {v1, sof1, eol1} <= '0;
            c1 <= '{default: '0};
            y1 <= '{default: '0};
        end else begin
            v1   <= i.valid;
            sof1 <= i.valid && i.sof;
            eol1 <= i.valid && i.eol;
            for (int p = 0; p < 2; p++) begin
                logic [15:0] s;
                s = wr[p] + wg[p] + wb[p];        // weights sum to 256: no overflow
                c1[p] <= i.data[p];
                y1[p] <= s[15:8];
            end
        end
    end

    // ------------------------------------------------------- stage 2: C'
    function automatic logic [8:0] lift(input logic [7:0] c, input logic [7:0] y);
        return 9'(c) + 9'd256 - 9'(y);               // 1 .. 511
    endfunction

    logic [8:0]  u [2][3];
    logic [18:0] sp [2][3];
    for (genvar p = 0; p < 2; p++) begin : g_s
        assign u[p][0] = lift(c1[p].r, y1[p]);
        assign u[p][1] = lift(c1[p].g, y1[p]);
        assign u[p][2] = lift(c1[p].b, y1[p]);
        for (genvar c = 0; c < 3; c++) begin : g_c
            mul_nodsp #(.AW(9), .BW(10)) u_m (.a(u[p][c]), .b(cfg.sat), .p(sp[p][c]));
        end
    end

    function automatic logic [7:0] clip(input logic [7:0] y, input logic [18:0] prod,
                                        input logic [9:0] s);
        logic [11:0] pre;
        pre = 12'(y) + 12'(prod[18:8]);
        if (pre <= 12'(s))              return 8'd0;
        if (pre - 12'(s) > 12'd255)     return 8'd255;
        return 8'(pre - 12'(s));
    endfunction

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
            for (int p = 0; p < 2; p++)
                o.data[p] <= cfg.bypass_sat ? c1[p]
                           : '{r: clip(y1[p], sp[p][0], cfg.sat),
                               g: clip(y1[p], sp[p][1], cfg.sat),
                               b: clip(y1[p], sp[p][2], cfg.sat)};
        end
    end

endmodule
