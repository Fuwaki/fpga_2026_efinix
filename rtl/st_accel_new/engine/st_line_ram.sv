// st_line_ram.sv -- one line of the ST DW stage's 3x3 window buffer.
//
// One write port and one read port on the same clock, registered read data;
// the canonical simple-dual-port block-RAM form, one RAM10 chain per instance.
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
    logic [39:0] mem [WORDS];

    always_ff @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
