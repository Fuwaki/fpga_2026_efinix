// proc_stub.sv -- placeholder for a frame-processing accelerator: a stream of
// RGB565 pixel pairs in, the same out, one pair per clock, elastic in both
// directions.
//
//   PROC_PASS    copy
//   PROC_INVERT  every channel inverted
//   PROC_SOBEL   edge strength of luma (sobel8() in vid_pkg), as gray
//
// Sobel needs the neighbours on all sides, but every output beat is produced
// when an input beat arrives, so nothing has to be emitted on its own: output
// pixel (x, y) is centred on input (x - 2, y - 1).  The picture moves right by
// one beat and down by one line; the first beat of each line and the first
// line are black, the last two columns and the last row are dropped.  Missing
// neighbours at the top and left edges are mirrored.  Two lines of luma are
// buffered (one block RAM word per beat holds both).
//
// A real accelerator replaces this module and keeps its ports: frames come in
// and go out framed by sof/eol, back-pressure in both directions.
module proc_stub
    import vid_pkg::*;
#(
    parameter proc_mode_e MODE = PROC_INVERT
) (
    vstream_if.snk   i,      // rgb565_t x 2
    vstream_if.src   o       // rgb565_t x 2
);
    wire clk = i.clk, rst_n = i.rst_n;

    if (MODE != PROC_SOBEL) begin : g_pixel
        function automatic rgb565_t op(input rgb565_t p);
            return (MODE == PROC_INVERT) ? rgb565_t'(~p) : p;
        endfunction

        // One register stage, refilled whenever it is empty or being emptied.
        assign i.ready = !o.valid || o.ready;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                o.valid <= 1'b0;
                o.sof   <= 1'b0;
                o.eol   <= 1'b0;
                o.data  <= '0;
            end else if (i.ready) begin
                o.valid   <= i.valid;
                o.sof     <= i.sof;
                o.eol     <= i.eol;
                o.data[0] <= op(i.data[0]);
                o.data[1] <= op(i.data[1]);
            end
        end
    end else begin : g_sobel
        localparam int BPL = CAM_W / 2;
        localparam int AW  = $clog2(BPL);
        typedef logic [7:0] y_t;

        // Two-stage elastic pipeline: A holds the accepted beat while its
        // line-buffer read completes, B is the output register.
        logic va;
        wire  adv_b = !o.valid || o.ready;
        wire  adv_a = !va || adv_b;
        wire  take  = i.valid && adv_a;
        wire  a2b   = va && adv_b;
        assign i.ready = adv_a;

        // ------------------------------------------------ stage A: count
        logic [AW-1:0] bx_cnt;
        logic [11:0]   k_cnt;
        wire  [AW-1:0] bx_now = i.sof ? '0 : bx_cnt;
        wire  [11:0]   k_now  = i.sof ? '0 : k_cnt;

        logic          sof_a, eol_a;
        logic [AW-1:0] bx_a;
        logic [11:0]   k_a;
        y_t            live_a [2];

        // Line buffer: {row k - 1, row k - 2}, 2 lumas each.
        logic [31:0] lb [1 << AW];
        logic [31:0] lb_q;
        always_ff @(posedge clk)
            if (take) lb_q <= lb[bx_now];

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                va <= 1'b0;
                bx_cnt <= '0; k_cnt <= '0;
                sof_a <= 1'b0; eol_a <= 1'b0; bx_a <= '0; k_a <= '0;
                live_a <= '{default: '0};
            end else begin
                if (take) begin
                    va        <= 1'b1;
                    sof_a     <= i.sof;
                    eol_a     <= i.eol;
                    bx_a      <= bx_now;
                    k_a       <= k_now;
                    live_a[0] <= luma8(i.data[0]);
                    live_a[1] <= luma8(i.data[1]);
                    if (i.eol) begin
                        bx_cnt <= '0;
                        k_cnt  <= (k_now == 12'hFFF) ? k_now : k_now + 1'b1;
                    end else begin
                        bx_cnt <= (bx_now == AW'(BPL - 1)) ? bx_now : bx_now + 1'b1;
                        k_cnt  <= k_now;
                    end
                end else if (a2b) begin
                    va <= 1'b0;
                end
            end
        end

        // ------------------------------------------- stage B: window, out
        y_t row1 [2], row2 [2];               // rows k - 1, k - 2 of this beat
        // Word layout {row1[1], row1[0], row2[1], row2[0]}; element 0 is listed
        // first in an unpacked literal.
        assign row1 = '{lb_q[23:16], lb_q[31:24]};
        assign row2 = '{lb_q[7:0],   lb_q[15:8]};

        always_ff @(posedge clk)
            if (a2b) lb[bx_a] <= {live_a[1], live_a[0], row1[1], row1[0]};

        // The beat's column of three rows: [row][pixel], row 0 on top.
        y_t n [3][2];
        always_comb begin
            for (int p = 0; p < 2; p++) begin
                n[0][p] = (k_a == 12'd1) ? live_a[p] : row2[p];   // row -1 mirrors row 1
                n[1][p] = row1[p];
                n[2][p] = live_a[p];
            end
        end

        y_t cur [3][2], prv [3][2];           // beats b - 1 and b - 2
        logic cur_first;                      // beat b - 1 is the first of its line

        // Output for beat b - 1: pixels from prv[.][1] | cur | n[.][0].
        function automatic y_t win(input y_t l [3], input y_t c [3], input y_t r [3]);
            y_t w [3][3];
            for (int y = 0; y < 3; y++) begin
                w[y][0] = l[y];
                w[y][1] = c[y];
                w[y][2] = r[y];
            end
            return sobel8(w);
        endfunction

        y_t c0 [3], c1 [3], l0 [3], r1 [3];
        always_comb
            for (int y = 0; y < 3; y++) begin
                c0[y] = cur[y][0];
                c1[y] = cur[y][1];
                l0[y] = cur_first ? cur[y][1] : prv[y][1];
                r1[y] = n[y][0];
            end

        wire y_t e0 = win(l0, c0, c1);
        wire y_t e1 = win(c0, c1, r1);
        wire     black = (bx_a == '0) || (k_a == '0);

        function automatic rgb565_t gray(input y_t v);
            return pack565('{r: v, g: v, b: v});
        endfunction

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                o.valid <= 1'b0;
                o.sof   <= 1'b0;
                o.eol   <= 1'b0;
                o.data  <= '0;
                for (int y = 0; y < 3; y++)
                    for (int p = 0; p < 2; p++) begin
                        cur[y][p] <= '0;
                        prv[y][p] <= '0;
                    end
                cur_first <= 1'b0;
            end else begin
                if (o.valid && o.ready)
                    o.valid <= 1'b0;
                if (a2b) begin
                    o.valid   <= 1'b1;
                    o.sof     <= sof_a;
                    o.eol     <= eol_a;
                    o.data[0] <= black ? '0 : gray(e0);
                    o.data[1] <= black ? '0 : gray(e1);
                    prv       <= cur;
                    cur       <= n;
                    cur_first <= (bx_a == '0);
                end
            end
        end
    end
endmodule
