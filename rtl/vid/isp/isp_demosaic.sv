// isp_demosaic.sv -- bilinear demosaic, 2 pixels per clock.
//
// Output line k is centred on input row k - 1, emitted while input row k
// arrives, so the stage never has to produce a line on its own: line 0 is
// black, the picture moves down one row and the sensor's last row is dropped
// (see demosaic() in sim/ref/isp_ref.py).  Missing neighbours are mirrored.
//
// Rows: the live input (row k) and one line buffer holding rows k - 1 and
// k - 2 side by side, read before it is overwritten.  Columns: a beat is
// emitted when the next one arrives, so both horizontal neighbours are known;
// the last beat of a line goes out in the first blanking cycle, which the
// vpush_if contract guarantees.  Gaps inside a line are allowed.
module isp_demosaic
    import vid_pkg::*;
(
    vpush_if.snk     i,      // raw10_t x 2, after black level and white balance
    vpush_if.src     o,      // rgb10_t x 2
    input isp_cfg_t  cfg
);
    localparam int BPL = CAM_W / 2;          // beats per line
    localparam int AW  = $clog2(BPL);

    wire clk = i.clk, rst_n = i.rst_n;

    typedef logic [9:0] px_t;
    // Three rows of one beat: [row][element], row 0 = up, 1 = centre, 2 = down.
    typedef px_t [2:0][1:0] col3_t;

    // ---------------------------------------------------- stage 0: count
    logic [AW-1:0] bx_cnt;
    logic [11:0]   k_cnt;
    wire  [AW-1:0] bx_now = i.sof ? '0 : bx_cnt;
    wire  [11:0]   k_now  = i.sof ? '0 : k_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bx_cnt <= '0;
            k_cnt  <= '0;
        end else if (i.valid) begin
            if (i.eol) begin
                bx_cnt <= '0;
                if (k_now != 12'hFFF)
                    k_cnt <= k_now + 1'b1;
            end else begin
                bx_cnt <= (bx_now == AW'(BPL - 1)) ? bx_now : bx_now + 1'b1;
                k_cnt  <= k_now;
            end
        end
    end

    // Line buffer: word = {row k - 1, row k - 2}, 2 pixels each.
    logic [39:0] lb [1 << AW];
    logic [39:0] lb_q;
    always_ff @(posedge clk)
        if (i.valid) lb_q <= lb[bx_now];

    // ---------------------------------------------- stage 1: pick rows
    logic          v1, eol1;
    logic [AW-1:0] bx1;
    logic [11:0]   k1;
    px_t [1:0]     live1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {v1, eol1} <= '0;
            bx1   <= '0;
            k1    <= '0;
            live1 <= '0;
        end else begin
            v1    <= i.valid;
            eol1  <= i.valid && i.eol;
            bx1   <= bx_now;
            k1    <= k_now;
            live1 <= i.data;
        end
    end

    px_t [1:0] row_a, row_b;          // rows k - 1 and k - 2
    assign row_a = lb_q[39:20];
    assign row_b = lb_q[19:0];

    always_ff @(posedge clk)
        if (v1) lb[bx1] <= {live1, row_a};

    col3_t n1;                        // the beat's three rows
    assign n1[0] = (k1 == 12'd1) ? live1 : row_b;   // row -1 mirrors to row 1
    assign n1[1] = row_a;
    assign n1[2] = live1;

    // --------------------------------------------- stage 2: column window
    col3_t       cur, prev;
    logic        cur_first, pend;
    logic [11:0] cur_k;

    logic        e_v, e_first, e_last;    // emission
    col3_t       e_prev, e_cur, e_next;
    logic [11:0] e_k;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur <= '0; prev <= '0;
            cur_first <= 1'b0; pend <= 1'b0; cur_k <= '0;
            e_v <= 1'b0; e_first <= 1'b0; e_last <= 1'b0;
            e_prev <= '0; e_cur <= '0; e_next <= '0; e_k <= '0;
        end else begin
            e_v <= 1'b0;
            if (v1) begin
                if (bx1 != '0) begin
                    e_v     <= 1'b1;
                    e_first <= cur_first;
                    e_last  <= 1'b0;
                    e_prev  <= prev;
                    e_cur   <= cur;
                    e_next  <= n1;
                    e_k     <= cur_k;
                end
                prev      <= cur;
                cur       <= n1;
                cur_first <= (bx1 == '0);
                cur_k     <= k1;
                pend      <= eol1;
            end else if (pend) begin
                e_v     <= 1'b1;
                e_first <= cur_first;
                e_last  <= 1'b1;
                e_prev  <= prev;
                e_cur   <= cur;
                e_next  <= cur;               // unused: mirrored below
                e_k     <= cur_k;
                pend    <= 1'b0;
            end
        end
    end

    // ------------------------------------------------ stage 3: interpolate
    // Centre row c = k - 1; its parity is !k[0].
    wire c_par = !e_k[0];
    wire r_row = (c_par == cfg.cfa_r[1]);

    function automatic rgb10_t interp(input px_t ul, input px_t uc, input px_t ur,
                                      input px_t cl, input px_t cc, input px_t cr,
                                      input px_t dl, input px_t dc, input px_t dr,
                                      input logic [1:0] colour, input logic on_r_row);
        logic [11:0] cr4, dg4;      // cross and diagonal sums
        logic [10:0] hor, ver;
        rgb10_t      p;
        cr4   = 12'(cl) + 12'(cr) + 12'(uc) + 12'(dc);
        dg4   = 12'(ul) + 12'(ur) + 12'(dl) + 12'(dr);
        hor   = 11'(cl) + 11'(cr);
        ver   = 11'(uc) + 11'(dc);
        unique case (colour)
            2'd0:    p = '{r: cc, g: cr4[11:2], b: dg4[11:2]};
            2'd2:    p = '{r: dg4[11:2], g: cr4[11:2], b: cc};
            default: p = on_r_row ? '{r: hor[10:1], g: cc, b: ver[10:1]}
                                  : '{r: ver[10:1], g: cc, b: hor[10:1]};
        endcase
        return p;
    endfunction

    function automatic logic [1:0] colour(input logic p, input logic e, input logic [1:0] cfa_r);
        if (p == cfa_r[1] && e == cfa_r[0]) return 2'd0;
        if (p != cfa_r[1] && e != cfa_r[0]) return 2'd2;
        return 2'd1;
    endfunction

    // Neighbours per row: element 0 sees (prev.1 | mirror cur.1), cur.0, cur.1;
    // element 1 sees cur.0, cur.1, (next.0 | mirror cur.0).
    px_t l0 [3], r1 [3];
    always_comb
        for (int y = 0; y < 3; y++) begin
            l0[y] = e_first ? e_cur[y][1] : e_prev[y][1];
            r1[y] = e_last  ? e_cur[y][0] : e_next[y][0];
        end

    rgb10_t q0, q1;
    assign q0 = interp(l0[0], e_cur[0][0], e_cur[0][1],
                       l0[1], e_cur[1][0], e_cur[1][1],
                       l0[2], e_cur[2][0], e_cur[2][1],
                       colour(c_par, 1'b0, cfg.cfa_r), r_row);
    assign q1 = interp(e_cur[0][0], e_cur[0][1], r1[0],
                       e_cur[1][0], e_cur[1][1], r1[1],
                       e_cur[2][0], e_cur[2][1], r1[2],
                       colour(c_par, 1'b1, cfg.cfa_r), r_row);

    wire black = (e_k == '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o.valid <= 1'b0;
            o.sof   <= 1'b0;
            o.eol   <= 1'b0;
            o.data  <= '0;
        end else begin
            o.valid   <= e_v;
            o.sof     <= e_v && black && e_first;
            o.eol     <= e_v && e_last;
            o.data[0] <= black ? '0 : q0;
            o.data[1] <= black ? '0 : q1;
        end
    end

endmodule
