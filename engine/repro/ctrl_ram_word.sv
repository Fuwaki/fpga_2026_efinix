// E5c reproducer: 256-bit RAM, whole-word write (the shape of conv_stream's weight buffer WITHOUT the byte lane)
// Minimal standalone module used to isolate the efx_map 2026.1.132 Titanium bug.
module TOP (input var logic clk, input var logic we, input var logic [10:0] a, input var logic [255:0] d, output var logic [31:0] q);
    logic [255:0] mem [1152];
    logic [255:0] r;
    always_ff @(posedge clk) begin
        if (we) mem[a] <= d;
        r <= mem[a];
    end
    assign q = r[31:0];
endmodule
