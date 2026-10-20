// vid_subsystem.sv -- the new video subsystem behind flat ports.
//
// Interfaces are used inside only; the ports are plain AXI signals so the
// Verilog top level connects to it as to any other block, and so the AXI
// attributes the controller needs but the subsystem never varies (size,
// burst type, cache, prot, lock, strobes) are fixed in one place.
//
// Phase 1 contents:
//   axi_arb      master 0 = legacy frame store (highest priority), master 1
//                = self-test path
//   self-test    vid_testgen -> vdma_wr -> frame_ring (test) -> vdma_rd ->
//                vid_testchk, every word compared, results in status
module vid_subsystem
    import vid_pkg::*;
#(
    parameter bit ENABLE_SELFTEST = 1,
    // Self-test geometry and timing; simulation shortens them.
    parameter int TEST_LINES        = CAM_H,
    parameter int TEST_FRAME_CYCLES = 3_333_333,
    parameter int TEST_LINE_CYCLES  = 2_000
) (
    input  logic                  clk,          // AXI / core clock
    input  logic                  rst_n,

    // ---------------------------------------- legacy frame store (AXI slave)
    input  logic [AXI_IW-1:0]     lg_awid,
    input  logic [AXI_AW-1:0]     lg_awaddr,
    input  logic [7:0]            lg_awlen,
    input  logic                  lg_awvalid,
    output logic                  lg_awready,
    input  logic [AXI_DW-1:0]     lg_wdata,
    input  logic                  lg_wlast,
    input  logic                  lg_wvalid,
    output logic                  lg_wready,
    output logic [AXI_IW-1:0]     lg_bid,
    output logic [1:0]            lg_bresp,
    output logic                  lg_bvalid,
    input  logic                  lg_bready,
    input  logic [AXI_IW-1:0]     lg_arid,
    input  logic [AXI_AW-1:0]     lg_araddr,
    input  logic [7:0]            lg_arlen,
    input  logic                  lg_arvalid,
    output logic                  lg_arready,
    output logic [AXI_IW-1:0]     lg_rid,
    output logic [AXI_DW-1:0]     lg_rdata,
    output logic [1:0]            lg_rresp,
    output logic                  lg_rlast,
    output logic                  lg_rvalid,
    input  logic                  lg_rready,

    // ------------------------------------------------ DDR controller (master)
    output logic [AXI_IW-1:0]     ddr_awid,
    output logic [AXI_AW-1:0]     ddr_awaddr,
    output logic [7:0]            ddr_awlen,
    output logic [2:0]            ddr_awsize,
    output logic [1:0]            ddr_awburst,
    output logic                  ddr_awlock,
    output logic [3:0]            ddr_awcache,
    output logic [2:0]            ddr_awprot,
    output logic                  ddr_awvalid,
    input  logic                  ddr_awready,
    output logic [AXI_DW-1:0]     ddr_wdata,
    output logic [AXI_DW/8-1:0]   ddr_wstrb,
    output logic                  ddr_wlast,
    output logic                  ddr_wvalid,
    input  logic                  ddr_wready,
    input  logic [AXI_IW-1:0]     ddr_bid,
    input  logic [1:0]            ddr_bresp,
    input  logic                  ddr_bvalid,
    output logic                  ddr_bready,
    output logic [AXI_IW-1:0]     ddr_arid,
    output logic [AXI_AW-1:0]     ddr_araddr,
    output logic [7:0]            ddr_arlen,
    output logic [2:0]            ddr_arsize,
    output logic [1:0]            ddr_arburst,
    output logic                  ddr_arlock,
    output logic [3:0]            ddr_arcache,
    output logic [2:0]            ddr_arprot,
    output logic                  ddr_arvalid,
    input  logic                  ddr_arready,
    input  logic [AXI_IW-1:0]     ddr_rid,
    input  logic [AXI_DW-1:0]     ddr_rdata,
    input  logic [1:0]            ddr_rresp,
    input  logic                  ddr_rlast,
    input  logic                  ddr_rvalid,
    output logic                  ddr_rready,

    output vid_status_t           status
);
    localparam int NW = 2, NR = 2;

    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mw [NW] (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mr [NR] (.clk(clk), .rst_n(rst_n));
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));

    // ------------------------------------------------- legacy = master 0
    assign mw[0].awid    = lg_awid;
    assign mw[0].awaddr  = lg_awaddr;
    assign mw[0].awlen   = lg_awlen;
    assign mw[0].awvalid = lg_awvalid;
    assign lg_awready    = mw[0].awready;
    assign mw[0].wdata   = lg_wdata;
    assign mw[0].wlast   = lg_wlast;
    assign mw[0].wvalid  = lg_wvalid;
    assign lg_wready     = mw[0].wready;
    assign lg_bid        = mw[0].bid;
    assign lg_bresp      = mw[0].bresp;
    assign lg_bvalid     = mw[0].bvalid;
    assign mw[0].bready  = lg_bready;

    assign mr[0].arid    = lg_arid;
    assign mr[0].araddr  = lg_araddr;
    assign mr[0].arlen   = lg_arlen;
    assign mr[0].arvalid = lg_arvalid;
    assign lg_arready    = mr[0].arready;
    assign lg_rid        = mr[0].rid;
    assign lg_rdata      = mr[0].rdata;
    assign lg_rresp      = mr[0].rresp;
    assign lg_rlast      = mr[0].rlast;
    assign lg_rvalid     = mr[0].rvalid;
    assign mr[0].rready  = lg_rready;

    // ------------------------------------------------------- self-test
    if (ENABLE_SELFTEST) begin : g_selftest
        frame_geom_t geom;
        assign geom = '{w: 13'(CAM_W), h: 13'(TEST_LINES)};

        vstream_if #(.T(rgb565_t), .PPC(2)) gen (.clk(clk), .rst_n(rst_n));
        vstream_if #(.T(rgb565_t), .PPC(2)) back (.clk(clk), .rst_n(rst_n));
        ring_prod_if rp ();
        ring_cons_if rc [1] ();

        logic [15:0] gen_frame;
        vid_testgen #(.FRAME_CYCLES(TEST_FRAME_CYCLES), .LINE_CYCLES(TEST_LINE_CYCLES)) u_gen (
            .o(gen), .geom(geom), .enable(1'b1), .frame(gen_frame));

        frame_ring #(.SLOTS(3), .NCONS(1)) u_ring (
            .clk(clk), .rst_n(rst_n), .p(rp), .c(rc), .status(status.test_ring));

        vdma_wr #(.FIFO_WORDS(1024)) u_wr (
            .s(gen), .m(mw[1]), .ring(rp),
            .ring_base(RING_TEST_BASE), .geom(geom), .src_seq(gen_frame),
            .st_frames(status.tw_frames), .st_skipped(status.tw_skipped),
            .st_errors(status.tw_errors), .st_sig(status.tw_sig));

        logic         rd_busy, rd_start;
        frame_token_t rd_tok;
        logic [SEQ_W-1:0] rd_frames, rd_late;
        always_ff @(posedge clk or negedge rst_n)
            if (!rst_n) rd_start <= 1'b0;
            else        rd_start <= !rd_busy && !rd_start;

        vdma_rd #(.FIFO_WORDS(512), .RD_BURST(32)) u_rd (
            .m(mr[1]), .ring(rc[0]), .o(back),
            .ring_base(RING_TEST_BASE), .start(rd_start), .policy(ACQ_NEW_ONLY), .geom(geom),
            .x0_beat(8'd0), .nbeats(8'(CAM_W / BEAT_PIX)),
            .busy(rd_busy), .token(rd_tok),
            .st_frames(rd_frames), .st_miss(status.tr_miss), .st_late(rd_late));

        vid_testchk u_chk (
            .s(back), .geom(geom), .frame_id(rd_tok.src_seq),
            .st_frames(status.tc_frames), .st_bad_frames(status.tc_bad_frames),
            .st_bad_words(status.tc_bad_words), .st_first_bad(status.tc_first_bad),
            .st_last_bad(status.tc_last_bad), .st_last_pos(status.tc_last_pos));
    end else begin : g_no_selftest
        assign mw[1].awvalid = 1'b0;
        assign mw[1].awid    = '0;
        assign mw[1].awaddr  = '0;
        assign mw[1].awlen   = '0;
        assign mw[1].wvalid  = 1'b0;
        assign mw[1].wdata   = '0;
        assign mw[1].wlast   = 1'b0;
        assign mw[1].bready  = 1'b1;
        assign mr[1].arvalid = 1'b0;
        assign mr[1].arid    = '0;
        assign mr[1].araddr  = '0;
        assign mr[1].arlen   = '0;
        assign mr[1].rready  = 1'b1;
        assign status.test_ring     = '0;
        assign status.tw_frames     = '0;
        assign status.tw_errors     = '0;
        assign status.tw_skipped    = '0;
        assign status.tw_sig        = '0;
        assign status.tc_frames     = '0;
        assign status.tc_bad_frames = '0;
        assign status.tc_bad_words  = '0;
        assign status.tc_first_bad  = '0;
        assign status.tc_last_bad   = '0;
        assign status.tc_last_pos   = '0;
        assign status.tr_miss       = '0;
    end

    // ---------------------------------------- legacy burst-length monitor
    // The legacy writer's wlast logic is hand-rolled; check that each burst
    // carries exactly awlen + 1 beats, because the arbiter orders W by AW and
    // a mismatch would hand beats to the next master's burst.
    logic       lm_valid, lm_full;
    logic [7:0] lm_len;
    logic [3:0] lm_level;
    logic [8:0] lm_beats;
    wire        lm_w    = lg_wvalid && mw[0].wready;
    wire        lm_last = lm_w && lg_wlast;

    fifo_sync_core #(.W(8), .DEPTH(8)) u_lm (
        .clk(clk), .rst_n(rst_n),
        .wen(lg_awvalid && mw[0].awready), .wdata(lg_awlen), .wfull(lm_full),
        .rready(lm_last), .rvalid(lm_valid), .rdata(lm_len), .level(lm_level));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lm_beats             <= '0;
            status.lg_wlen_err   <= '0;
            status.lg_last_len   <= '0;
            status.lg_last_beats <= '0;
        end else if (lm_w) begin
            lm_beats <= lm_last ? '0 : lm_beats + 1'b1;
            // Early wlast, missing wlast, or W with no AW outstanding.
            if ((lm_last && lm_beats != 9'(lm_len)) || (!lm_last && lm_beats == 9'(lm_len))
                || !lm_valid) begin
                status.lg_wlen_err   <= status.lg_wlen_err + 1'b1;
                status.lg_last_len   <= lm_len;
                status.lg_last_beats <= 8'(lm_beats + 1'b1);
            end
        end
    end

    // ------------------------------------------------------------- DDR
    axi_arb #(.NW(NW), .NR(NR)) u_arb (.sw(mw), .sr(mr), .mw(dw), .mr(dr));

    assign ddr_awid    = dw.awid;
    assign ddr_awaddr  = dw.awaddr;
    assign ddr_awlen   = dw.awlen;
    assign ddr_awsize  = 3'($clog2(BEAT_BYTES));
    assign ddr_awburst = 2'b01;          // INCR
    assign ddr_awlock  = 1'b0;
    assign ddr_awcache = 4'b0011;
    assign ddr_awprot  = 3'b010;
    assign ddr_awvalid = dw.awvalid;
    assign dw.awready  = ddr_awready;
    assign ddr_wdata   = dw.wdata;
    assign ddr_wstrb   = '1;
    assign ddr_wlast   = dw.wlast;
    assign ddr_wvalid  = dw.wvalid;
    assign dw.wready   = ddr_wready;
    assign dw.bid      = ddr_bid;
    assign dw.bresp    = ddr_bresp;
    assign dw.bvalid   = ddr_bvalid;
    assign ddr_bready  = dw.bready;

    assign ddr_arid    = dr.arid;
    assign ddr_araddr  = dr.araddr;
    assign ddr_arlen   = dr.arlen;
    assign ddr_arsize  = 3'($clog2(BEAT_BYTES));
    assign ddr_arburst = 2'b01;
    assign ddr_arlock  = 1'b0;
    assign ddr_arcache = 4'b0011;
    assign ddr_arprot  = 3'b010;
    assign ddr_arvalid = dr.arvalid;
    assign dr.arready  = ddr_arready;
    assign dr.rid      = ddr_rid;
    assign dr.rdata    = ddr_rdata;
    assign dr.rresp    = ddr_rresp;
    assign dr.rlast    = ddr_rlast;
    assign dr.rvalid   = ddr_rvalid;
    assign ddr_rready  = dr.rready;

endmodule
