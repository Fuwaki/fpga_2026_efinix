// st_add.sv -- residual / skip add of the ST block engine.
//
// Two group streams of the same shape: the trunk t and the aux a.  Per lane
//
//   y = t + clamp(f32_mul_round(a, mant, k), -127, 127)
//
// with no clamp after the add (|y| <= 254 fits the 10-bit lane), exactly
// st_golden.Net.add_requant + trunk.  The factor (mant, k) is the add's
// requant word, static during a pass.  Flags (last, eol, sof) come from the
// trunk; simulation checks that the aux flags agree.
//
// Four st_requant lanes (XW = 10, two DSP blocks each) scale the aux lanes;
// the trunk beat and its flags ride through lane 0's tag, so both arrive
// together.  The lanes never stall: a pair enters only when the output FIFO
// has room for everything in flight (credit), II = 1.
module st_add (
    input  logic          clk,
    input  logic          rst_n,

    input  logic [23:0]   cfg_mant,    // add factor, r = mant * 2**(-k)
    input  logic [5:0]    cfg_k,

    input  logic          t_valid,
    output logic          t_ready,
    input  logic [39:0]   t_data,
    input  logic          t_last,
    input  logic          t_eol,
    input  logic          t_sof,

    input  logic          a_valid,
    output logic          a_ready,
    input  logic [39:0]   a_data,
    input  logic          a_last,
    input  logic          a_eol,
    input  logic          a_sof,

    output logic          out_valid,
    input  logic          out_ready,
    output logic [39:0]   out_data,
    output logic          out_last,
    output logic          out_eol,
    output logic          out_sof
);
    localparam int DEPTH = 16;          // output FIFO, > requant LAT + 1
    localparam int TW    = 43;          // trunk data + last, eol, sof

    // ------------------------------------------------------------- credit
    logic [4:0]  inflight;              // pairs in the requant lanes
    logic [4:0]  level;
    logic        f_wen, f_rvalid;
    wire  [5:0]  used   = 6'(level) + 6'(f_rvalid) + 6'(inflight);
    wire         credit = used < 6'(DEPTH);
    wire         go     = t_valid && a_valid && credit;

    assign t_ready = go;
    assign a_ready = go;

    // -------------------------------------------------------- requant lanes
    logic [3:0]          rv;
    logic signed [9:0]   ry [4];
    logic [TW-1:0]       tag;
    logic                unused_tag [3];

    for (genvar j = 0; j < 4; j++) begin : g_lane
        if (j == 0) begin : g_tag
            st_requant #(.XW(10), .TW(TW)) u_rq (
                .clk(clk), .rst_n(rst_n), .in_valid(go),
                .in_x(a_data[10*j +: 10]), .in_mant(cfg_mant), .in_k(cfg_k),
                .in_lo(-10'sd127), .in_hi(10'sd127),
                .in_tag({t_sof, t_eol, t_last, t_data}),
                .out_valid(rv[j]), .out_y(ry[j]), .out_tag(tag));
        end else begin : g_plain
            logic [0:0] t1;
            st_requant #(.XW(10), .TW(1)) u_rq (
                .clk(clk), .rst_n(rst_n), .in_valid(go),
                .in_x(a_data[10*j +: 10]), .in_mant(cfg_mant), .in_k(cfg_k),
                .in_lo(-10'sd127), .in_hi(10'sd127), .in_tag(1'b0),
                .out_valid(rv[j]), .out_y(ry[j]), .out_tag(t1));
            assign unused_tag[j-1] = t1[0] | rv[j];
        end
    end

    logic [39:0] sum;
    always_comb
        for (int j = 0; j < 4; j++)
            sum[10*j +: 10] = tag[10*j +: 10] + ry[j];

    assign f_wen = rv[0];

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) inflight <= '0;
        else        inflight <= inflight + 5'(go) - 5'(f_wen);

    // --------------------------------------------------------- output FIFO
    logic f_full;
    fifo_srl_core #(.W(TW), .DEPTH(DEPTH)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wen(f_wen), .wdata({tag[42:40], sum}), .wfull(f_full),
        .rready(out_ready), .rvalid(f_rvalid),
        .rdata({out_sof, out_eol, out_last, out_data}), .level(level));
    assign out_valid = f_rvalid;

`ifndef SYNTHESIS
    always @(posedge clk)
        if (rst_n && go && {a_sof, a_eol, a_last} != {t_sof, t_eol, t_last})
            $error("st_add: aux flags %b differ from trunk flags %b",
                   {a_sof, a_eol, a_last}, {t_sof, t_eol, t_last});
    always @(posedge clk)
        if (rst_n && f_wen && f_full)
            $error("st_add: output FIFO overflow (credit broken)");
`endif

    logic unused;
    assign unused = f_full | unused_tag[0] | unused_tag[1] | unused_tag[2];
endmodule
