// Upsample 1 RGB pixel @ vid_clk to 2 pixel clocks @ hdmi_clk (148.5MHz).
// Input stream is CAM_ACTIVE_W active DE per line; output is DISP_HRES timing
// with content centered (black outside).
`timescale 1ps/1ps
`include "video/video_pkg.vh"

module hdmi_rgb_center #(
    parameter integer CAM_W = `CAM_ACTIVE_W,
    parameter integer CAM_H = `CAM_ACTIVE_H,
    parameter integer DISP_W = `DISP_HRES,
    parameter integer DISP_H = `DISP_VRES,
    parameter integer H_MARGIN = `DISP_H_MARGIN,
    parameter integer V_MARGIN = `DISP_V_MARGIN
) (
    input  wire       vid_clk,
    input  wire       hdmi_clk,
    input  wire       rst_n,
    input  wire       in_vs, in_hs, in_de,
    input  wire [7:0] in_r, in_g, in_b,
    output reg        out_vs, out_hs, out_de,
    output reg [7:0]  out_r, out_g, out_b
);
    reg in_vs_d, in_hs_d;
    always @(posedge vid_clk) begin
        in_vs_d <= in_vs;
        in_hs_d <= in_hs;
    end

    reg [11:0] h_cnt, v_cnt;
    reg [7:0]  hold_r, hold_g, hold_b;
    reg        hold_valid;

    always @(posedge vid_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 0;
            v_cnt <= 0;
        end else begin
            if (in_vs && !in_vs_d) begin
                h_cnt <= 0;
                v_cnt <= 0;
            end else if (in_de) begin
                if (h_cnt == CAM_W - 1) begin
                    h_cnt <= 0;
                    v_cnt <= v_cnt + 1'b1;
                end else
                    h_cnt <= h_cnt + 1'b1;
            end
            if (in_de) begin
                hold_r <= in_r;
                hold_g <= in_g;
                hold_b <= in_b;
                hold_valid <= 1'b1;
            end else
                hold_valid <= 1'b0;
        end
    end

    reg [11:0] oh, ov;
    reg        toggle;

    always @(posedge hdmi_clk or negedge rst_n) begin
        if (!rst_n) begin
            oh <= 0;
            ov <= 0;
            toggle <= 0;
            out_de <= 0;
            out_vs <= 0;
            out_hs <= 0;
            out_r <= 0;
            out_g <= 0;
            out_b <= 0;
        end else begin
            toggle <= ~toggle;
            if (oh == DISP_W - 1) begin
                oh <= 0;
                ov <= (ov == DISP_H - 1) ? 0 : ov + 1'b1;
            end else
                oh <= oh + 1'b1;

            out_vs <= (ov == 0) && (oh == 0);
            out_hs <= (oh == 0);
            out_de <= (ov >= V_MARGIN) && (ov < V_MARGIN + CAM_H) &&
                      (oh >= H_MARGIN) && (oh < H_MARGIN + CAM_W);
            if (out_de && toggle && hold_valid)
                {out_b, out_g, out_r} <= {hold_b, hold_g, hold_r};
            else if (!out_de) begin
                out_r <= 0;
                out_g <= 0;
                out_b <= 0;
            end
        end
    end
endmodule
