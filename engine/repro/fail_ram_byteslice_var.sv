// E5c reproducer: 256-bit RAM written one byte at a time with a VARIABLE byte lane (this is conv_stream.sv:358)
// Minimal standalone module used to isolate the efx_map 2026.1.132 Titanium bug.
module TOP (input var logic clk, input var logic we, input var logic [31:0] a, input var logic [31:0] d, output var logic [31:0] q);
    logic [255:0] mem [1152];
    logic [255:0] r;
    always_ff @(posedge clk) begin
        if (we) mem[a[10:0]][8*(a[7:0])+:8] <= d[7:0];
        r <= mem[a[10:0]];
    end
    assign q = r[31:0];
endmodule
