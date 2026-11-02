// st_line_ram.sv -- one line of the ST DW stage's 3x3 window buffer.
//
// One write port and one read port on the same clock, registered read data;
// the canonical simple-dual-port block-RAM form.  The depth is split into a
// 2048-word and a 512-word bank because Efinity rounds a non-power-of-two
// depth up before it splits the array: one 2560 x 40 array would cost the
// 4096 x 40 shape, 20 RAM10, while the two banks cost 8 + 2 = 10.  The write
// enable is steered to the bank of the write address and the registered bank
// select picks the read data, so the read latency is still one cycle.
//
// The DW stage instantiates two of these as a ping-pong line store.
module st_line_ram #(
    parameter int WORDS = 2560,             // 40-bit group words per line
    parameter int AW    = $clog2(WORDS)     // derived; do not override
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [39:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [39:0]   rdata
);
    localparam int BW = 2048;               // words 0 .. 2047, the big bank
    localparam int TW = WORDS - BW;         // 512 words, the top bank
    localparam int BAW = $clog2(BW);        // 11
    localparam int TAW = $clog2(TW);        // 9

    logic [39:0] big [BW];                   // words 0 .. BW-1
    logic [39:0] top [TW];                   // words BW .. WORDS-1
    logic [39:0] q_big, q_top;
    logic        rsel;                      // bank of the read address

    wire wsel = waddr[AW-1];                // WORDS <= 2 * BW, so one bit

    always_ff @(posedge clk) begin
        if (we && !wsel)
            big[waddr[BAW-1:0]] <= wdata;
        if (we && wsel)
            top[waddr[TAW-1:0]] <= wdata;
        rsel  <= raddr[AW-1];
        q_big <= big[raddr[BAW-1:0]];
        q_top <= top[raddr[TAW-1:0]];
    end

    assign rdata = rsel ? q_top : q_big;

    initial begin
        if (WORDS != BW + TW || WORDS > 2 * BW)
            $error("st_line_ram: WORDS must split into a 2048 and a 512 bank");
    end
endmodule
