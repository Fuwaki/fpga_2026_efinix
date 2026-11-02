// st_pw_rom.sv -- PW weight ROM of the ST block engine.
//
// DEPTH words of 1024 bits, one registered read port.  A word holds the
// weights of one output tile of 8 and one input tile of 16: byte o*16 + i is
// W[8*ot + o][16*it + i], two's complement int8.  Words are stored output
// tile outer, input tile inner, so the address of (ot, it) of a layer whose
// first word is PW_BASE is PW_BASE + ot*ceil(Cin/16) + it
// (tools/st_gen_params.py, docs/st-accel-engine-adr.md).
//
// HEX is the $readmemh image, one 256-digit word per line, MSB first.
module st_pw_rom #(
    parameter int    DEPTH = 512,
    parameter string HEX   = "rtl/st_accel_new/gen/tiny_dw/st_pw.hex"
) (
    input  logic          clk,
    input  logic [8:0]    addr,
    output logic [1023:0] dout
);
    logic [1023:0] mem [DEPTH];

    initial begin
        for (int a = 0; a < DEPTH; a++) mem[a] = '0;
        $readmemh(HEX, mem);
    end

    always_ff @(posedge clk) dout <= mem[addr];

endmodule
