// mul_nodsp.sv -- unsigned multiply kept out of the DSP blocks.
//
// DSP blocks are reserved for the neural-network accelerator, so every
// multiply in the video subsystem goes through this module.  Efinity honours
// syn_use_dsp only on the multiplier's own output signal, which is why it is
// a module and not a function.  With a constant operand synthesis reduces it
// to a few adders.
module mul_nodsp #(
    parameter int AW = 10,
    parameter int BW = 10
) (
    input  logic [AW-1:0]    a,
    input  logic [BW-1:0]    b,
    output logic [AW+BW-1:0] p
);
    (* syn_use_dsp = "no" *) logic [AW+BW-1:0] prod;
    assign prod = (AW + BW)'(a) * (AW + BW)'(b);
    assign p    = prod;
endmodule
