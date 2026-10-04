// E5c control: an 8x8 signed multiply with a registered result.
// Purpose: prove the tool DOES infer hard multiplier blocks on both families,
// so "no number for conv_stream" is not a generic tool failure.
module TOP (input var logic clk, input var logic signed [7:0] a, input var logic signed [7:0] b, output var logic signed [31:0] y);
    logic signed [31:0] acc;
    always_ff @(posedge clk) acc <= a * b;
    assign y = acc;
endmodule
