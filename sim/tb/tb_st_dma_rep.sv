// tb_st_dma_rep.sv -- tile_dma_rd line repeat (line_shift = 1).
//
// Memory holds lines whose every beat is tagged with its line and beat index.
// Two transfers run back to back on the same reader, with random R
// back-pressure from the model and random output ready:
//   * line_shift 1, 6 lines of 5 beats: lines 0,0,1,1,2,2 must come back;
//   * line_shift 0, 3 lines: lines 0,1,2 (no repeat leaks into the next start).
// sof/eol are checked on every beat.
module tb_st_dma_rep;
    import vid_pkg::*;

    localparam logic [AXI_AW-1:0] BASE   = 32'h0100_0f80;   // bursts cross 4 KiB
    localparam int                STRIDE = 4096;
    localparam int                NB     = 5;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dw (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) dr (.clk(clk), .rst_n(rst_n));
    axi_mem_model #(.READY_PCT(60)) u_mem (.wr(dw), .rd(dr));

    assign dw.awvalid = 1'b0;
    assign dw.awid    = '0;
    assign dw.awaddr  = '0;
    assign dw.awlen   = '0;
    assign dw.wvalid  = 1'b0;
    assign dw.wdata   = '0;
    assign dw.wlast   = 1'b0;
    assign dw.bready  = 1'b1;

    vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) o (.clk(clk), .rst_n(rst_n));

    logic              start = 0, shift = 0, busy;
    logic [15:0]       lines = 0;

    tile_dma_rd #(.FIFO_BEATS(16), .RD_BURST(4)) dut (
        .m(dr), .o(o),
        .start(start), .base_addr(BASE), .beats_per_line(16'(NB)), .lines(lines),
        .line_stride(AXI_AW'(STRIDE)), .line_shift(shift),
        .busy(busy), .err(), .st_done(), .st_err());

    function automatic logic [AXI_DW-1:0] tag(input int line, input int beat);
        return {32'hC0DE_0000 | 32'(line), 32'(beat), 64'h0123_4567_89AB_CDEF};
    endfunction

    always @(posedge clk) o.ready <= $urandom_range(99) < 70;

    // Expected source line of each output line, both transfers concatenated.
    int exp_line [$] = '{0, 0, 1, 1, 2, 2, 0, 1, 2};
    int got = 0, errs = 0, oline = 0, obeat = 0;

    always @(posedge clk) begin
        if (rst_n && o.valid && o.ready) begin
            automatic logic [AXI_DW-1:0] want = tag(exp_line[oline], obeat);
            automatic bit first = (oline == 0 || oline == 6) && obeat == 0;
            if (o.data[0] !== want || o.sof !== first || o.eol !== (obeat == NB - 1)) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH out line %0d beat %0d: data %h sof %b eol %b, want line %0d",
                             oline, obeat, o.data[0], o.sof, o.eol, exp_line[oline]);
            end
            got++;
            if (obeat == NB - 1) begin
                obeat = 0;
                oline++;
            end else begin
                obeat++;
            end
        end
    end

    task automatic run(input bit sh, input int nl);
        @(negedge clk);
        shift = sh;
        lines = 16'(nl);
        start = 1;
        @(negedge clk);
        start = 0;
        wait (!busy);
    endtask

    initial begin
        for (int l = 0; l < 3; l++)
            for (int b = 0; b < NB; b++)
                u_mem.poke(64'(BASE) + 64'(l * STRIDE + b * BEAT_BYTES), tag(l, b));
        repeat (5) @(posedge clk);
        rst_n = 1;
        run(1'b1, 6);
        run(1'b0, 3);
        repeat (200) @(posedge clk);
        if (errs != 0 || got != 9 * NB)
            $fatal(1, "tb_st_dma_rep FAIL %0d errors, %0d of %0d beats", errs, got, 9 * NB);
        $display("tb_st_dma_rep PASS %0d beats", got);
        $finish;
    end
endmodule
