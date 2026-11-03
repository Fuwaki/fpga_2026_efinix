// ui_regs.sv -- APB slave for the menu and the ISP's AWB/AE.
//
// Sapphire presents a byte address.  The top gates PSEL to 0x8000-0x803F, so
// the accelerator's low window (0x34-0x54) is left alone.
//   0x8000 CTRL    bit 0 osd_en, reset 1.  Other bits read 0.
//   0x8004 MENU    bit 0 view_full (reset 0), bit 1 single_sel (reset 1),
//                  bit 2 cursor (reset 0), bits [4:3] style (reset 0).
//   0x8008 GAIN_RG ISP gain Q4.8: [11:0] R, [27:16] G   } reset: the compile-time
//   0x800C GAIN_B  [11:0] B                             } white balance
//   0x8010-0x801C  raw sum of the last frame by {row, column} parity  (read only)
//   0x8020 CLIP    pixels >= 1020 in the last frame                    (read only)
//   0x8024 KEY1    bit 0: KEY1 held (debounced; the firmware's white-paper key)
//   0x8028 FRAMES  [7:0] frames counted by the statistics, wraps       (read only)
//   0x802C-0x8034  R, G, B (>> 2) sums of the near-gray pixels after WB (read only)
// The ISP takes the gains at its next frame start.
module ui_regs
    import vid_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] paddr,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    output logic        osd_en,
    output logic        view_full,
    output logic        single_sel,
    output logic        cursor,
    output logic [1:0]  style,

    output isp_gain_t   isp_gain,
    input  logic [3:0][31:0] raw_sum,
    input  logic [31:0] raw_clip,
    input  logic        key1,
    input  logic [7:0]  raw_frames,
    input  logic [2:0][26:0] gray_sum
);
    localparam isp_gain_t GAIN_RST = isp_gain_of(ISP_CFG_DEFAULT);

    wire       wr  = psel && penable && pwrite;
    wire [3:0] reg_a = paddr[5:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            osd_en     <= 1'b1;
            view_full  <= 1'b0;
            single_sel <= 1'b1;
            cursor     <= 1'b0;
            style      <= 2'd0;
            isp_gain   <= GAIN_RST;
        end else if (wr) begin
            case (reg_a)
                4'd0: osd_en <= pwdata[0];
                4'd1: begin
                    view_full  <= pwdata[0];
                    single_sel <= pwdata[1];
                    cursor     <= pwdata[2];
                    style      <= pwdata[4:3];
                end
                4'd2: begin
                    isp_gain[0] <= pwdata[11:0];
                    isp_gain[1] <= pwdata[27:16];
                end
                4'd3: isp_gain[2] <= pwdata[11:0];
                default: ;
            endcase
        end
    end

    always_comb begin
        case (reg_a)
            4'd0:    prdata = {31'd0, osd_en};
            4'd1:    prdata = {27'd0, style, cursor, single_sel, view_full};
            4'd2:    prdata = {4'd0, isp_gain[1], 4'd0, isp_gain[0]};
            4'd3:    prdata = {20'd0, isp_gain[2]};
            4'd4:    prdata = raw_sum[0];
            4'd5:    prdata = raw_sum[1];
            4'd6:    prdata = raw_sum[2];
            4'd7:    prdata = raw_sum[3];
            4'd8:    prdata = raw_clip;
            4'd9:    prdata = {31'd0, key1};
            4'd10:   prdata = {24'd0, raw_frames};
            4'd11:   prdata = {5'd0, gray_sum[0]};
            4'd12:   prdata = {5'd0, gray_sum[1]};
            4'd13:   prdata = {5'd0, gray_sum[2]};
            default: prdata = 32'd0;
        endcase
    end

    assign pready  = psel;
    assign pslverr = 1'b0;
endmodule
