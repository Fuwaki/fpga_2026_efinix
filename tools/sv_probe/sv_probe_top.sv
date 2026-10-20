// sv_probe_top.sv -- Efinity capability probe for the vid subsystem.
//
// Synthesised on its own by tools/sv_probe/run.sh.  It uses the real library
// modules and every SV construct the subsystem depends on, so a construct
// Efinity mishandles fails here in a minute instead of deep inside a full
// build:
//   * package types and constants (vid_pkg), packed-struct ports
//   * type-parameterised interfaces whose element is a packed struct, PPC > 1
//   * an array of interface instances, indexed by constants in a generate loop
//   * interface ports with modports, $bits() of an interface member
//   * block-RAM inference through the type-agnostic FIFO cores
//   * mul_nodsp: a variable multiply that must stay off the DSP blocks

/* verilator lint_off UNUSEDSIGNAL */   // probe only: deliberately partial use
module probe_gain (
    vstream_if.snk             s,
    vstream_if.src             m,
    input  vid_pkg::isp_cfg_t  cfg
);
    import vid_pkg::*;
    localparam int PPC = $bits(s.data) / $bits(rgb565_t);

    rgb565_t [PPC-1:0] scaled;

    for (genvar i = 0; i < PPC; i++) begin : g_px
        rgb565_t     p;
        logic [15:0] g;
        assign p = s.data[i];
        mul_nodsp #(.AW(6), .BW(10)) u_mul (.a(p.g), .b(cfg.wb_g), .p(g));
        assign scaled[i] = '{r: p.r, g: (g[15:14] != 0) ? 6'h3F : g[13:8], b: p.b};
    end

    assign m.valid = s.valid;
    assign m.sof   = s.sof;
    assign m.eol   = s.eol;
    assign m.data  = scaled;
    assign s.ready = m.ready;
endmodule
/* verilator lint_on UNUSEDSIGNAL */


module sv_probe_top
    import vid_pkg::*;
(
    input  logic          clk_a,
    input  logic          clk_b,
    input  logic          rst_n,

    input  logic          in_valid,
    output logic          in_ready,
    input  logic          in_sof,
    input  logic          in_eol,
    input  logic [127:0]  in_data,

    output logic          out_valid,
    input  logic          out_ready,
    output logic          out_sof,
    output logic          out_eol,
    output logic [127:0]  out_data,

    input  logic [9:0]    wb_g,
    output logic [9:0]    a_level,
    output logic [9:0]    b_level
);
    vstream_if #(.T(rgb565_t), .PPC(BEAT_PIX)) a (.clk(clk_a), .rst_n(rst_n));
    vstream_if #(.T(rgb565_t), .PPC(BEAT_PIX)) b [3] (.clk(clk_b), .rst_n(rst_n));

    isp_cfg_t cfg;
    always_comb begin
        cfg      = ISP_CFG_DEFAULT;
        cfg.wb_g = wb_g;
    end

    assign a.valid  = in_valid;
    assign a.sof    = in_sof;
    assign a.eol    = in_eol;
    assign a.data   = in_data;
    assign in_ready = a.ready;

    logic [9:0] unused_m_level;
    vstream_async_fifo #(.DEPTH(512)) u_cdc (
        .s(a), .m(b[0]), .s_level(a_level), .m_level(unused_m_level));

    for (genvar i = 0; i < 2; i++) begin : g_stage
        if (i == 0) begin : g_gain
            probe_gain u_gain (.s(b[i]), .m(b[i + 1]), .cfg(cfg));
        end else begin : g_fifo
            vstream_fifo #(.DEPTH(512)) u_fifo (.s(b[i]), .m(b[i + 1]), .level(b_level));
        end
    end

    assign out_valid  = b[2].valid;
    assign out_sof    = b[2].sof;
    assign out_eol    = b[2].eol;
    assign out_data   = b[2].data;
    assign b[2].ready = out_ready;
endmodule
