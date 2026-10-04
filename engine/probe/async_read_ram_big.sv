// E5c follow-up probe: the same async read on a 1 Mbit byte RAM (conv_engine's yram).
module TOP (input var logic clk, input var logic we, input var logic [16:0] wa,
            input var logic [7:0] d, input var logic [16:0] ra, output var logic [7:0] q);
    logic [7:0] mem [131072];
    always_ff @(posedge clk) if (we) mem[wa] <= d;
    always_comb q = mem[ra];
endmodule
