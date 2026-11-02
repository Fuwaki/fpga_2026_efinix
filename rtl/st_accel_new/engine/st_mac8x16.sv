// st_mac8x16.sv -- 8 output x 16 input int8 MAC array of the ST block engine.
//
// One weight word (1024 bits) holds the weight of output lane o and input
// lane i in byte o*16 + i, two's complement.  The array is plain signed
// multiplies with registered operands followed by a 16-input adder tree with
// one register level every two adder levels:
//
//   in regs -> products -> 8 sums -> 4 sums (reg) -> 2 sums -> 1 sum (reg, + acc)
//
// The accumulator of every output lane is cleared on in_first -- the first
// input tile of an output tile -- and added to otherwise, so consecutive
// input tiles of one output tile accumulate without back-pressure.  done is
// high in the cycle the accumulator of the last input tile (in_last) is
// valid, so a caller may issue the next tiles of the same output tile back to
// back and take acc_out when done says so.
//
// Fixed latency LAT = 4, II = 1: a beat accepted with in_valid leaves its
// accumulator -- and done, if it carried in_last -- exactly four cycles later.
// Kept separate from the scheduler so a DSP-primitive version can replace it.
module st_mac8x16 (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                in_valid,
    input  logic [15:0][7:0]    in_x,       // input lanes, byte i = x[i]
    input  logic [1023:0]       in_w,       // byte o*16 + i = W[o][i]
    input  logic                in_first,   // clear the accumulators
    input  logic                in_last,    // last input tile of the output tile

    output logic                done,       // accumulators valid after the last tile
    output logic signed [23:0]  acc_out [8]
);
    // Cycles from an accepted in_valid beat to its accumulator, II = 1.
    localparam int LAT = 4;

    // ---------------------------------------------------- stage 1: operands
    logic signed [7:0] x_s1 [16];
    logic signed [7:0] w_s1 [8][16];
    logic              first_s1, last_s1;
    logic              vld_s1;

    // Control bits are reset; the operand and data registers are not, so
    // synthesis can place them in the DSP blocks' input and output registers.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s1   <= 1'b0;
            first_s1 <= 1'b0;
            last_s1  <= 1'b0;
        end else begin
            vld_s1   <= in_valid;
            first_s1 <= in_first;
            last_s1  <= in_last;
        end
    end

    always_ff @(posedge clk) begin
        for (int i = 0; i < 16; i++)
            x_s1[i] <= $signed(in_x[i]);
        for (int o = 0; o < 8; o++)
            for (int i = 0; i < 16; i++)
                w_s1[o][i] <= $signed(in_w[8*(16*o + i) +: 8]);
    end

    // ---------------------------------------------------- stage 2: products
    logic signed [15:0] p_s2 [8][16];
    logic               first_s2, last_s2;
    logic               vld_s2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s2   <= 1'b0;
            first_s2 <= 1'b0;
            last_s2  <= 1'b0;
        end else begin
            vld_s2   <= vld_s1;
            first_s2 <= first_s1;
            last_s2  <= last_s1;
            if (vld_s1)
                for (int o = 0; o < 8; o++)
                    for (int i = 0; i < 16; i++)
                        p_s2[o][i] <= $signed(x_s1[i]) * $signed(w_s1[o][i]);
        end
    end

    // ------------------------------------- stage 3: adder levels 1 and 2
    // 16 products -> 8 sums -> 4 sums of four products each; |sum| <= 4*128*128.
    logic signed [17:0] q_s3 [8][4];
    logic               first_s3, last_s3;
    logic               vld_s3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s3   <= 1'b0;
            first_s3 <= 1'b0;
            last_s3  <= 1'b0;
        end else begin
            vld_s3   <= vld_s2;
            first_s3 <= first_s2;
            last_s3  <= last_s2;
            if (vld_s2)
                for (int o = 0; o < 8; o++)
                    for (int k = 0; k < 4; k++)
                        q_s3[o][k] <= 18'(p_s2[o][4*k])
                                    + 18'(p_s2[o][4*k + 1])
                                    + 18'(p_s2[o][4*k + 2])
                                    + 18'(p_s2[o][4*k + 3]);
        end
    end

    // ----------------------- stage 4: adder levels 3 and 4, accumulate
    logic signed [19:0] r_s4 [8];

    always_comb begin
        for (int o = 0; o < 8; o++)
            r_s4[o] = 20'(q_s3[o][0]) + 20'(q_s3[o][1])
                    + 20'(q_s3[o][2]) + 20'(q_s3[o][3]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            for (int o = 0; o < 8; o++) acc_out[o] <= 24'sd0;
        end else begin
            done <= vld_s3 && last_s3;
            if (vld_s3)
                for (int o = 0; o < 8; o++)
                    acc_out[o] <= first_s3 ? 24'(r_s4[o])
                                           : acc_out[o] + 24'(r_s4[o]);
        end
    end

    initial begin
        if (LAT != 4) $error("st_mac8x16: the scheduler assumes LAT = 4");
    end

endmodule
