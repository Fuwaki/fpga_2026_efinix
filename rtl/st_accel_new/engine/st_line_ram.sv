// st_line_ram.sv -- one line of the ST DW stage's 3x3 window buffer.
//
// One write port and one read port on the same clock, registered read data;
// the canonical simple-dual-port block-RAM form.  The 3200-word depth is
// split into a 2048-, a 1024- and a 128-word bank because Efinity rounds a
// non-power-of-two depth up before it splits the array: one 3200 x 40 array
// would cost the 4096 x 40 shape, 16 RAM10, while the three banks cost
// 8 + 4 + 1 = 13.  The write enable is steered to the bank of the write
// address and the registered bank select picks the read data, so the read
// latency is still one cycle.
//
// 3200 group words hold W*G up to 3200: 80 channels at W = 160, 3 or 4
// channels at W = 640, 16 or 24 channels at W = 320.  The DW stage
// instantiates two of these as a ping-pong line store.
module st_line_ram #(
    parameter int WORDS = 3200,             // 40-bit group words per line
    parameter int AW    = $clog2(WORDS)     // derived; do not override
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [39:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [39:0]   rdata
);
    localparam int BW  = 2048;              // words 0 .. 2047, the big bank
    localparam int MW  = 1024;              // words 2048 .. 3071
    localparam int TW  = WORDS - BW - MW;   // 128 words, 3072 .. WORDS-1
    localparam int BAW = $clog2(BW);        // 11
    localparam int MAW = $clog2(MW);        // 10
    localparam int TAW = $clog2(TW);        // 7

    logic [39:0] big [BW];                  // words 0 .. BW-1
    logic [39:0] mid [MW];                  // words BW .. BW+MW-1
    logic [39:0] top [TW];                  // words BW+MW .. WORDS-1
    logic [39:0] q_big, q_mid, q_top;
    logic [1:0]  rsel;                      // bank of the read address

    // only the selected bank's own address bits index it, so a read of any
    // address stays inside its array
    wire [1:0] wsel = (waddr >= AW'(BW + MW)) ? 2'd2 :
                      (waddr >= AW'(BW))      ? 2'd1 : 2'd0;
    wire [1:0] rbank = (raddr >= AW'(BW + MW)) ? 2'd2 :
                       (raddr >= AW'(BW))      ? 2'd1 : 2'd0;

    always_ff @(posedge clk) begin
        if (we && wsel == 2'd0)
            big[waddr[BAW-1:0]] <= wdata;
        if (we && wsel == 2'd1)
            mid[waddr[MAW-1:0]] <= wdata;
        if (we && wsel == 2'd2)
            top[waddr[TAW-1:0]] <= wdata;
        rsel  <= rbank;
        q_big <= big[raddr[BAW-1:0]];
        q_mid <= mid[raddr[MAW-1:0]];
        q_top <= top[raddr[TAW-1:0]];
    end

    always_comb begin
        case (rsel)
            2'd0:    rdata = q_big;
            2'd1:    rdata = q_mid;
            default: rdata = q_top;
        endcase
    end

    initial begin
        if (WORDS != BW + MW + TW || TW != 128)
            $error("st_line_ram: WORDS must split into 2048 + 1024 + 128");
    end
endmodule
