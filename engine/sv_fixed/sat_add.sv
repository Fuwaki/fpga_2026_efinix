module sat_add (
    input  var logic signed [8-1:0] a_i,
    input  var logic signed [8-1:0] b_i,
    output var logic signed [8-1:0] y_o
);
    logic signed [9-1:0] sum; always_comb sum = a_i + b_i;

    always_comb begin
        if (sum > 9'sd127) begin
            y_o = 8'sd127;
        end else if (sum < -9'sd127) begin
            y_o = -8'sd127;
        end else begin
            y_o = sum[7:0];
        end
    end
endmodule
