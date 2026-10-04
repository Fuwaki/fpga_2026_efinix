// E5c follow-up probe: asynchronous (combinational) read + synchronous write RAM -
// the shape of conv_engine.sv:133 `always_comb x_tap = xram[x_tap_addr];`.
module TOP (input var logic clk, input var logic we, input var logic [8:0] wa,
            input var logic [7:0] d, input var logic [8:0] ra, output var logic [7:0] q);
    logic [7:0] mem [288];
    always_ff @(posedge clk) if (we) mem[wa] <= d;
    always_comb q = mem[ra];
endmodule
