//=============================================================================
// conv_engine.veryl -- Veryl port of rtl/conv_engine.v
//=============================================================================
module conv_engine #(
    parameter int unsigned IN_C    = 3 ,
    parameter int unsigned OUT_C   = 32,
    parameter int unsigned K       = 3 ,
    parameter int unsigned STRIDE  = 1 ,
    parameter int unsigned MAX_H   = 64,
    parameter int unsigned MAX_W   = 64,
    parameter int unsigned ACC_W   = 32,
    parameter int unsigned M0_W    = 18,
    parameter int unsigned SHIFT_W = 6 ,
    // OCW is derived from OUT_C; it stays a parameter (not a const) so that a
    // -GOUT_C override re-evaluates it, exactly like the localparam in the SV.
    parameter int unsigned OCW = ((OUT_C < 2) ? ( 1 ) : ( $clog2(OUT_C) ))
) (
    input var logic clk  ,
    input var logic rst_n,

    input  var logic [16-1:0]      img_h        ,
    input  var logic [16-1:0]      img_w        ,
    input  var logic [SHIFT_W-1:0] requant_shift,
    input  var logic               relu_en      ,
    input  var logic               start        ,
    output var logic               busy         ,
    output var logic               done         ,

    input var logic          w_we  ,
    input var logic [32-1:0] w_addr,
    input var logic [8-1:0]  w_data,

    input var logic                    b_we  ,
    input var logic        [OCW-1:0]   b_addr,
    input var logic signed [ACC_W-1:0] b_data,

    input var logic                   m_we  ,
    input var logic        [OCW-1:0]  m_addr,
    input var logic signed [M0_W-1:0] m_data,

    input var logic          x_we  ,
    input var logic [32-1:0] x_addr,
    input var logic [8-1:0]  x_data,

    input  var logic [32-1:0] y_addr,
    output var logic [8-1:0]  y_data
);
    // ---- geometry / sizes --------------------------------------------------
    localparam int unsigned           PAD     = K / 2;
    localparam int unsigned           W_DEPTH = OUT_C * IN_C * K * K;
    localparam int unsigned           X_DEPTH = IN_C * MAX_H * MAX_W;
    localparam int unsigned           Y_DEPTH = OUT_C * MAX_H * MAX_W;
    localparam int unsigned           TAPS    = IN_C * K * K;
    localparam logic        [OCW-1:0] OC_LAST = OUT_C - 1;
    // (2*PAD - K) as a 32-bit two's complement constant: 0 for even K, -1 for
    // odd K.  The SV computes it as a signed integer and lets the unsigned
    // 32-bit addition with {16'b0, img_h} wrap, which is the same thing.
    localparam int unsigned ADJ = ((K % 2 == 0) ? ( 0 ) : ( 32'hFFFF_FFFF ));

    // ---- FSM states --------------------------------------------------------
    localparam logic [3-1:0] S_IDLE = 0;
    localparam logic [3-1:0] S_TAP  = 1;
    localparam logic [3-1:0] S_RQ   = 2;
    localparam logic [3-1:0] S_WR   = 3;
    localparam logic [3-1:0] S_DONE = 4;

    // ---- storage -----------------------------------------------------------
    logic        [8-1:0]     wram [W_DEPTH];
    logic signed [ACC_W-1:0] bram [OUT_C]  ;
    logic signed [M0_W-1:0]  mram [OUT_C]  ;
    logic        [8-1:0]     xram [X_DEPTH];
    logic        [8-1:0]     yram [Y_DEPTH];

    always_comb y_data = yram[y_addr];

    // ---- control state -----------------------------------------------------
    logic [3-1:0]   state  ;
    logic [16-1:0]  h_out  ;
    logic [16-1:0]  w_out  ;
    logic [16-1:0]  oy     ;
    logic [16-1:0]  ox     ;
    logic [32-1:0]  tap    ;
    logic [OCW-1:0] oc     ;
    logic [3-1:0]   rq_wait;

    // Geometry at 32 bits, then explicitly truncated to 16 (SV comment).
    logic [32-1:0] h_out_c;
    logic [32-1:0] w_out_c;
    always_comb begin
        h_out_c = (32'(img_h)) + ADJ;
        h_out_c = h_out_c / STRIDE + 1;
        w_out_c = (32'(img_w)) + ADJ;
        w_out_c = w_out_c / STRIDE + 1;
    end

    // tap t -> (ic, ky, kx): kk = t/IN_C, ic = t%IN_C, ky = kk/K, kx = kk%K
    logic [32-1:0] t_kk; always_comb t_kk = tap / IN_C;
    logic [32-1:0] t_ic; always_comb t_ic = tap % IN_C;
    logic [32-1:0] t_ky; always_comb t_ky = t_kk / K;
    logic [32-1:0] t_kx; always_comb t_kx = t_kk % K;

    // reflect border index (edge pixel not duplicated), same as the SV
    // while-loop form on the whole domain the engine can generate.
    function automatic int reflect(
        input var int v,
        input var int n
    ) ;
        int a     ;
        int period;
        a      = v;
        if (a < 0) begin
            a = -a;
        end
        period = 2 * n - 2;
        // Bounded closed form of the SV loop while (r >= n) r = 2*n-2-r.
        // n >= 2 and 0 <= |v| <= n hold for every index this engine generates,
        // where the SV loop runs at most once and both forms agree exactly.
        if (period > 0) begin
            a = a % period;
            if (a > n - 1) begin
                a = period - a;
            end
        end
        return a;
    endfunction

    int yy ; always_comb yy  = (int'(oy)) * (int'(STRIDE)) - (int'(PAD)) + (int'(t_ky));
    int xx ; always_comb xx  = (int'(ox)) * (int'(STRIDE)) - (int'(PAD)) + (int'(t_kx));
    int yyi; always_comb yyi = reflect(yy, int'(img_h));
    int xxi; always_comb xxi = reflect(xx, int'(img_w));

    logic        [32-1:0] x_tap_addr; always_comb x_tap_addr = ((32'(yyi)) * (32'(img_w)) + (32'(xxi))) * IN_C + t_ic;
    logic signed [8-1:0]  x_tap     ; always_comb x_tap      = xram[x_tap_addr];

    logic        [32-1:0] w_tap_base        ; always_comb w_tap_base         = ((t_ic * K + t_ky) * K + t_kx) * OUT_C;
    logic signed [8-1:0]  w_tap      [OUT_C];

    always_comb begin
        for (int l = 0; l < OUT_C; l++) begin
            w_tap[l] = wram[w_tap_base + l];
        end
    end

    // Explicit 32-bit arithmetic: a bare 16-bit expression would wrap for the
    // wide layers.
    logic [32-1:0] y_wr_addr; always_comb y_wr_addr = ((32'(oc)) * (32'(h_out)) + (32'(oy))) * (32'(w_out)) + (32'(ox));

    // ---- per-output-channel lanes -----------------------------------------
    logic signed [ACC_W-1:0] acc    [OUT_C];
    logic        [8-1:0]     y_lane [OUT_C];

    for (genvar l = 0; l < OUT_C; l++) begin :gen_lanes
        requant_unit #(
            .ACC_W   (ACC_W  ),
            .M0_W    (M0_W   ),
            .SHIFT_W (SHIFT_W)
        ) u_requant (
            .clk     (clk             ),
            .acc_i   (acc[l] + bram[l]),
            .m0_i    (mram[l]         ),
            .shift_i (requant_shift   ),
            .relu_i  (relu_en         ),
            .y_o     (y_lane[l]       )
        );
    end

    // The SV leaves the memories un-reset on purpose: they are filled through
    // the load ports after reset.  Every *register* below is reset exactly like
    // the SV does.

    always_ff @ (posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            busy    <= 0;
            done    <= 0;
            oy      <= 0;
            ox      <= 0;
            tap     <= 0;
            oc      <= 0;
            rq_wait <= 0;
            h_out   <= 0;
            w_out   <= 0;
            for (int i = 0; i < OUT_C; i++) begin
                acc[i] <= 0;
            end
        end else begin
            // ---- parameter / map load ports (independent of the FSM) --------
            if (w_we) begin
                wram[w_addr] <= w_data;
            end
            if (b_we) begin
                bram[32'(b_addr)] <= b_data;
            end
            if (m_we) begin
                mram[32'(m_addr)] <= m_data;
            end
            if (x_we) begin
                xram[x_addr] <= x_data;
            end

            case (state) inside
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        h_out   <= h_out_c[15:0];
                        w_out   <= w_out_c[15:0];
                        oy      <= 0;
                        ox      <= 0;
                        tap     <= 0;
                        oc      <= 0;
                        rq_wait <= 0;
                        for (int i = 0; i < OUT_C; i++) begin
                            acc[i] <= 0;
                        end
                        busy  <= 1;
                        state <= S_TAP;
                    end
                end
                S_TAP: begin
                    // one tap per clock: K*K*IN_C clocks, all output channels at once
                    for (int i = 0; i < OUT_C; i++) begin
                        acc[i] <= acc[i] + x_tap * w_tap[i];
                    end
                    if (tap == TAPS - 1) begin
                        tap     <= 0;
                        rq_wait <= 0;
                        state   <= S_RQ;
                    end else begin
                        tap <= tap + 1;
                    end
                end
                S_RQ: begin
                    // let the 2-stage requant pipeline settle on the frozen acc
                    if (rq_wait == 3) begin
                        oc    <= 0;
                        state <= S_WR;
                    end else begin
                        rq_wait <= rq_wait + 1;
                    end
                end
                S_WR: begin
                    yram[y_wr_addr] <= y_lane[32'(oc)];
                    if (oc == OC_LAST) begin
                        oc <= 0;
                        if (ox == w_out - 1) begin
                            ox <= 0;
                            if (oy == h_out - 1) begin
                                oy    <= 0;
                                busy  <= 0;
                                done  <= 1;
                                state <= S_DONE;
                            end else begin
                                oy <= oy + 1;
                                for (int i = 0; i < OUT_C; i++) begin
                                    acc[i] <= 0;
                                end
                                state <= S_TAP;
                            end
                        end else begin
                            ox <= ox + 1;
                            for (int i = 0; i < OUT_C; i++) begin
                                acc[i] <= 0;
                            end
                            state <= S_TAP;
                        end
                    end else begin
                        oc <= oc + 1;
                    end
                end
                S_DONE: begin
                    if (start) begin
                        h_out   <= h_out_c[15:0];
                        w_out   <= w_out_c[15:0];
                        oy      <= 0;
                        ox      <= 0;
                        tap     <= 0;
                        oc      <= 0;
                        rq_wait <= 0;
                        for (int i = 0; i < OUT_C; i++) begin
                            acc[i] <= 0;
                        end
                        busy  <= 1;
                        done  <= 0;
                        state <= S_TAP;
                    end
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
