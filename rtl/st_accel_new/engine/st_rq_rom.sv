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
// Stored form.  A block RAM read is at most 20 bits wide, so the ROM's cost
// is its read width: NB x 64 bits would be 13 RAM10.  The banks hold a
// 48-bit form instead, expanded back to the 64-bit word on the way out:
//
//   [19:0]  bias, sign-extended to 32 bits on read (|bias| < 2**19)
//   [42:20] mant[22:0]; mant[23] is always 1
//   [47:43] k - 16 (k is 16..47)
//
// NB x 48 bits = 10 RAM10.  tools/st_gen_guided.py asserts the ranges, and
// load() checks them in simulation.
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
    logic [47:0] bank [NB][DEPTH];     // bank b: the words with addr%NB == b

    function automatic logic [47:0] pack(input logic [63:0] w);
        pack = {5'(w[61:56] - 6'd16), w[54:32], w[19:0]};
    endfunction

    task automatic load(input string path);
        for (int i = 0; i < NB * DEPTH; i++)
            img[i] = '0;
        $readmemh(path, img);
        for (int b = 0; b < NB; b++)
            for (int i = 0; i < DEPTH; i++)
                bank[b][i] = pack(img[NB*i + b]);
`ifndef SYNTHESIS
        for (int i = 0; i < NB * DEPTH; i++)
            if (img[i] != '0 && (img[i][63:62] != 2'b00 || !img[i][55]
                    || img[i][61:56] < 6'd16 || img[i][61:56] > 6'd47
                    || img[i][31:19] != {13{img[i][19]}}))
                $error("st_rq_rom: word %0d (%h) outside the 48-bit form", i, img[i]);
`endif
    endtask

    initial load(HEX);

    logic [47:0] q [NB];
    always_ff @(posedge clk) begin
        for (int b = 0; b < NB; b++)
            q[b] <= bank[b][addr];
    end

    // An all-zero word (unused padding) expands to k = 16, mant = 2**23,
    // bias 0, which no channel reads.
    always_comb begin
        for (int b = 0; b < NB; b++)
            dout[b] = {2'b00, 6'(q[b][47:43]) + 6'd16, 1'b1, q[b][42:20],
                       {12{q[b][19]}}, q[b][19:0]};
    end

    initial begin
        if (NB < 2 || (1 << $clog2(NB)) != NB)
            $error("st_rq_rom: NB must be a power of two, at least 2");
    end
endmodule
