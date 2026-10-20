// isp_top.v -- CSI-domain ISP: packed RAW in, RGBx32 ({0,R,G,B}) out for DDR writer.
`timescale 1ps/1ps

module isp_top #(
    parameter integer WB_R = 256,
    parameter integer WB_G = 213,
    parameter integer WB_B = 256
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,
    input  wire        hs,
    input  wire        de,
    input  wire [31:0] raw_pack4,
    output wire        rgb_vs,
    output wire        rgb_hs,
    output wire        rgb_de,
    output wire [31:0] rgb_x
);

    wire [15:0] raw16 = raw_pack4[15:0];

    wire        d_vs, d_hs, d_de, d_valid;
    wire [47:0] rgb_datax2;

    debayer_top_2to1 u_debayer (
        .in_pclk       (clk),
        .in_rstn       (rst_n),
        .raw_vs_i      (vs),
        .raw_hs_i      (hs),
        .raw_de_i      (de),
        .raw_valid_i   (de),
        .raw_datax4_i  (raw16),
        .r_gain        (WB_R[15:0]),
        .g_gain        (WB_G[15:0]),
        .b_gain        (WB_B[15:0]),
        .rgb_vs_o      (d_vs),
        .rgb_hs_o      (d_hs),
        .rgb_de_o      (d_de),
        .rgb_valid_o   (d_valid),
        .rgb_bout      (),
        .rgb_gout      (),
        .rgb_rout      (),
        .rgb_datax2_o  (rgb_datax2)
    );

    reg        half;
    reg [7:0]  pix_r, pix_g, pix_b;
    reg        pix_de;

    wire [7:0] lo_r = rgb_datax2[7:0];
    wire [7:0] lo_g = rgb_datax2[15:8];
    wire [7:0] lo_b = rgb_datax2[23:16];
    wire [7:0] hi_r = rgb_datax2[31:24];
    wire [7:0] hi_g = rgb_datax2[39:32];
    wire [7:0] hi_b = rgb_datax2[47:40];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half   <= 1'b0;
            pix_de <= 1'b0;
            pix_r  <= 8'd0;
            pix_g  <= 8'd0;
            pix_b  <= 8'd0;
        end else begin
            pix_de <= 1'b0;
            if (!d_de) begin
                half <= 1'b0;
            end else begin
                if (!half) begin
                    {pix_b, pix_g, pix_r} <= {lo_b, lo_g, lo_r};
                    half   <= 1'b1;
                    pix_de <= 1'b1;
                end else begin
                    {pix_b, pix_g, pix_r} <= {hi_b, hi_g, hi_r};
                    half   <= 1'b0;
                    pix_de <= 1'b1;
                end
            end
        end
    end

    assign rgb_vs = d_vs;
    assign rgb_hs = d_hs;
    assign rgb_de = pix_de;
    assign rgb_x  = {8'd0, pix_r, pix_g, pix_b};

endmodule
