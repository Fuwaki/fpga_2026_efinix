// ui_regs.sv -- two-word APB menu slave.
//
// Sapphire presents a byte address.  Only 0x8000 and 0x8004 belong to this
// slave; the top gates PSEL so the accelerator's low window (0x34-0x54) is
// left alone.
//   0x8000 CTRL  bit 0 osd_en, reset 1.  Other bits read 0.
//   0x8004 MENU  bit 0 view_full (reset 0), bit 1 single_sel (reset 1),
//                bit 2 cursor (reset 0), bits [4:3] style (reset 0).
module ui_regs (
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
    output logic [1:0]  style
);
    wire wr = psel && penable && pwrite;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            osd_en     <= 1'b1;
            view_full  <= 1'b0;
            single_sel <= 1'b1;
            cursor     <= 1'b0;
            style      <= 2'd0;
        end else if (wr && paddr[15:0] == 16'h8000) begin
            osd_en <= pwdata[0];
        end else if (wr && paddr[15:0] == 16'h8004) begin
            view_full  <= pwdata[0];
            single_sel <= pwdata[1];
            cursor     <= pwdata[2];
            style      <= pwdata[4:3];
        end
    end

    always_comb begin
        prdata = 32'd0;
        if (paddr[15:0] == 16'h8000)
            prdata = {31'd0, osd_en};
        else if (paddr[15:0] == 16'h8004)
            prdata = {27'd0, style, cursor, single_sel, view_full};
    end

    assign pready  = psel;
    assign pslverr = 1'b0;
endmodule
