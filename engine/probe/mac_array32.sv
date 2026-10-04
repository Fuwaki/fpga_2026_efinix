// E5c follow-up probe: 32 independent int8 lanes + one 32-input adder tree, registered.
// This is the resource question that decides the whole DSP budget: does a P=32
// int8 MAC array become 32 hard DSPs on Ti60F225, or soft multipliers/logic?
module TOP (input var logic clk, input var logic [255:0] x,
            input var logic [255:0] w, output var logic signed [31:0] y);
    logic signed [31:0] p [32];
    logic signed [31:0] acc;
    int unsigned i;
    always_comb begin
        for (i = 0; i < 32; i = i + 1)
            p[i] = $signed(x[8*i+:8]) * $signed(w[8*i+:8]);
    end
    always_ff @(posedge clk) acc <= p[0] + p[1] + p[2] + p[3] + p[4] + p[5] + p[6] + p[7] + p[8] + p[9] + p[10] + p[11] + p[12] + p[13] + p[14] + p[15] + p[16] + p[17] + p[18] + p[19] + p[20] + p[21] + p[22] + p[23] + p[24] + p[25] + p[26] + p[27] + p[28] + p[29] + p[30] + p[31];
    assign y = acc;
endmodule
