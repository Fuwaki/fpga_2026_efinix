module requant_unit #(
    parameter int unsigned ACC_W   = 32,
    parameter int unsigned M0_W    = 18,
    parameter int unsigned SHIFT_W = 6 
) (
    input  var logic                      clk    ,
    input  var logic signed [ACC_W-1:0]   acc_i  ,
    input  var logic signed [M0_W-1:0]    m0_i   ,
    input  var logic        [SHIFT_W-1:0] shift_i,
    input  var logic                      relu_i ,
    output var logic signed [8-1:0]       y_o
);
    localparam int unsigned PROD_W = ACC_W + M0_W;
    localparam int unsigned MAG_W  = PROD_W + 1;

    logic signed [PROD_W-1:0]  prod_r ;
    logic        [SHIFT_W-1:0] shift_r;
    logic                      relu_r ;

    always_ff @ (posedge clk) begin
        prod_r  <= acc_i * m0_i;
        shift_r <= shift_i;
        relu_r  <= relu_i;
    end

    logic [MAG_W-1:0]  one    ; always_comb one     = 1;
    logic [PROD_W-1:0] mag    ; always_comb mag     = ((prod_r[PROD_W - 1]) ? ( ~prod_r + 1 ) : ( prod_r ));
    logic [MAG_W-1:0]  mag_ext; always_comb mag_ext = {1'b0, mag};
    logic [MAG_W-1:0]  half   ; always_comb half    = ((shift_r == 0) ? ( 0 ) : ( one << (shift_r - 1) ));
    logic [MAG_W-1:0]  mag_rnd; always_comb mag_rnd = mag_ext + half;
    logic [MAG_W-1:0]  mag_sh ; always_comb mag_sh  = mag_rnd >> shift_r;
    logic              neg    ; always_comb neg     = prod_r[PROD_W - 1];

    always_ff @ (posedge clk) begin
        if (relu_r && neg) begin
            y_o <= 8'sd0;
        end else if (mag_sh >= 127) begin
            y_o <= ((neg) ? ( -8'sd127 ) : ( 8'sd127 ));
        end else begin
            y_o <= ((neg) ? ( -(byte'(mag_sh[7:0])) ) : ( (byte'(mag_sh[7:0])) ));
        end
    end
endmodule
