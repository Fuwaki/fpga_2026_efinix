// E5c reproducer: the same byte-lane RAM, but one level down in the hierarchy.
// Purpose: conv_stream as root crashes with SIGSEGV while layer_seq/engine_top
// abort with 'ram net has invalid dimension'. If this file shows the assert
// instead of the SIGSEGV, both symptoms have the same root cause.
module child (input var logic clk, input var logic we, input var logic [10:0] a,
             input var logic [7:0] d, output var logic [31:0] q);
    logic [255:0] mem [1152];
    logic [255:0] r;
    always_ff @(posedge clk) begin
        if (we) mem[a][8*(a[7:0])+:8] <= d;
        r <= mem[a];
    end
    assign q = r[31:0];
endmodule

module TOP (input var logic clk, input var logic we, input var logic [31:0] a,
            input var logic [31:0] d, output var logic [31:0] q);
    child u_child (.clk, .we, .a(a[10:0]), .d(d[7:0]), .q);
endmodule
