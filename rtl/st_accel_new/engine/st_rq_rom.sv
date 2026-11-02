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
// The ROM has NB banks; bank b holds the words with addr % NB == b, each
// loaded from the same hex.  A read at an address aligned to NB therefore
// returns NB consecutive words in one cycle: lane j of dout is word
// addr + j, the channels of one DW group.  DEPTH is the words per bank, and
// the port takes the word address divided by NB, so the caller's address is
// a multiple of NB by construction.
//
// load() is the one place the image is installed; the initial block calls it
// with HEX and a testbench may call it again with a per-case file.
module st_rq_rom #(
    parameter int    NB    = 4,
    parameter int    DEPTH = 512,
    parameter string HEX   = "rtl/st_accel_new/gen/guided/st_rq.hex"
) (
    input  logic                     clk,
    input  logic [$clog2(DEPTH)-1:0] addr,   // word address / NB
    output logic [NB-1:0][63:0]      dout
);
    logic [63:0] img [NB*DEPTH];       // the full image, in file order
    logic [63:0] bank [NB][DEPTH];     // bank b: the words with addr%NB == b

    task automatic load(input string path);
        for (int i = 0; i < NB * DEPTH; i++)
            img[i] = '0;
        $readmemh(path, img);
        for (int b = 0; b < NB; b++)
            for (int i = 0; i < DEPTH; i++)
                bank[b][i] = img[NB*i + b];
    endtask

    initial load(HEX);

    always_ff @(posedge clk) begin
        for (int b = 0; b < NB; b++)
            dout[b] <= bank[b][addr];
    end

    initial begin
        if (NB < 2 || (1 << $clog2(NB)) != NB)
            $error("st_rq_rom: NB must be a power of two, at least 2");
    end
endmodule
