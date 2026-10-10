// st_layer_desc.v -- packed tiny-ST layer descriptors (W8A8 vangogh/ink arch)
// idx 0..15 -> {unsigned[0], relu[1], pad[2], stride[4:3], k[5], oc[13:6], ic[21:14]}
module st_layer_desc (
    input  wire [3:0]  idx,
    output reg  [7:0]  ic,
    output reg  [7:0]  oc,
    output reg  [1:0]  k,       // 1 or 3
    output reg  [1:0]  stride,  // 1 or 2
    output reg         pad,     // zero-pad amount (0 or 1)
    output reg         relu,
    output reg         out_unsigned
);
    always @(*) begin
        ic=8'd1; oc=8'd1; k=2'd3; stride=2'd1; pad=1'b1; relu=1'b1; out_unsigned=1'b0;
        case (idx)
            4'd0:  begin ic=8'd3;  oc=8'd32; k=2'd3; stride=2'd1; pad=1; relu=1; out_unsigned=0; end // enc.0
            4'd1:  begin ic=8'd32; oc=8'd64; k=2'd3; stride=2'd2; pad=1; relu=1; out_unsigned=0; end // enc.1
            4'd2:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd2; pad=1; relu=1; out_unsigned=0; end // enc.2
            4'd3:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=1; out_unsigned=0; end // res.0.c1
            4'd4:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=0; out_unsigned=0; end // res.0.c2
            4'd5:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=1; out_unsigned=0; end // res.1.c1
            4'd6:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=0; out_unsigned=0; end // res.1.c2
            4'd7:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=1; out_unsigned=0; end // res.2.c1
            4'd8:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=0; out_unsigned=0; end // res.2.c2
            4'd9:  begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=1; out_unsigned=0; end // res.3.c1
            4'd10: begin ic=8'd64; oc=8'd64; k=2'd3; stride=2'd1; pad=1; relu=0; out_unsigned=0; end // res.3.c2
            4'd11: begin ic=8'd64; oc=8'd32; k=2'd3; stride=2'd1; pad=1; relu=1; out_unsigned=0; end // up3.0
            4'd12: begin ic=8'd32; oc=8'd32; k=2'd1; stride=2'd1; pad=0; relu=1; out_unsigned=0; end // up1.0
            4'd13: begin ic=8'd32; oc=8'd16; k=2'd3; stride=2'd1; pad=1; relu=1; out_unsigned=0; end // up3.1
            4'd14: begin ic=8'd16; oc=8'd16; k=2'd1; stride=2'd1; pad=0; relu=1; out_unsigned=0; end // up1.1
            4'd15: begin ic=8'd16; oc=8'd3;  k=2'd3; stride=2'd1; pad=1; relu=0; out_unsigned=1; end // head
            default: ;
        endcase
    end
endmodule
