// tb_st_engine.sv -- the block engine alone against tools/st_engine_vectors.py.
//
// DDR (axi_mem_model, random back-pressure) holds the camera frame in an ISP
// slot.  The engine runs passes +FIRST..+LAST (default 0..14); afterwards
// every DDR region the run wrote is compared byte-exact with the golden
// p{N}.hex, and with pass 14 the whole PROC slot with proc.hex.  For a
// subrange, the regions the run does not write are preloaded from the golden
// images, so one pass can be debugged on its own; the regions it writes start
// as the model's FILL pattern.  Reports the first mismatching beat of each
// region and the cycles of every pass.
module tb_st_engine;
    import vid_pkg::*;
    import st_net_pkg::*;

    localparam logic [AXI_AW-1:0] ISP  = 32'h0440_0000;   // ISP slot 1
    localparam logic [AXI_AW-1:0] PROC = 32'h0600_0000;   // PROC slot 0

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));
    axi_mem_model #(.READY_PCT(80), .BAD_IDS(1)) u_mem (.wr(dw), .rd(dr));

    logic        start = 0, busy, pre_done, err;
    logic [3:0]  pass, first = 0, last = 4'(ST_N_PASSES - 1);
    logic [31:0] cycles;

    st_engine u_eng (
        .clk(clk), .rst_n(rst_n), .m_wr(dw), .m_rd(dr),
        .start(start), .isp_base(ISP), .proc_base(PROC),
        .first_pass(first), .last_pass(last),
        .busy(busy), .pre_done(pre_done), .err(err), .pass(pass), .cycles(cycles));

    string dir;

    // Load a hex file of beats: line i goes to base + i*16, or with a stride,
    // bpl beats per line at base + line*stride.
    function automatic int load(input string f, input logic [AXI_AW-1:0] base,
                                input int bpl, input int stride);
        int fd, n = 0;
        logic [127:0] v;
        fd = $fopen({dir, "/", f}, "r");
        if (fd == 0) $fatal(1, "tb_st_engine: cannot open %s/%s", dir, f);
        while ($fscanf(fd, "%h\n", v) == 1) begin
            u_mem.poke(64'(base) + 64'((n / bpl) * stride + (n % bpl) * BEAT_BYTES), v);
            n++;
        end
        $fclose(fd);
        return n;
    endfunction

    // Compare: returns the number of mismatching beats, prints the first.
    function automatic int check(input string f, input string what, input logic [AXI_AW-1:0] base,
                                 input int bpl, input int stride);
        int fd, n = 0, bad = 0;
        logic [127:0] v, got;
        fd = $fopen({dir, "/", f}, "r");
        if (fd == 0) $fatal(1, "tb_st_engine: cannot open %s/%s", dir, f);
        while ($fscanf(fd, "%h\n", v) == 1) begin
            got = u_mem.peek(64'(base) + 64'((n / bpl) * stride + (n % bpl) * BEAT_BYTES));
            if (got !== v) begin
                if (bad == 0)
                    $display("  %s: first mismatch at beat %0d (line %0d beat %0d): got %h want %h",
                             what, n, n / bpl, n % bpl, got, v);
                bad++;
            end
            n++;
        end
        $fclose(fd);
        return bad;
    endfunction

    // the pass that writes point pt, or -1
    function automatic int writer(input int pt);
        for (int p = 0; p < ST_N_PASSES - 1; p++)
            if (int'(st_pass(p).out_point) == pt) return p;
        return -1;
    endfunction

    // per-pass cycles
    longint t_pass;
    logic [3:0] pass_q;
    logic       busy_q;
    always @(posedge clk) begin
        busy_q <= busy;
        pass_q <= pass;
        if (busy && !busy_q) t_pass = $time;
        if (busy_q && (pass != pass_q || !busy)) begin
            $display("pass %2d: %0d cycles", pass_q, ($time - t_pass) / 10);
            t_pass = $time;
        end
    end

    initial begin
        int bad = 0, fa = 0, la = ST_N_PASSES - 1;
        if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "tb_st_engine: +DIR missing");
        void'($value$plusargs("FIRST=%d", fa));
        void'($value$plusargs("LAST=%d", la));
        first = 4'(fa);
        last  = 4'(la);

        void'(load("frame.hex", ISP, CAM_W * PIX_BYTES / BEAT_BYTES, LINE_STRIDE));
        for (int i = 0; i < ST_N_REGIONS; i++) begin
            automatic int pt = int'(st_region_point(i));
            automatic int w  = writer(pt);
            if (w < fa || w > la)
                void'(load($sformatf("p%0d.hex", pt), st_region(pt).base, 1, BEAT_BYTES));
        end

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
        @(posedge clk);
        wait (!busy);
        $display("tb_st_engine: passes %0d..%0d in %0d cycles, err %b", fa, la, cycles, err);

        for (int i = 0; i < ST_N_REGIONS; i++) begin
            automatic int pt = int'(st_region_point(i));
            automatic int w  = writer(pt);
            if (w >= fa && w <= la) begin
                automatic int b = check($sformatf("p%0d.hex", pt), $sformatf("pass %0d p%0d", w, pt),
                                        st_region(pt).base, 1, BEAT_BYTES);
                if (b != 0) $display("  pass %0d (p%0d): %0d bad beats", w, pt, b);
                bad += b;
            end
        end
        if (la == ST_N_PASSES - 1) begin
            automatic int b = check("proc.hex", "pass 14 PROC slot", PROC,
                                    CAM_W * PIX_BYTES / BEAT_BYTES, LINE_STRIDE);
            if (b != 0) $display("  pass 14 (PROC): %0d bad beats", b);
            bad += b;
        end
        if (bad != 0 || err)
            $fatal(1, "tb_st_engine FAIL: %0d bad beats, err %b", bad, err);
        $display("tb_st_engine PASS passes %0d..%0d, %0d cycles", fa, la, cycles);
        $finish;
    end
endmodule
