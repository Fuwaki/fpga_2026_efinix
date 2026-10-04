// E5c reproducer: 64 x 8 bit RAM, 1 write / 1 read (control)
// Minimal standalone module used to isolate the efx_map 2026.1.132 Titanium bug.
module TOP (input var logic clk, input var logic we, input var logic [31:0] a, input var logic [31:0] d, output var logic [31:0] q);
    logic [7:0] mem [64];
    logic [7:0] r;
    always_ff @(posedge clk) begin
        if (we) mem[a[5:0]] <= d[7:0];
        r <= mem[a[5:0]];
    end
    assign q = {24'b0, r};
endmodule
