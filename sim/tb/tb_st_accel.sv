// tb_st_accel.sv -- the ST accelerator as the processing engine:
// vid_patgen -> ISP ring -> st_accel_wrapper (ext master, PROC_EXT = 1)
// -> st_engine's 15 passes through DDR -> PROC ring, all through axi_arb and
// the DDR model.
//
// The pixels themselves are checked byte-exact by tb_st_engine against the
// golden model; this test checks the ring level.  On every PROC commit the
// whole slot is read back: every 2x2 block must be one pixel (st_post's
// replication) up to its output dither -- each RGB565 field within one code
// of the block's top-left pixel -- and the content must not be constant.  Passes after NGOOD good frames with no aborts.
module tb_st_accel #(
    parameter int NGOOD = 2
);
    import vid_pkg::*;

    logic clk = 0, pclk = 0, rst_n = 0;
    always #5     clk  = ~clk;
    always #6.734 pclk = ~pclk;
    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1;
    end

    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) xw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) xr (.clk(clk), .rst_n(rst_n));
    axi_mem_model #(.READY_PCT(75), .BAD_IDS(1)) u_mem (.wr(dw), .rd(dr));

    logic                   src_req, src_ack, src_ok, dst_req, dst_ack, dst_ok;
    ring_c_op_e             src_op;
    ring_p_op_e             dst_op;
    frame_token_t           src_token;
    logic [SEQ_W-1:0]       dst_src_seq, frames, miss, errors, skipped;
    logic [31:0]            cycles;
    logic [RING_SLOT_W-1:0] dst_slot;
    vid_status_t            st;

    st_accel_wrapper u_st (
        .clk(clk), .rst_n(rst_n),
        .m_axi_awid(xw.awid), .m_axi_awaddr(xw.awaddr), .m_axi_awlen(xw.awlen),
        .m_axi_awvalid(xw.awvalid), .m_axi_awready(xw.awready),
        .m_axi_wdata(xw.wdata), .m_axi_wlast(xw.wlast), .m_axi_wvalid(xw.wvalid),
        .m_axi_wready(xw.wready), .m_axi_bid(xw.bid), .m_axi_bresp(xw.bresp),
        .m_axi_bvalid(xw.bvalid), .m_axi_bready(xw.bready),
        .m_axi_arid(xr.arid), .m_axi_araddr(xr.araddr), .m_axi_arlen(xr.arlen),
        .m_axi_arvalid(xr.arvalid), .m_axi_arready(xr.arready),
        .m_axi_rid(xr.rid), .m_axi_rdata(xr.rdata), .m_axi_rresp(xr.rresp),
        .m_axi_rlast(xr.rlast), .m_axi_rvalid(xr.rvalid), .m_axi_rready(xr.rready),
        .src_req(src_req), .src_op(src_op), .src_ack(src_ack), .src_ok(src_ok), .src_token(src_token),
        .dst_req(dst_req), .dst_op(dst_op), .dst_src_seq(dst_src_seq),
        .dst_ack(dst_ack), .dst_ok(dst_ok), .dst_slot(dst_slot),
        .busy(), .st_frames(frames), .st_miss(miss), .st_errors(errors), .st_skipped(skipped),
        .st_cycles(cycles));

    vid_subsystem #(.ENABLE_SELFTEST(0), .PAT_FRAME_CYCLES(1_500_000), .PAT_LINE_CYCLES(2_000),
                    .PROC_EN(1), .PROC_EXT(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .ext_awid(xw.awid), .ext_awaddr(xw.awaddr), .ext_awlen(xw.awlen), .ext_awvalid(xw.awvalid),
        .ext_awready(xw.awready), .ext_wdata(xw.wdata), .ext_wlast(xw.wlast), .ext_wvalid(xw.wvalid),
        .ext_wready(xw.wready), .ext_bid(xw.bid), .ext_bresp(xw.bresp), .ext_bvalid(xw.bvalid),
        .ext_bready(xw.bready),
        .ext_arid(xr.arid), .ext_araddr(xr.araddr), .ext_arlen(xr.arlen), .ext_arvalid(xr.arvalid),
        .ext_arready(xr.arready), .ext_rid(xr.rid), .ext_rdata(xr.rdata), .ext_rresp(xr.rresp),
        .ext_rlast(xr.rlast), .ext_rvalid(xr.rvalid), .ext_rready(xr.rready),
        .ext_src_req(src_req), .ext_src_op(src_op), .ext_src_ack(src_ack), .ext_src_ok(src_ok),
        .ext_src_token(src_token),
        .ext_dst_req(dst_req), .ext_dst_op(dst_op), .ext_dst_src_seq(dst_src_seq),
        .ext_dst_ack(dst_ack), .ext_dst_ok(dst_ok), .ext_dst_slot(dst_slot),
        .ext_pr_frames(frames), .ext_pr_miss(miss), .ext_pr_errors(errors), .ext_pr_skipped(skipped),
        .ddr_awid(dw.awid), .ddr_awaddr(dw.awaddr), .ddr_awlen(dw.awlen), .ddr_awsize(),
        .ddr_awburst(), .ddr_awlock(), .ddr_awcache(), .ddr_awprot(), .ddr_awvalid(dw.awvalid),
        .ddr_awready(dw.awready), .ddr_wdata(dw.wdata), .ddr_wstrb(), .ddr_wlast(dw.wlast),
        .ddr_wvalid(dw.wvalid), .ddr_wready(dw.wready), .ddr_bid(dw.bid), .ddr_bresp(dw.bresp),
        .ddr_bvalid(dw.bvalid), .ddr_bready(dw.bready),
        .ddr_arid(dr.arid), .ddr_araddr(dr.araddr), .ddr_arlen(dr.arlen), .ddr_arsize(),
        .ddr_arburst(), .ddr_arlock(), .ddr_arcache(), .ddr_arprot(), .ddr_arvalid(dr.arvalid),
        .ddr_arready(dr.arready), .ddr_rid(dr.rid), .ddr_rdata(dr.rdata), .ddr_rresp(dr.rresp),
        .ddr_rlast(dr.rlast), .ddr_rvalid(dr.rvalid), .ddr_rready(dr.rready),
        .csi_clk(1'b0), .csi_vs(1'b0), .csi_hs(1'b0), .csi_de(1'b0), .csi_data('0),
        .pix_clk(pclk), .pix_r(), .pix_g(), .pix_b(), .pix_de(), .pix_hs(), .pix_vs(),
        .status(st));

    // Check each committed PROC slot: every 2x2 block of the 1280x720 slot is
    // one source pixel, dithered: a field is the code for t = 0 or one more.
    function automatic bit near(input logic [15:0] p, input logic [15:0] q);
        int dr, dg, db;
        dr = int'(p[15:11]) - int'(q[15:11]);
        dg = int'(p[10:5])  - int'(q[10:5]);
        db = int'(p[4:0])   - int'(q[4:0]);
        return dr >= -1 && dr <= 1 && dg >= -1 && dg <= 1 && db >= -1 && db <= 1;
    endfunction
    int good = 0, checked = 0;
    always @(posedge clk) begin
        if (rst_n && dst_req && dst_ack && dst_op == RING_P_COMMIT) begin
            int bad = 0, f;
            logic [15:0] first_px, px [CAM_W], top [CAM_W];
            bit varies;
            logic [AXI_AW-1:0] base;
            f        = int'(dst_src_seq);
            base     = slot_base(RING_PROC_BASE, u_st.slot);
            varies   = 0;
            first_px = 'x;
            for (int y = 0; y < CAM_H; y++) begin
                for (int b = 0; b < CAM_W / BEAT_PIX; b++) begin
                    logic [AXI_DW-1:0] got;
                    got = u_mem.peek(longint'(line_addr(base, 12'(y))) + longint'(b * BEAT_BYTES));
                    for (int p = 0; p < BEAT_PIX; p++)
                        px[b * BEAT_PIX + p] = got[p*16 +: 16];
                end
                if (y % 2 == 0) top = px;      // the block's first line
                for (int x = 0; x < CAM_W; x++) begin
                    bit ok;
                    ok = near(px[x], top[x - x % 2]);
                    if (^px[x] === 1'bx) ok = 0;
                    if (y == 0 && x == 0) first_px = px[x];
                    else if (px[x] != first_px) varies = 1;
                    if (!ok) begin
                        if (bad < 4)
                            $display("  frame %0d (%0d,%0d): %h breaks the 2x2 structure",
                                     f, x, y, px[x]);
                        bad++;
                    end
                end
            end
            if (!varies) begin
                $display("  frame %0d: constant content %h", f, first_px);
                bad++;
            end
            checked++;
            if (bad == 0) good++;
            $display("PROC commit %0d: source frame %0d slot %0d, %0d bad pixels, engine %0d cycles (t=%0t)",
                     checked, f, u_st.slot, bad, cycles, $time);
        end
    end

    initial begin
        wait (rst_n);
        fork
            wait (good >= NGOOD);
            wait (checked > good);
            begin #400ms; end
        join_any
        $display("tb_st_accel: commits %0d miss %0d errors %0d skipped %0d, ISP frames %0d",
                 frames, miss, errors, skipped, st.pw_frames);
        if (good < NGOOD || checked != good || errors != 0)
            $fatal(1, "tb_st_accel FAIL: %0d good of %0d checked", good, checked);
        $display("tb_st_accel PASS");
        $finish;
    end
endmodule
