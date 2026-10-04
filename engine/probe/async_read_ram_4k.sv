// E5c follow-up probe: asynchronous read, depth 4096 (12-bit address).
module TOP (input var logic clk, input var logic we, input var logic [11:0] wa,
            input var logic [7:0] d, input var logic [11:0] ra, output var logic [7:0] q);
    logic [7:0] mem [4096];
    always_ff @(posedge clk) if (we) mem[wa] <= d;
    always_comb q = mem[ra];
endmodule
