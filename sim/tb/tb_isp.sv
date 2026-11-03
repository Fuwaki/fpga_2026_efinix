// tb_isp.sv -- camera path end to end: a CSI source with sensor-like timing
// -> csi_capture -> line_release -> isp_top -> vdma_wr -> ISP ring in the DDR
// model.  The ring slots are dumped and compared, pixel by pixel, with
// sim/ref/isp_ref.py; the writer's frame signatures are compared too.
//
//   RAW     raw frame, one CSI beat (4 x 10 bit, p0 low) per line
//   DUMP    output file: '# sig <hex>' per committed frame, then the slots
//   BYPASS  1 = isp cfg bypass_all
//   PATTERN 1 = csi_capture's own picture instead of RAW
module tb_isp #(
    parameter string RAW     = "sim/obj/tb_isp/raw.hex",
    parameter string DUMP    = "sim/obj/tb_isp/dump.hex",
    parameter bit    BYPASS  = 0,
    parameter bit    PATTERN = 0,
    parameter int    FRAMES  = 2
);
    import vid_pkg::*;

    logic clk = 0, csi_clk = 0, rst_n = 0;
    always #5  clk     = ~clk;      // 100 MHz
    always #10 csi_clk = ~csi_clk;  // 50 MHz
    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1;
    end

    function automatic isp_cfg_t cfg_for(input bit bypass);
        isp_cfg_t c = ISP_CFG_DEFAULT;
        c.bypass_all = bypass;
        return c;
    endfunction

    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));
    axi_mem_model #(.READY_PCT(75), .BAD_IDS(1)) u_mem (.wr(dw), .rd(dr));

    // ------------------------------------------------------- CSI source
    localparam int BPL = CAM_W / 4;
    localparam int LINE_PERIOD = 810;          // 16.2 us at 50 MHz, as on the board
    logic [39:0] frame [CAM_H * BPL];
    logic        vs = 0, hs = 0, de = 0;
    logic [39:0] data = '0;
    int          sent;

    initial begin
        if (!PATTERN) $readmemh(RAW, frame);
        wait (rst_n);
        repeat (50) @(posedge csi_clk);
        for (int f = 0; f < FRAMES + 1; f++) begin
            vs <= 1;
            repeat (20) @(posedge csi_clk);
            vs <= 0;
            repeat (200) @(posedge csi_clk);
            for (int y = 0; y < CAM_H; y++) begin
                int c;
                c = 0;
                hs <= 1;
                repeat (3) @(posedge csi_clk);
                for (int b = 0; b < BPL; ) begin
                    // The receiver pauses inside lines; model it.
                    if ($urandom_range(99) < 85) begin
                        de   <= 1;
                        data <= PATTERN ? 40'($urandom()) : frame[y * BPL + b];
                        b++;
                    end else begin
                        de   <= 0;
                        data <= 40'($urandom());
                    end
                    @(posedge csi_clk);
                    c++;
                end
                de <= 0;
                @(posedge csi_clk);
                hs <= 0;
                repeat (LINE_PERIOD - c - 5) @(posedge csi_clk);
            end
            sent = f + 1;
            repeat (3000) @(posedge csi_clk);
        end
    end

    // -------------------------------------------------------------- DUT
    vid_status_t st;
    vid_subsystem #(.ENABLE_SELFTEST(0), .EXT_EN(0), .DISP_SRC(1), .CSI_PATTERN(PATTERN),
                    .ISP_CFG(cfg_for(BYPASS))) dut (
        .clk(clk), .rst_n(rst_n),
        .ext_awid('0), .ext_awaddr('0), .ext_awlen('0), .ext_awvalid(1'b0), .ext_awready(),
        .ext_wdata('0), .ext_wlast(1'b0), .ext_wvalid(1'b0), .ext_wready(),
        .ext_bid(), .ext_bresp(), .ext_bvalid(), .ext_bready(1'b1),
        .ext_arid('0), .ext_araddr('0), .ext_arlen('0), .ext_arvalid(1'b0), .ext_arready(),
        .ext_rid(), .ext_rdata(), .ext_rresp(), .ext_rlast(), .ext_rvalid(), .ext_rready(1'b1),
        .ddr_awid(dw.awid), .ddr_awaddr(dw.awaddr), .ddr_awlen(dw.awlen), .ddr_awsize(),
        .ddr_awburst(), .ddr_awlock(), .ddr_awcache(), .ddr_awprot(), .ddr_awvalid(dw.awvalid),
        .ddr_awready(dw.awready), .ddr_wdata(dw.wdata), .ddr_wstrb(), .ddr_wlast(dw.wlast),
        .ddr_wvalid(dw.wvalid), .ddr_wready(dw.wready), .ddr_bid(dw.bid), .ddr_bresp(dw.bresp),
        .ddr_bvalid(dw.bvalid), .ddr_bready(dw.bready),
        .ddr_arid(dr.arid), .ddr_araddr(dr.araddr), .ddr_arlen(dr.arlen), .ddr_arsize(),
        .ddr_arburst(), .ddr_arlock(), .ddr_arcache(), .ddr_arprot(), .ddr_arvalid(dr.arvalid),
        .ddr_arready(dr.arready), .ddr_rid(dr.rid), .ddr_rdata(dr.rdata), .ddr_rresp(dr.rresp),
        .ddr_rlast(dr.rlast), .ddr_rvalid(dr.rvalid), .ddr_rready(dr.rready),
        .csi_clk(csi_clk), .csi_vs(vs), .csi_hs(hs), .csi_de(de), .csi_data(data),
        .pix_clk(1'b0), .pix_r(), .pix_g(), .pix_b(), .pix_de(), .pix_hs(), .pix_vs(),
        .status(st));

    // ------------------------------------------------------------ check
    int n_hs = 0, n_eol = 0, n_rel_eol = 0;
    always @(negedge hs) n_hs++;
    always @(posedge csi_clk) if (dut.g_display.g_cam.cw_en && dut.g_display.g_cam.cw_data[40]) n_eol++;
    always @(posedge clk) if (dut.g_display.g_cam.raw.valid && dut.g_display.g_cam.raw.eol) n_rel_eol++;
    int fd;
    logic [SEQ_W-1:0] last_frames = '0;
    always @(posedge clk) begin
        if (rst_n && st.pw_frames != last_frames) begin
            last_frames <= st.pw_frames;
            // The signature register updates with the commit; sample it a
            // cycle later.
            @(posedge clk);
            $display("tb_isp: frame %0d committed, sig %08h", st.pw_frames, st.pw_sig);
            $fdisplay(fd, "# sig %08h", st.pw_sig);
        end
    end

    initial begin
        fd = $fopen(DUMP, "w");
        if (fd == 0) $fatal(1, "tb_isp: cannot open %s", DUMP);
        wait (rst_n);
        wait (int'(st.pw_frames) >= FRAMES || sent > FRAMES);
        repeat (100) @(posedge clk);
        $display("tb_isp: capture frames %0d lines %0d beats %0d dropped %0d | holes %0d isp dropped %0d | written %0d errors %0d skipped %0d",
                 st.cap_frames, st.cap_lines, st.cap_beats, st.cap_dropped,
                 st.rel_holes, st.isp_dropped, st.pw_frames, st.pw_errors, st.pw_skipped);
        $display("tb_isp: hs falls %0d, eol written %0d, eol released %0d", n_hs, n_eol, n_rel_eol);
        $display("tb_isp: raw sums %0d %0d %0d %0d clip %0d dark %0d",
                 st.raw_sum[0], st.raw_sum[1], st.raw_sum[2], st.raw_sum[3], st.raw_clip, st.raw_dark);
        $display("tb_isp: gray sums %0d %0d %0d (stat frames %0d)",
                 st.gray_sum[0], st.gray_sum[1], st.gray_sum[2], st.raw_frames);
        if (st.raw_frames >= 8'd2)
            $fdisplay(fd, "# gray %0d %0d %0d", st.gray_sum[0], st.gray_sum[1], st.gray_sum[2]);
        for (int k = 0; k < 3; k++) begin
            $fdisplay(fd, "# slot %0d", k);
            for (int y = 0; y < CAM_H; y++)
                for (int b = 0; b < CAM_W / BEAT_PIX; b++)
                    $fdisplay(fd, "%032h", u_mem.peek(longint'(slot_base(RING_ISP_BASE, 3'(k)))
                                                      + longint'(y) * LINE_STRIDE + longint'(b) * BEAT_BYTES));
        end
        $fclose(fd);
        if (int'(st.pw_frames) < FRAMES || st.pw_errors != 0 || st.cap_dropped != 0
            || st.rel_holes != 0 || st.isp_dropped != 0 || st.isp_ring_err)
            $fatal(1, "tb_isp FAIL: counters");
        $display("tb_isp done; compare with sim/ref/isp_ref.py");
        $finish;
    end
endmodule
