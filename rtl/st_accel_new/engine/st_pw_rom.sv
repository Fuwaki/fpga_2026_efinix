// st_pw_rom.sv -- PW weight ROM of the ST block engine.
//
// DEPTH words of 1024 bits, one registered read port.  A word holds the
// weights of one output tile of 8 and one input tile of 16: byte o*16 + i is
// W[8*ot + o][16*it + i], two's complement int8.  Words are stored output
// tile outer, input tile inner, so the address of (ot, it) of a layer whose
// first word is PW_BASE is PW_BASE + ot*ceil(Cin/16) + it
// (tools/st_gen_params.py, docs/st-accel-engine-adr.md).
//
// DEPTH 256 holds the guided net's 204 words (26 RAM10 blocks of 1024x10).
//
// HEX is the $readmemh image, one 256-digit word per line, MSB first.
// load() is the one place the image is installed; the initial block calls it
// with HEX and a testbench may call it again with a per-case file.
module st_pw_rom #(
    parameter int    DEPTH = 256,
    parameter string HEX   = "rtl/st_accel_new/gen/guided/st_pw.hex"
) (
    input  logic                     clk,
    input  logic [$clog2(DEPTH)-1:0] addr,
    output logic [1023:0]            dout
);
    logic [1023:0] mem [DEPTH];

    task automatic load(input string path);
        for (int a = 0; a < DEPTH; a++)
            mem[a] = '0;
        $readmemh(path, mem);
    endtask

    initial load(HEX);

    always_ff @(posedge clk) dout <= mem[addr];

endmodule
