// E5c follow-up probe: the MAC-lane shape of the engine (signed int8 x signed int8,
// 32-bit accumulate, registered) - does efx_map put it in a DSP on Ti60F225?
module TOP (input var logic clk, input var logic signed [7:0] a,
            input var logic signed [7:0] b, output var logic signed [31:0] y);
    logic signed [31:0] acc;
    always_ff @(posedge clk) acc <= acc + a * b;
    assign y = acc;
endmodule
