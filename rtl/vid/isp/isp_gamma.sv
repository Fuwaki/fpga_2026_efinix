// isp_gamma.sv -- gamma curve by table, 10 bit in, top 8 bits of the 10-bit
// table entry out.
//
// Six lookups per clock (3 channels x 2 pixels): one 1024 x 10 table per
// channel, each read through both ports of its block RAM, so three blocks
// in all.  Latency 2 (registered table read, then the output register).
module isp_gamma
    import vid_pkg::*;
#(
    parameter string CURVE = "./rtl/gamma_conrrection/SRGB_ENC.mem"
) (
    vpush_if.snk     i,      // rgb10_t x 2
    vpush_if.src     o,      // rgb888_t x 2
    input isp_cfg_t  cfg
);
    wire clk = i.clk, rst_n = i.rst_n;

    logic [9:0] q [3][2];    // [channel][pixel]

    for (genvar c = 0; c < 3; c++) begin : g_ch
        logic [9:0] rom [1024];
        initial $readmemh(CURVE, rom);

        function automatic logic [9:0] chan(input rgb10_t p);
            return (c == 0) ? p.r : (c == 1) ? p.g : p.b;
        endfunction

        always_ff @(posedge clk) begin
            q[c][0] <= rom[chan(i.data[0])];
            q[c][1] <= rom[chan(i.data[1])];
        end
    end

    logic       v1, sof1, eol1;
    rgb10_t     in1 [2];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {v1, sof1, eol1} <= '0;
            in1 <= '{default: '0};
        end else begin
            v1   <= i.valid;
            sof1 <= i.valid && i.sof;
            eol1 <= i.valid && i.eol;
            in1  <= '{i.data[0], i.data[1]};
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
            for (int p = 0; p < 2; p++)
                o.data[p] <= cfg.bypass_gamma
                           ? '{r: in1[p].r[9:2], g: in1[p].g[9:2], b: in1[p].b[9:2]}
                           : '{r: q[0][p][9:2],  g: q[1][p][9:2],  b: q[2][p][9:2]};
        end
    end

endmodule
