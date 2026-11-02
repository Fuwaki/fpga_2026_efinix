// st_rq_rom.sv -- the ST block engine's requantisation parameter ROM.
//
// One 64-bit word per output channel, the layout tools/st_gen_params.py
// writes (rq_word, 16 hex digits MSB first):
//
//   [31:0]  bias_int32, two's complement
//   [55:32] mant, 24 bit, bit 23 set (normalised)
//   [61:56] k = 24 - exp
//   [63:62] zero
//
// The scale is r = mant * 2**(-k), which is what st_requant applies.
//
// A read at an address aligned to NB returns NB consecutive words in one
// cycle: lane j of dout is word addr + j, the channels of one DW group.
// DEPTH is the lines of NB words, and the port takes the word address
// divided by NB, so the caller's address is a multiple of NB by construction.
//
// Stored form.  A block RAM read is at most 20 bits wide, so NB x 64 bits
// would cost 13 RAM10.  The ROM stores a 49-bit form of each word instead,
// NB of them per line, and expands it on the way out:
//
//   [19:0]  bias, sign-extended to 32 bits (|bias| < 2**19)
//   [42:20] mant[22:0]; mant[23] is always 1
//   [48:43] k
//
// NB x 49 = 196 bits per line, 10 RAM10.  The line image (HEX, NB x 49 bits
// per line, lane j in bits [49j+48:49j], MSB first) is written by
// tools/st_gen_guided.py and installed by ONE $readmemh straight into the
// array: that is the only form Efinity infers RAM contents from (a copy loop
// with any bit slicing in it leaves the array undriven, and the ROM turns
// into 3.5k LUTs).  load() takes the plain 64-bit word image a testbench
// writes per case and packs it, in simulation only.
module st_rq_rom #(
    parameter int    NB    = 4,
    parameter int    DEPTH = 512,
    parameter string HEX   = "rtl/st_accel_new/gen/guided/st_rq_lines.hex"
) (
    input  logic                     clk,
    input  logic [$clog2(DEPTH)-1:0] addr,   // word address / NB
    output logic [NB-1:0][63:0]      dout
);
    localparam int SW = 49;            // stored bits per word

    logic [NB*SW-1:0] mem [DEPTH];
    logic [NB*SW-1:0] q;

    initial $readmemh(HEX, mem);

`ifndef SYNTHESIS
    // A per-case image of 64-bit words, file order, packed into lines.
    task automatic load(input string path);
        logic [63:0] img [NB*DEPTH];
        for (int i = 0; i < NB * DEPTH; i++)
            img[i] = '0;
        $readmemh(path, img);
        for (int i = 0; i < NB * DEPTH; i++) begin
            if (img[i] != '0 && (img[i][63:62] != 2'b00 || !img[i][55]
                    || img[i][31:19] != {13{img[i][19]}}))
                $error("st_rq_rom: word %0d (%h) outside the 49-bit form", i, img[i]);
            mem[i / NB][SW*(i % NB) +: SW] = {img[i][61:56], img[i][54:32], img[i][19:0]};
        end
    endtask
`endif

    always_ff @(posedge clk) q <= mem[addr];

    // An all-zero word (padding) expands to mant = 2**23, k = 0, bias 0,
    // which no channel reads.
    always_comb begin
        for (int b = 0; b < NB; b++)
            dout[b] = {2'b00, q[SW*b+43 +: 6], 1'b1, q[SW*b+20 +: 23],
                       {12{q[SW*b+19]}}, q[SW*b +: 20]};
    end

    initial begin
        if (NB < 2 || (1 << $clog2(NB)) != NB)
            $error("st_rq_rom: NB must be a power of two, at least 2");
    end
endmodule
