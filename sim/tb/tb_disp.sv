// tb_disp.sv -- the display path end to end: vid_patgen -> vdma_wr -> ring
// -> DDR model -> vdma_rd (dual-clock) -> compositor at 74.25 MHz.
//
// Every output pixel of every raster frame is compared with the expected
// picture: the 1280x720 layer fills the 720p60 raster, pat_pixel() through
// RGB565 inside,
// for the frame the reader acquired.  Passes when at least NGOOD consecutive
// raster frames match exactly and the compositor reports no bad lines in them.
//
// With PROC = 1 the processing engine writes each frame, inverted (PMODE 1)
// or as Sobel edges (PMODE 2), into the PROC ring, and SPLIT >= 0 shows
// layer 0 left of that column and the PROC ring from it on (any column, not
// only multiples of 8).
module tb_disp #(
    parameter int NGOOD = 3,
    parameter bit PROC  = 0,
    parameter int SPLIT = -1,
    parameter int PMODE = 1
);
    import vid_pkg::*;

    // Expected processed pixel at layer (x, y) of source frame f.  Sobel:
    // centred on (x - 2, y - 1), black in the first line and the first two
    // columns, neighbours above row 0 and left of column 0 mirrored.
    function automatic rgb888_t proc_pixel(input int x, input int y, input int f);
        rgb565_t    src;
        logic [7:0] w [3][3];
        if (PMODE == 1)
            return unpack565(rgb565_t'(~pack565(pat_pixel(12'(x), 12'(y), 16'(f)))));
        if (y == 0 || x < 2)
            return '0;
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++) begin
                int yy, xx;
                yy = y - 1 + dy; if (yy < 0) yy = 1;
                xx = x - 2 + dx; if (xx < 0) xx = 1;
                src = pack565(pat_pixel(12'(xx), 12'(yy), 16'(f)));
                w[dy + 1][dx + 1] = luma8(src);
            end
        begin
            logic [7:0] e;
            e = sobel8(w);
            return unpack565(pack565('{r: e, g: e, b: e}));
        end
    endfunction

    function automatic comp_cfg_t comp_for(input int split);
        comp_cfg_t c = COMP_CFG_DEFAULT;
        if (split >= 0) begin
            c.mode      = COMP_SPLIT;
            c.split_col = 12'(split);
        end
        return c;
    endfunction

    logic clk = 0, pclk = 0, rst_n = 0;
    always #5     clk  = ~clk;      // 100 MHz
    always #6.734 pclk = ~pclk;     // 74.25 MHz
    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1;
    end

    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));
    axi_mem_model #(.READY_PCT(75), .BAD_IDS(1)) u_mem (.wr(dw), .rd(dr));

    logic [7:0] r, g, b;
    logic       de, hs, vs;
    vid_status_t st;

    vid_subsystem #(.ENABLE_SELFTEST(0), .PAT_FRAME_CYCLES(1_500_000), .PAT_LINE_CYCLES(2_000),
                    .PROC_EN(PROC), .PROC_MODE(PMODE == 2 ? PROC_SOBEL : PROC_INVERT), .COMP_CFG(comp_for(SPLIT))) dut (
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
        .csi_clk(1'b0), .csi_vs(1'b0), .csi_hs(1'b0), .csi_de(1'b0), .csi_data('0),
        .pix_clk(pclk), .pix_r(r), .pix_g(g), .pix_b(b), .pix_de(de), .pix_hs(hs), .pix_vs(vs),
        .status(st));

    localparam int X0 = 0, Y0 = 0;

    // Output raster position, rebuilt from de/vs.
    int  ox, oy, frames, good_run, bad_px, bad_lines_at_start;
    bit  de_d, vs_d, frame_has_layer;
    int  shown;      // pattern frame number shown in this raster frame (-1: black)
    int  shown1;     // the same for layer 1 (the processed frame's source)
    int  hist[$];

    always_ff @(posedge pclk) begin
        if (rst_n) begin
            de_d <= de;
            vs_d <= vs;
            if (vs && !vs_d) begin
                // End of a raster frame (vsync starts after the active area).
                if (frames > 0) begin
                    hist.push_back(shown);
                    // Frames before the first commit are black by design:
                    // they must be correct but do not count.
                    if (bad_px != 0)
                        good_run <= 0;
                    else if (frame_has_layer && int'(st.cp_bad_lines) + int'(st.cp1_bad_lines) == bad_lines_at_start
                             && (SPLIT < 0 || shown1 >= 0))
                        good_run <= good_run + 1;
                    $display("raster frame %0d: pattern frame %0d / %0d, %0d bad pixels, bad lines total %0d + %0d",
                             frames, shown, shown1, bad_px, st.cp_bad_lines, st.cp1_bad_lines);
                end
                frames             <= frames + 1;
                oy                 <= 0;
                bad_px             <= 0;
                frame_has_layer    <= 0;
                bad_lines_at_start <= int'(st.cp_bad_lines) + int'(st.cp1_bad_lines);
            end
            if (de) begin
                rgb888_t want;
                bit in_l;
                int f;
                int  f1;
                bit  right;
                in_l = ox >= X0 && ox < X0 + CAM_W && oy >= Y0 && oy < Y0 + CAM_H;
                // The frame on screen is the one the reader holds when the
                // layer starts; none held (nothing committed yet) = black.
                f = (ox == X0 && oy == Y0)
                  ? (dut.g_display.rd_tok.valid ? int'(dut.g_display.rd_tok.src_seq) : -1)
                  : shown;
                f1 = (ox == X0 && oy == Y0)
                   ? (dut.g_display.rd1_tok.valid ? int'(dut.g_display.rd1_tok.src_seq) : -1)
                   : shown1;
                if (in_l && ox == X0 && oy == Y0) begin
                    shown  <= f;
                    shown1 <= f1;
                end
                right = SPLIT >= 0 && ox - X0 >= SPLIT;
                if (in_l && !right && f >= 0) begin
                    want = unpack565(pack565(pat_pixel(12'(ox - X0), 12'(oy - Y0), 16'(f))));
                    frame_has_layer <= 1;
                end else if (in_l && right && f1 >= 0) begin
                    want = proc_pixel(ox - X0, oy - Y0, f1);
                    frame_has_layer <= 1;
                end else begin
                    want = '0;
                end
                if ({r, g, b} != want && frames > 0) begin
                    if (bad_px < 4 && good_run < NGOOD)
                        $display("  (%0d,%0d) got %h%h%h want %h", ox, oy, r, g, b, want);
                    bad_px <= bad_px + 1;
                end
                ox <= ox + 1;
            end else if (de_d) begin
                ox <= 0;
                oy <= oy + 1;
            end
        end else begin
            ox <= 0; oy <= 0; frames <= 0; good_run <= 0; bad_px <= 0; shown <= -1; shown1 <= -1;
            de_d <= 0; vs_d <= 0; frame_has_layer <= 0; bad_lines_at_start <= 0;
        end
    end

    initial begin
        wait (rst_n);
        wait (good_run >= NGOOD || frames > NGOOD + 4);
        $display("tb_disp: pattern frames written %0d, display reads %0d (miss %0d, late %0d), bad lines %0d, resyncs %0d",
                 st.pw_frames, st.dr_frames, st.dr_miss, st.dr_late, st.cp_bad_lines, st.cp_resyncs);
        $display("tb_disp: processed %0d (miss %0d err %0d skip %0d), layer 1 reads %0d, seq gap %0d",
                 st.pr_frames, st.pr_miss, st.pr_errors, st.pr_skipped, st.dr1_frames, st.seq_gap);
        if (good_run < NGOOD)
            $fatal(1, "tb_disp FAIL: only %0d consecutive correct frames", good_run);
        $display("tb_disp PASS");
        $finish;
    end
endmodule
