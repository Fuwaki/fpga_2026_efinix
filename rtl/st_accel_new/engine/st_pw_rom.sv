// st_pw_rom.sv -- PW weight ROM of the ST block engine.
//
// DEPTH lines of 512 bits, one registered read port with a clock enable.  A line is half of a
// weight word: a word holds the weights of one output tile of 8 and one input
// tile of 16, byte o*16 + i = W[8*ot + o][16*it + i], two's complement int8.
// Words are stored output tile outer, input tile inner, so the address of
// (ot, it) of a layer whose first word is PW_BASE is PW_BASE + ot*ceil(Cin/16)
// + it (tools/st_gen_params.py, docs/st-accel-engine-adr.md).
//
// The stage reads a word in two halves, one per pixel of a pixel pair, so the
// array still gets a full 1024-bit word every cycle while the ROM supplies
// only 512 bits per cycle:
//
//   line 2a     bits [511:0]  of word a -- output lanes 0..3
//   line 2a + 1 bits [1023:512] of word a -- output lanes 4..7
//
// Half the width for the same word count halves the block RAM: the guided
// net's 204 words are 408 lines, and 512 x 512 bits is 26 RAM10 at 512x20
// (a 1024-bit word would be 52).
//
// HEX is the $readmemh image, one 128-digit line per line of the ROM, MSB
// first.  load() is the one place the image is installed; the initial block
// calls it with HEX and a testbench may call it again with a per-case file.
module st_pw_rom #(
    parameter int    DEPTH = 512,
    parameter string HEX   = "rtl/st_accel_new/gen/guided/st_pw.hex"
) (
    input  logic                     clk,
    input  logic                     ce,      // hold the line and the output
    input  logic [$clog2(DEPTH)-1:0] addr,
    output logic [511:0]             dout
);
    logic [511:0] mem [DEPTH];

    task automatic load(input string path);
        for (int a = 0; a < DEPTH; a++)
            mem[a] = '0;
        $readmemh(path, mem);
    endtask

    initial load(HEX);

    always_ff @(posedge clk)
        if (ce) dout <= mem[addr];

endmodule
