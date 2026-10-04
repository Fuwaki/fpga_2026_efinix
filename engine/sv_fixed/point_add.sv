//=============================================================================
// point_add.veryl -- E5: residual point requant + saturating add
//-----------------------------------------------------------------------------
// tools/engine_ref.py res_add(branch, trunk, m0, shift, mode="fixed", sat=True):
//
//     scaled = round_shift(branch * m0, shift)   // round half away
//     scaled = clip(scaled, -127, +127)
//     point  = clip(scaled + trunk, -127, +127)  // sat_add
//
// i.e. two frozen steps: requant_unit (relu_i = 0 -> the clamp is exactly the
// reference's +/-127 clip) and sat_add.  m0 is a scalar for the whole tensor
// (the residual tables gen/engine/<style>/res.<r>_m0_18b.hex are one value,
// unlike the per-oc conv tables), so this unit needs no per-channel memory.
//
// Layout: branch and trunk are read as CHW byte planes (one byte per element,
// address = byte index), exactly how the feature map arena stores a layer
// output.  One byte costs 3 cycles because requant_unit itself is TWO stages
// (prod_r, then the registered y_o): cycle 0 presents the branch, cycle 1 is
// the product, cycle 2 completes the sat_add and registers the write pair
// (out_addr/out_data/out_we), so a write is a clean 1 cycle pulse carrying the
// address of the byte that produced it.
//
// The branch is fed to requant_unit #(ACC_W: 8): the reference multiplies the
// int64 branch value by m0 exactly, and an int8 * 18-bit product (|p| < 2^24)
// fits the 8+18 = 26 bit product/magnitude path of the frozen module with no
// truncation, so the two agree bit for bit.  Verified byte for byte against
// engine_ref.res_add for all four residual tables of both styles in
// test/tb_point_add.veryl.
//=============================================================================
module point_add #(
    parameter int unsigned AW = 24
) (
    input  var logic                 clk     ,
    input  var logic                 rst_n   ,
    input  var logic                 start   ,
    output var logic                 busy    ,
    output var logic                 done    ,
    input  var logic        [32-1:0] n_bytes ,
    input  var logic signed [18-1:0] m0_i    ,
    input  var logic        [6-1:0]  shift_i ,
    output var logic        [AW-1:0] br_addr ,
    input  var logic        [8-1:0]  br_data ,
    output var logic        [AW-1:0] tr_addr ,
    input  var logic        [8-1:0]  tr_data ,
    output var logic                 out_we  ,
    output var logic        [AW-1:0] out_addr,
    output var logic        [8-1:0]  out_data,
    output var logic        [32-1:0] cyc_o   ,
    output var logic                 err_o   
);
    logic        [3-1:0]  st_r   ;
    logic        [32-1:0] idx_r  ;
    logic        [32-1:0] cyc_r  ;
    logic        [AW-1:0] oaddr_r;
    logic signed [8-1:0]  odata_r;
    logic signed [8-1:0]  br8    ;
    logic signed [8-1:0]  tr8    ;
    logic signed [8-1:0]  sum8   ;
    logic signed [8-1:0]  rq_y   ;

    always_comb begin
        br_addr  = idx_r[AW - 1:0];
        tr_addr  = idx_r[AW - 1:0];
        out_addr = oaddr_r;
        br8      = br_data;
        tr8      = tr_data;
        out_data = odata_r;
    end

    requant_unit #(
        .ACC_W (8)
    ) rq (
        .clk     (clk    ),
        .acc_i   (br8    ),
        .m0_i    (m0_i   ),
        .shift_i (shift_i),
        .relu_i  (1'b0   ),
        .y_o     (rq_y   )
    );

    sat_add sa (
        .a_i (rq_y),
        .b_i (tr8 ),
        .y_o (sum8)
    );

    always_ff @ (posedge clk) begin
        if ((!rst_n)) begin
            st_r    <= 3'd0;
            idx_r   <= 0;
            cyc_r   <= 0;
            oaddr_r <= 0;
            odata_r <= 0;
            busy    <= 0;
            done    <= 0;
            out_we  <= 0;
            cyc_o   <= 0;
            err_o   <= 0;
        end else begin
            done   <= 0;
            out_we <= 0;
            if ((st_r == 3'd0)) begin
                if ((start)) begin
                    busy  <= 1;
                    idx_r <= 0;
                    cyc_r <= 0;
                    err_o <= 0;
                    if ((n_bytes == 0)) begin
                        st_r <= 3'd4;
                    end else begin
                        st_r <= 3'd1;
                    end
                end
            end else if ((st_r == 3'd1)) begin
                // cycle 0: requant_unit stage 1 sees br8 = branch[idx_r]
                cyc_r <= cyc_r + 1;
                st_r  <= 3'd2;
            end else if ((st_r == 3'd2)) begin
                // cycle 1: requant_unit stage 2 registers y_o
                cyc_r <= cyc_r + 1;
                st_r  <= 3'd3;
            end else if ((st_r == 3'd3)) begin
                // cycle 2: rq_y = requant(branch[idx_r]), trunk[idx_r] read
                // combinationally, the sat_add result is registered together
                // with its own address
                odata_r <= sum8;
                oaddr_r <= idx_r[AW - 1:0];
                out_we  <= 1;
                cyc_r   <= cyc_r + 1;
                if (((idx_r + 32'd1) >= n_bytes)) begin
                    st_r <= 3'd4;
                end else begin
                    idx_r <= idx_r + 1;
                    st_r  <= 3'd1;
                end
            end else begin
                busy <= 0;
                done <= 1;
                st_r <= 3'd0;
            end
            cyc_o <= cyc_r;
            if ((busy && start && (st_r != 3'd0))) begin
                err_o <= 1;
            end
        end
    end
endmodule

/// Cycles a point_add of n_bytes takes, start to done (3 per byte + 4).

