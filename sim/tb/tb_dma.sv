// tb_dma.sv -- frame DMA end to end: producer -> vdma_wr -> axi_arb -> DDR
// model -> axi_arb -> two vdma_rd readers -> checkers, linked by a frame_ring.
//
//   reader 0  REPEAT_OK, whole frame, started on a fixed period (a display)
//   reader 1  NEW_ONLY, crop window, started whenever idle (a processor)
//
// Every word carries hash(frame, line, word), so a checker knows exactly what
// each word must be once it knows which frame it is reading.  Every SHORT-th
// frame is produced one line short and must be aborted, never shown.
// Protocol checkers are bound to every stream and AXI interface.
package tb_dma_pkg;
    function automatic logic [31:0] pat(input int f, input int y, input int w);
        logic [31:0] h;
        h = 32'(f) * 32'h9E37_79B1 ^ 32'(y) * 32'h85EB_CA6B ^ 32'(w) * 32'hC2B2_AE35;
        return h ^ (h >> 15);
    endfunction
endpackage


module tb_dma_check #(
    parameter int W_WORDS = 640,   // words per (cropped) line
    parameter int X0_WORD = 0,     // first word of the crop, in full-line words
    parameter int H       = 8,
    parameter int READY_PCT = 70
) (
    vstream_if.snk  s,
    input  logic    acq,           // reader acquired a frame this cycle
    input  int      acq_frame,     // its source frame number
    output int      frames,
    output int      errors,
    output int      seen [$]
);
    import tb_dma_pkg::*;
    int q[$];
    int f, y, w;
    bit in_frame;

    always_ff @(posedge s.clk or negedge s.rst_n) begin
        if (!s.rst_n) begin
            s.ready <= 1'b0;
            frames = 0; errors = 0; in_frame = 0; f = -1; y = 0; w = 0;
        end else begin
            if (acq)
                q.push_back(acq_frame);
            s.ready <= $urandom_range(99) < READY_PCT;
            if (s.valid && s.ready) begin
                if (s.sof) begin
                    if (q.size() == 0) begin
                        errors++; $error("%m: sof with no acquired frame");
                    end else begin
                        f = q.pop_front();
                        seen.push_back(f);
                    end
                    in_frame = 1; y = 0; w = 0;
                end
                if (!in_frame) begin
                    errors++; $error("%m: word outside a frame");
                end else begin
                    if (s.data != pat(f, y, X0_WORD + w)) begin
                        errors++;
                        if (errors < 10)
                            $error("%m: frame %0d line %0d word %0d: got %h want %h",
                                   f, y, w, s.data, pat(f, y, X0_WORD + w));
                    end
                    if (s.eol != (w == W_WORDS - 1)) begin
                        errors++; $error("%m: eol %0b at line %0d word %0d", s.eol, y, w);
                    end
                    if (w == W_WORDS - 1) begin
                        w = 0;
                        if (y == H - 1) begin
                            frames++; in_frame = 0;
                        end else
                            y++;
                    end else
                        w++;
                end
            end
        end
    end
endmodule


module tb_dma #(
    parameter int WPX    = 1280,     // pixels per line: 160 beats -> bursts of 128 + 32
    parameter int H      = 6,
    parameter int FRAMES = 14,
    parameter int SHORT  = 4         // every SHORT-th frame is one line short
);
    import vid_pkg::*;
    import tb_dma_pkg::*;

    localparam int W_WORDS = WPX / 2;          // 32-bit words, 2 px each

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1;
    end

    // ------------------------------------------------------------ producer
    vstream_if #(.T(rgb565_t), .PPC(2)) src (.clk(clk), .rst_n(rst_n));
    int  pf, py, pw;
    bit  pdone;
    int  short_frames[$];
    // Frame number of the frame entering vdma_wr.  vdma_wr samples src_seq
    // when that frame's sof reaches its FIFO head; the FIFO is shorter than a
    // frame, so the producer is still on the same frame then.
    int  cur_frame;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src.valid <= 0; src.sof <= 0; src.eol <= 0; src.data <= '0;
            pf = 0; py = 0; pw = 0; pdone = 0; cur_frame = 0;
        end else begin
            int lines;
            if (src.valid && src.ready)
                src.valid <= 0;
            lines = (pf % SHORT == SHORT - 1) ? H - 1 : H;
            if ((!src.valid || src.ready) && !pdone && $urandom_range(99) < 85) begin
                src.valid <= 1;
                src.data  <= pat(pf, py, pw);
                src.sof   <= (py == 0 && pw == 0);
                if (py == 0 && pw == 0) cur_frame = pf;
                src.eol   <= (pw == W_WORDS - 1);
                if (pw == W_WORDS - 1) begin
                    pw = 0;
                    if (py == lines - 1) begin
                        if (lines != H) short_frames.push_back(pf);
                        py = 0; pf++;
                        if (pf == FRAMES) pdone = 1;
                    end else
                        py++;
                end else
                    pw++;
            end
        end
    end


    // ---------------------------------------------------------------- ring
    ring_prod_if rp ();
    ring_cons_if rc [2] ();
    ring_status_t rstat;
    frame_ring #(.SLOTS(4), .NCONS(2)) u_ring (
        .clk(clk), .rst_n(rst_n), .p(rp), .c(rc), .status(rstat));

    // ---------------------------------------------------------------- AXI
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) w_m [1] (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) r_m [2] (.clk(clk), .rst_n(rst_n));
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) w_s (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) r_s (.clk(clk), .rst_n(rst_n));

    axi_arb #(.NW(1), .NR(2), .STARVE(64)) u_arb (.sw(w_m), .sr(r_m), .mw(w_s), .mr(r_s));
    axi_mem_model #(.READY_PCT(60)) u_mem (.wr(w_s), .rd(r_s));

    // -------------------------------------------------------------- writer
    logic [SEQ_W-1:0] wr_frames, wr_skipped, wr_errors;
    logic [31:0]      wr_sig;
    frame_geom_t      geom;
    assign geom = '{w: 13'(WPX), h: 13'(H)};

    vdma_wr #(.FIFO_WORDS(1024)) u_wr (
        .s(src), .m(w_m[0]), .ring(rp),
        .ring_base(RING_TEST_BASE), .geom(geom), .src_seq(SEQ_W'(cur_frame)),
        .st_frames(wr_frames), .st_skipped(wr_skipped), .st_errors(wr_errors), .st_sig(wr_sig));

    // ------------------------------------------------------------- readers
    localparam int CROP_X0 = 3, CROP_NB = 5;     // beats

    vstream_if #(.T(rgb565_t), .PPC(2)) o0 (.clk(clk), .rst_n(rst_n));
    vstream_if #(.T(rgb565_t), .PPC(2)) o1 (.clk(clk), .rst_n(rst_n));

    logic         start0, start1, busy0, busy1;
    frame_token_t tok0, tok1;
    logic [SEQ_W-1:0] f0, m0, l0, f1, m1, l1;

    vdma_rd #(.FIFO_WORDS(512), .RD_BURST(32)) u_rd0 (
        .m(r_m[0]), .ring(rc[0]), .o(o0),
        .ring_base(RING_TEST_BASE), .start(start0), .policy(ACQ_REPEAT_OK), .geom(geom),
        .x0_beat(8'd0), .nbeats(8'(WPX / BEAT_PIX)),
        .busy(busy0), .token(tok0), .st_frames(f0), .st_miss(m0), .st_late(l0));

    vdma_rd #(.FIFO_WORDS(512), .RD_BURST(32)) u_rd1 (
        .m(r_m[1]), .ring(rc[1]), .o(o1),
        .ring_base(RING_TEST_BASE), .start(start1), .policy(ACQ_NEW_ONLY), .geom(geom),
        .x0_beat(8'(CROP_X0)), .nbeats(8'(CROP_NB)),
        .busy(busy1), .token(tok1), .st_frames(f1), .st_miss(m1), .st_late(l1));

    // reader 0: a "vsync" every PERIOD cycles; reader 1: whenever idle.
    localparam int PERIOD = W_WORDS * H * 2;
    int cyc;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cyc <= 0; start0 <= 0; start1 <= 0; end
        else begin
            cyc    <= (cyc == PERIOD - 1) ? 0 : cyc + 1;
            start0 <= (cyc == PERIOD - 1);
            start1 <= !busy1 && !start1 && ($urandom_range(99) < 5);
        end
    end

    // A reader's acquire, seen at the ring ack, tells its checker which frame
    // the next sof belongs to.
    wire acq0 = rc[0].ack && rc[0].op == RING_C_ACQ && rc[0].ok;
    wire acq1 = rc[1].ack && rc[1].op == RING_C_ACQ && rc[1].ok;

    int fr0, er0, fr1, er1;
    int seen0[$], seen1[$];
    tb_dma_check #(.W_WORDS(W_WORDS), .X0_WORD(0), .H(H), .READY_PCT(80)) u_chk0 (
        .s(o0), .acq(acq0), .acq_frame(int'(rc[0].token.src_seq)),
        .frames(fr0), .errors(er0), .seen(seen0));
    tb_dma_check #(.W_WORDS(CROP_NB * BEAT_PIX / 2), .X0_WORD(CROP_X0 * BEAT_PIX / 2), .H(H),
                   .READY_PCT(50)) u_chk1 (
        .s(o1), .acq(acq1), .acq_frame(int'(rc[1].token.src_seq)),
        .frames(fr1), .errors(er1), .seen(seen1));

    // ------------------------------------------------------------- verdict
    initial begin
        int bad;
        wait (rst_n);
        wait (pdone);
        repeat (PERIOD * 3) @(posedge clk);
        bad = 0;
        foreach (seen0[i]) foreach (short_frames[j]) if (seen0[i] == short_frames[j]) bad++;
        foreach (seen1[i]) foreach (short_frames[j]) if (seen1[i] == short_frames[j]) bad++;
        $display("tb_dma: produced %0d (%0d short), committed %0d, aborted %0d, skipped %0d",
                 FRAMES, short_frames.size(), wr_frames, rstat.aborts, wr_skipped);
        $display("  reader 0 (display): %0d frames checked, %0d misses, %0d late, %0d errors",
                 fr0, m0, l0, er0);
        $display("  reader 1 (crop, new only): %0d frames checked, %0d errors", fr1, er1);
        if (er0 != 0 || er1 != 0 || bad != 0 || rstat.proto_err
            || int'(wr_frames) != FRAMES - short_frames.size()
            || int'(rstat.aborts) != short_frames.size()
            || fr0 < FRAMES / 2 || fr1 < 2)
            $fatal(1, "tb_dma FAIL (short frames shown: %0d)", bad);
        $display("tb_dma PASS");
        $finish;
    end

    initial begin
        #200ms $fatal(1, "tb_dma TIMEOUT");
    end
endmodule
