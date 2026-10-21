// tb_vidsub.sv -- vid_subsystem with its self-test running against the DDR
// model, while a busy random master on the legacy port competes for DDR at
// higher priority.  Passes when the self-test reads back every frame intact.
module tb_vidsub #(parameter bit BAD_IDS = 0);
    import vid_pkg::*;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1;
    end

    localparam int LINES = 24, FRAMES = 6;
    localparam int LINE_CYC = 1600, FRAME_CYC = LINES * LINE_CYC + 3000;   // camera-like line rate

    // DDR side, through the model.
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));
    axi_mem_model #(.READY_PCT(75), .BAD_IDS(BAD_IDS)) u_mem (.wr(dw), .rd(dr));

    // Legacy port: a busy random master in its own region.  Like the real
    // frame store it keeps at most two read bursts outstanding (the real one
    // is limited by its FIFO); without a limit any in-order memory would
    // queue requests without bound.
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) lw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) lr (.clk(clk), .rst_n(rst_n));

    int lw_beat, lw_bursts, lr_bursts, lr_out;
    logic lw_wpend;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lw.awvalid <= 0; lw.awid <= '0; lw.awaddr <= '0; lw.awlen <= '0;
            lw.wvalid <= 0; lw.wdata <= '0; lw.wlast <= 0; lw.bready <= 1;
            lr.arvalid <= 0; lr.arid <= '0; lr.araddr <= '0; lr.arlen <= '0; lr.rready <= 1;
            lw_beat <= 0; lw_bursts <= 0; lr_bursts <= 0; lw_wpend <= 0; lr_out <= 0;
        end else begin
            if (lw.awvalid && lw.awready) begin lw.awvalid <= 0; lw_wpend <= 1; lw_beat <= 0; end
            if (!lw.awvalid && !lw_wpend && $urandom_range(999) < 15) begin
                lw.awvalid <= 1;
                lw.awaddr  <= 32'h0010_0000 + 32'($urandom_range(255)) * 2048;
                lw.awlen   <= 8'd127;
            end
            if (lw_wpend) begin
                if (!lw.wvalid || lw.wready) begin
                    if (lw.wvalid && lw.wready && lw.wlast) begin
                        lw.wvalid <= 0; lw_wpend <= 0; lw_bursts <= lw_bursts + 1;
                    end else begin
                        lw.wvalid <= 1;
                        lw.wdata  <= {4{32'($urandom())}};
                        lw.wlast  <= (lw_beat == 127);
                        lw_beat   <= lw_beat + ((lw.wvalid && lw.wready) || !lw.wvalid ? 1 : 0);
                    end
                end
            end
            lr_out <= lr_out + ((lr.arvalid && lr.arready) ? 1 : 0)
                             - ((lr.rvalid && lr.rready && lr.rlast) ? 1 : 0);
            if (lr.arvalid && lr.arready) begin lr.arvalid <= 0; lr_bursts <= lr_bursts + 1; end
            if (!lr.arvalid && lr_out < 2 && $urandom_range(999) < 15) begin
                lr.arvalid <= 1;
                lr.araddr  <= 32'h0010_0000 + 32'($urandom_range(255)) * 2048;
                lr.arlen   <= 8'd127;
            end
            lr.rready <= $urandom_range(99) < 90;
        end
    end

    vid_status_t st;

    vid_subsystem #(.TEST_LINES(LINES), .TEST_FRAME_CYCLES(FRAME_CYC), .TEST_LINE_CYCLES(LINE_CYC)) dut (
        .clk(clk), .rst_n(rst_n),
        .lg_awid(lw.awid), .lg_awaddr(lw.awaddr), .lg_awlen(lw.awlen), .lg_awvalid(lw.awvalid),
        .lg_awready(lw.awready), .lg_wdata(lw.wdata), .lg_wlast(lw.wlast), .lg_wvalid(lw.wvalid),
        .lg_wready(lw.wready), .lg_bid(lw.bid), .lg_bresp(lw.bresp), .lg_bvalid(lw.bvalid),
        .lg_bready(lw.bready),
        .lg_arid(lr.arid), .lg_araddr(lr.araddr), .lg_arlen(lr.arlen), .lg_arvalid(lr.arvalid),
        .lg_arready(lr.arready), .lg_rid(lr.rid), .lg_rdata(lr.rdata), .lg_rresp(lr.rresp),
        .lg_rlast(lr.rlast), .lg_rvalid(lr.rvalid), .lg_rready(lr.rready),
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
        .status(st));

    initial begin
        wait (rst_n);
        repeat (FRAME_CYC * (FRAMES + 1)) @(posedge clk);
        $display("tb_vidsub: written %0d (err %0d skip %0d), checked %0d good / %0d bad (%0d bad words), legacy %0d wr %0d rd bursts",
                 st.tw_frames, st.tw_errors, st.tw_skipped, st.tc_frames, st.tc_bad_frames,
                 st.tc_bad_words, lw_bursts, lr_bursts);
        $display("  ring commits %0d aborts %0d drops %0d | reader state %0d busy %0b inflight %0d y_q %0d y_r %0d miss %0d | writer state %0d",
                 st.test_ring.commits, st.test_ring.aborts, st.test_ring.drops,
                 dut.g_selftest.u_rd.state, dut.g_selftest.u_rd.busy, dut.g_selftest.u_rd.inflight,
                 dut.g_selftest.u_rd.y_q, dut.g_selftest.u_rd.y_r, st.tr_miss, dut.g_selftest.u_wr.state);
        if (st.tc_bad_words != 0 || st.tc_bad_frames != 0 || st.tw_errors != 0
            || int'(st.tc_frames) < FRAMES - 1 || st.test_ring.proto_err || lw_bursts < 10)
            $fatal(1, "tb_vidsub FAIL");
        $display("tb_vidsub PASS");
        $finish;
    end
endmodule
