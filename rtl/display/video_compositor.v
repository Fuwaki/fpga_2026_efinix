// video_compositor.v -- v1 single-layer passthrough (DDR camera layer).
`timescale 1ps/1ps

module video_compositor (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       in_de, in_hs, in_vs,
    input  wire [7:0] in_r, in_g, in_b,
    output reg        out_de, out_hs, out_vs,
    output reg [7:0]  out_r, out_g, out_b
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de <= 1'b0;
            out_hs <= 1'b0;
            out_vs <= 1'b0;
            out_r  <= 8'd0;
            out_g  <= 8'd0;
            out_b  <= 8'd0;
        end else begin
            out_de <= in_de;
            out_hs <= in_hs;
            out_vs <= in_vs;
            out_r  <= in_r;
            out_g  <= in_g;
            out_b  <= in_b;
        end
    end
endmodule
