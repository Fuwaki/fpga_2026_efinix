// efx_mac8.v -- signed int8 multiply via explicit EFX_DSP24 primitive
//
// Catalog note: Efinity IP Manager has no standalone Multiplier core for
// Titanium; hard DSP is EFX_DSP48/24/12 primitives (Titanium Primitives UG).
// Two DSP24 pack into one physical DSP block when they share clk/rst.
//
// Multiply-only mode (N_SEL=CONST0 => O = P). Pipeline with A/B/P/O regs
// is LATENCY=3 clocks from (A,B) present to O valid.

module efx_mac8 #(
    parameter integer LATENCY = 3
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,
    input  wire [7:0]  a,
    input  wire [7:0]  b,
    output wire [23:0] p
);
    // LATENCY documents pipeline depth for the PE scheduler.
    // synthesis translate_off
    initial if (LATENCY != 3) $display("efx_mac8: LATENCY param informational only");
    // synthesis translate_on

    EFX_DSP24 #(
        .A_REG(1), .B_REG(1), .C_REG(0), .P_REG(1), .OP_REG(0),
        .W_REG(0), .O_REG(1), .SHIFTER(0), .RST_SYNC(0), .SIGNED(1),
        .P_EXT("ALIGN_RIGHT"), .C_EXT("ALIGN_RIGHT"),
        .M_SEL("P"), .N_SEL("CONST0"), .W_SEL("X"), .CASCOUT_SEL("W"),
        .CLK_POLARITY(1), .CE_POLARITY(1), .RST_POLARITY(1),
        .SHIFT_ENA_POLARITY(1),
        .A_REG_USE_CE(1), .B_REG_USE_CE(1), .C_REG_USE_CE(1),
        .OP_REG_USE_CE(1), .P_REG_USE_CE(1), .W_REG_USE_CE(1), .O_REG_USE_CE(1),
        .A_REG_USE_RST(1), .B_REG_USE_RST(1), .C_REG_USE_RST(1),
        .OP_REG_USE_RST(1), .P_REG_USE_RST(1), .W_REG_USE_RST(1), .O_REG_USE_RST(1)
    ) u_dsp24 (
        .A(a), .B(b), .C(8'd0), .CASCIN(24'd0),
        .OP(2'b00), .SHIFT_ENA(1'b0),
        .CLK(clk), .CE(ce), .RST(rst),
        .O(p), .CASCOUT()
    );
endmodule
