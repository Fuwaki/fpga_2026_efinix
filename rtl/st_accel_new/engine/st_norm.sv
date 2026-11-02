// st_norm.sv -- the ST block engine's norm stage: LayerNorm and the FiLM
// affine as one group-stream stage (docs/st-guided-adr.md).
//
// Stream format (both sides): *_valid, *_ready, *_data[39:0] (4 lanes of
// 10-bit signed, lane j = bits [10j+9:10j]), *_last (last group beat of a
// pixel), *_eol (last beat of a line), *_sof (first beat of a frame).  A
// pixel is G = ceil(C/4) group beats, group 0 first, pixels in raster order;
// lanes beyond C are zero.  One beat per cycle is sustained in both modes
// with full back-pressure: a beat is held until it is accepted, and no beat
// is lost, duplicated or reordered.  A pixel's sof and eol are ORed over its
// input beats and placed on its first and last output beat, as in st_pw.
//
// Configuration is sampled on a one-cycle start pulse while idle; busy stays
// high until the last output beat has been accepted:
//
//   cfg_mode  1 LN, 2 FILM
//   cfg_g     groups per pixel: 8..20 in LN mode (20 for C = 80), 1..20 FILM
//   cfg_npix  pixels of the pass
//
// FiLM coefficients are written while idle through coef_we / coef_idx
// (channel 0..79) / coef_mul / coef_off, one channel per cycle.
//
// ------------------------------------------------------------------- LN
// Per pixel, N = 4*cfg_g channels, x the int9 codes (tools/st_guided.py
// ln_int, which is normative):
//
//   S = sum x, Q = sum x^2, D = N*Q - S^2 + E        (E = LN_E = 1)
//   e = (bitlen(D) + 1) >> 1,  m = D << (10 - 2e) or D >> (2e - 10)
//   R = LUT[m - 256]                                (768 x 17, st_ln_lut.hex)
//   per channel: u = N*x - S
//                t = (u*R + 2^(e+2)) >>> (e+3)
//                y = clamp((t*G_c + B_c + 2^21) >>> 22, -127, 127)
//
// G_c and B_c come from st_ln.hex, one word per channel.
//
// ------------------------------------------------------------- structure
// collect   the beats of pixel p go into a pixel buffer (four slots by pixel
//           mod 4, 20 beats x 40 bit, one block RAM) while S and Q accumulate
//           over the four lanes; the lane squares are mul_nodsp, not DSP.
// compute   once per pixel, three cycles after its last beat: S^2 on one DSP,
//           N*Q = (G*Q) << 2 by shift-add, D, a leading-one detector for e,
//           a barrel shift for m and the LUT ROM for R.  The parameters go
//           to the pixel's slot of four, so the compute of pixel p runs while
//           p+1 collects and p-1 emits.
// emit      reads the pixel's beats back, u = N*x - S (one 5x10 mul_nodsp
//           per lane: x enters as its 10-bit pattern x+1024, so
//           G*x = G*x_u - (G << 10) and N*x = (G*x) << 2), p1 = u*R on four
//           DSP, t, then the shared affine.  R, e and S travel in the emit
//           pipeline; the per-pixel registers are free for the next pixel.
// affine    p2 = t*G_c + B_c + 2^21, y = clamp(p2 >>> 22) in LN; in FILM
//           t = x with (mul_c, off_c, 15) instead: p2 = x*mul_c + off_c +
//           2^14.  Four DSP in both modes -- the same four multipliers.
// output    OUT_DEPTH-beat FIFO in block RAM, credit-checked at issue, so no
//           fixed-latency pipeline is ever back-pressured.  In FILM the
//           credit also gates the input, which has no buffer of its own.
//
// DSP: 4 u*R, 4 affine, 1 S^2 = 9.  RAM10: LN coefficient ROM 4 banks x 32 x
// 48 bit (20), FiLM coefficient banks 4 x 32 x 48 (20), R LUT 768 x 17 (2),
// pixel buffer 128 x 40 (4), output FIFO 16 x 43 (5).  The two coefficient
// tables are separate because one is a constant ROM and the other is
// written through the coefficient port; the banks cannot be shared.
//
// Pipelining.  Pixel p collects in cycles C..C+G-1 and emits in
// C+G+3..C+2G+2, so the collect of p+1 (C+G..C+2G-1) overlaps the compute of
// p and the collect of p+2 (C+2G..) overlaps the emit of p.  Four buffer
// slots keep the collecting pixel off the slot of any pixel in flight, and
// at most three pixels are in flight (in_ready low at inflight = 3), so the
// buffer needs no read/write guard: G >= 4 would suffice, and LN mode checks
// the stricter G >= 8 the timing above assumes.
module st_norm #(
    parameter int    OUT_DEPTH = 16,        // output beats in the FIFO
    parameter string LN_HEX    = "rtl/st_accel_new/gen/guided/st_ln.hex",
    parameter string LUT_HEX   = "rtl/st_accel_new/gen/guided/st_ln_lut.hex"
) (
    input  logic         clk,
    input  logic         rst_n,

    // group stream in
    input  logic         in_valid,
    output logic         in_ready,
    input  logic [39:0]  in_data,       // 4 int9 lanes in 10-bit fields
    input  logic         in_last,
    input  logic         in_eol,
    input  logic         in_sof,

    // group stream out
    output logic         out_valid,
    input  logic         out_ready,
    output logic [39:0]  out_data,
    output logic         out_last,
    output logic         out_eol,
    output logic         out_sof,

    // one-cycle start pulse while idle; busy until the last beat is accepted
    input  logic         start,
    output logic         busy,

    // configuration, sampled on start
    input  logic [1:0]   cfg_mode,      // 1 LN, 2 FILM
    input  logic [4:0]   cfg_g,         // groups per pixel
    input  logic [17:0]  cfg_npix,      // pixels of the pass

    // FiLM coefficient write port, while idle
    input  logic         coef_we,
    input  logic [6:0]   coef_idx,      // channel
    input  logic [17:0]  coef_mul,
    input  logic [23:0]  coef_off
);
    localparam int MODE_LN   = 1;
    localparam int MODE_FILM = 2;

    localparam int GMAX      = 20;          // groups per pixel
    localparam int GBITS     = 5;           // 0 .. 19
    localparam int NB        = 4;           // coefficient banks = lanes
    localparam int BW        = 32;          // words per coefficient bank
    localparam int CW        = 48;          // {3'b0, B/off[26:0], G/mul[17:0]}
    localparam int PB_AW     = 7;           // 4 slots x 32 beats
    localparam int LUT_DEPTH = 768;
    localparam int LN_E      = 1;           // D = N*Q - S^2 + LN_E
    localparam int SH_LN     = 22;          // affine shift, LN
    localparam int SH_FILM   = 15;          // affine shift, FILM
    localparam int OF_AW     = $clog2(OUT_DEPTH);
    localparam int FW        = 43;          // FIFO word: sof, eol, last, data

    // ------------------------------------------------------- configuration
    logic [1:0] mode_r;
    logic [4:0] g_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_r <= 2'd0;
            g_r    <= 5'd0;
        end else if (start) begin
            mode_r <= cfg_mode;
            g_r    <= cfg_g;
        end
    end

    wire ln_mode = (mode_r == 2'(MODE_LN));

    // ---------------------------------------------------- coefficient ROMs
    // One 48-bit word per channel: [44:18] B_c / off_c (27-bit signed),
    // [17:0] G_c / mul_c (18-bit signed).  Bank b word a holds channel
    // 4a + b, so one read returns the four channels of a group beat.  The LN
    // image is loaded once from LN_HEX; the FiLM banks are written through
    // the coefficient port.
    logic [CW-1:0] ln_img [NB*BW];
    logic [CW-1:0] ln_bank [NB][BW];
    logic [CW-1:0] fm_bank [NB][BW];
    logic [CW-1:0] ln_q [NB];
    logic [CW-1:0] fm_q [NB];
    logic [GBITS-1:0] coef_addr;

    initial begin
        for (int i = 0; i < NB * BW; i++) ln_img[i] = '0;
        $readmemh(LN_HEX, ln_img);
        for (int b = 0; b < NB; b++) begin
            for (int a = 0; a < BW; a++) begin
                ln_bank[b][a] = (a < GMAX) ? ln_img[NB*a + b] : '0;
                fm_bank[b][a] = '0;
            end
        end
    end

    always_ff @(posedge clk) begin
        for (int b = 0; b < NB; b++) begin
            if (coef_we && (coef_idx[1:0] == 2'(b)))
                fm_bank[b][coef_idx[6:2]] <= {3'b000,
                                              {3{coef_off[23]}}, coef_off,
                                              coef_mul};
            ln_q[b] <= ln_bank[b][coef_addr];
            fm_q[b] <= fm_bank[b][coef_addr];
        end
    end

    logic [CW-1:0]      coef_q [NB];
    logic signed [17:0] coef_mul_q [NB];
    logic signed [26:0] coef_off_q [NB];

    always_comb
        for (int b = 0; b < NB; b++) begin
            coef_q[b]     = ln_mode ? ln_q[b] : fm_q[b];
            coef_mul_q[b] = $signed(coef_q[b][17:0]);
            coef_off_q[b] = $signed(coef_q[b][44:18]);
        end

    // --------------------------------------------------------- R LUT (LN)
    logic [16:0] lut_mem [LUT_DEPTH];
    logic [16:0] lut_q;
    logic [9:0]  lut_addr;

    initial begin
        for (int i = 0; i < LUT_DEPTH; i++) lut_mem[i] = '0;
        $readmemh(LUT_HEX, lut_mem);
    end

    always_ff @(posedge clk) lut_q <= lut_mem[lut_addr];

    // ------------------------------------------------------------ pointers
    logic [17:0] pix_in_left;
    logic [17:0] pix_out_left;
    logic [1:0]  p_col;                 // pixel being collected, mod 4
    logic [1:0]  p_emit;                // pixel being emitted, mod 4
    logic [GBITS-1:0] beat_cnt;         // group beat of the pixel, 0..G-1
    logic        col_sof, col_eol;

    logic signed [16:0] acc_s;          // running sum of the pixel in collect
    logic [23:0]        acc_q;          // running sum of squares
    logic signed [16:0] tot_s [2];      // the pixel's totals, captured at last
    logic [23:0]        tot_q [2];      // (index = pixel parity)

    // ------------------------------------------------------- pixel buffer
    // Four slots, one per pixel mod 4: the pixel being collected (p_col) and
    // the three in flight behind it (p_emit .. p_emit+2) never share a slot,
    // so a write can never race the read of the same address and the collect
    // side needs no pointer guard.
    logic [39:0]      pix_ram [4*BW];
    logic [39:0]      pb_q;
    logic             pb_we;
    logic [PB_AW-1:0] pb_raddr;

    initial
        for (int i = 0; i < 4 * BW; i++) pix_ram[i] = '0;

    always_ff @(posedge clk) begin
        if (pb_we)    pix_ram[{p_col[1:0], beat_cnt}] <= in_data;
        if (em_issue) pb_q <= pix_ram[pb_raddr];
    end

    // ------------------------------------------------------ output credit
    logic [4:0]  of_level;
    logic        of_rvalid, of_wfull;
    logic [4:0]  pend;                  // beats issued, not yet in the FIFO
    wire  [6:0]  of_used = 7'(of_level) + 7'(of_rvalid) + 7'(pend);
    wire         credit  = (of_used < 7'(OUT_DEPTH));

    // ------------------------------------------------------- lane squares
    logic signed [9:0] in_lane [4];
    logic [8:0]        in_mag  [4];
    logic [17:0]       in_sq   [4];

    for (genvar j = 0; j < 4; j++) begin : g_sq
        assign in_lane[j] = $signed(in_data[10*j +: 10]);
        assign in_mag[j]  = in_lane[j][9] ? 9'(-in_lane[j]) : 9'(in_lane[j]);
        wire [17:0] p;
        mul_nodsp #(.AW(9), .BW(9)) u_sq (.a(in_mag[j]), .b(in_mag[j]), .p(p));
        assign in_sq[j] = p;
    end

    wire signed [12:0] beat_sum = 13'(in_lane[0]) + 13'(in_lane[1])
                                + 13'(in_lane[2]) + 13'(in_lane[3]);
    wire [19:0]        beat_sq  = 20'(in_sq[0]) + 20'(in_sq[1])
                                + 20'(in_sq[2]) + 20'(in_sq[3]);

    // --------------------------------------------------------- emit state
    logic             em_act;
    logic [GBITS-1:0] em_beat;
    logic signed [16:0] par_s [4];
    logic signed [16:0] par_r [4];
    logic [4:0]         par_e [4];
    logic               par_sof [4], par_eol [4];
    logic               par_rdy [4];        // parameters of that slot are valid

    wire [1:0] par_i     = p_emit[1:0];
    // pixels collected and not yet emitted, the emitting one included
    wire [1:0] inflight  = 2'(p_col - p_emit);

    wire in_accept = in_valid && in_ready;

    // Three pending pixels are the most the four buffer slots and the four
    // parameter slots can hold: p_emit, p_emit+1, p_emit+2 and the one being
    // collected.  A fourth would reuse p_emit's slot.
    assign in_ready = busy && (pix_in_left != 18'd0)
                   && (ln_mode ? (inflight != 2'd3) : credit);

    // --------------------------------------------------------- emit issue
    wire        par_ready = ln_mode && par_rdy[par_i];
    wire        em_issue  = busy && ln_mode && credit
                         && (em_act || par_ready);
    wire        em_last_b = (em_beat == 5'(g_r - 5'd1));
    wire [2:0]  em_flags  = {par_sof[par_i] && (em_beat == 5'd0),
                             par_eol[par_i] && em_last_b,
                             em_last_b};

    assign pb_we    = in_accept && ln_mode;
    assign pb_raddr = {par_i[1:0], em_beat};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            em_act  <= 1'b0;
            em_beat <= 5'd0;
            p_emit  <= 2'd0;
        end else if (start) begin
            em_act  <= 1'b0;
            em_beat <= 5'd0;
            p_emit  <= 2'd0;
        end else if (em_issue) begin
            if (em_last_b) begin
                em_act          <= 1'b0;
                em_beat         <= 5'd0;
                p_emit          <= p_emit + 2'd1;
                par_rdy[par_i]  <= 1'b0;
            end else begin
                em_act  <= 1'b1;
                em_beat <= em_beat + 5'd1;
            end
        end
    end

    // ------------------------------------------------------ collect state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_in_left  <= 18'd0;
            pix_out_left <= 18'd0;
            p_col        <= 2'd0;
            beat_cnt     <= 5'd0;
            col_sof      <= 1'b0;
            col_eol      <= 1'b0;
            acc_s        <= 17'sd0;
            acc_q        <= 24'd0;
            for (int k = 0; k < 2; k++) begin
                tot_s[k] <= 17'sd0;
                tot_q[k] <= 24'd0;
            end
        end else if (start) begin
            pix_in_left  <= cfg_npix;
            pix_out_left <= cfg_npix;
            p_col        <= 2'd0;
            beat_cnt     <= 5'd0;
            col_sof      <= 1'b0;
            col_eol      <= 1'b0;
            acc_s        <= 17'sd0;
            acc_q        <= 24'd0;
            for (int k = 0; k < 2; k++) begin
                tot_s[k] <= 17'sd0;
                tot_q[k] <= 24'd0;
            end
        end else begin
            if (in_accept) begin
                // the totals are captured at the last beat, so the next
                // pixel's collect may start in the very next cycle
                if (ln_mode) begin
                    acc_s <= (beat_cnt == 5'd0) ? 17'(beat_sum)
                                                : acc_s + 17'(beat_sum);
                    acc_q <= (beat_cnt == 5'd0) ? 24'(beat_sq)
                                                : acc_q + 24'(beat_sq);
                    col_sof <= col_sof | in_sof;
                    col_eol <= col_eol | in_eol;
                    if (in_last) begin
                        tot_s[p_col[0]] <= (beat_cnt == 5'd0)
                                         ? 17'(beat_sum) : acc_s + 17'(beat_sum);
                        tot_q[p_col[0]] <= (beat_cnt == 5'd0)
                                         ? 24'(beat_sq) : acc_q + 24'(beat_sq);
                        col_sof <= 1'b0;
                        col_eol <= 1'b0;
                    end
                end
                beat_cnt <= in_last ? 5'd0 : beat_cnt + 5'd1;
                if (in_last) begin
                    pix_in_left <= pix_in_left - 18'd1;
                    if (ln_mode) p_col <= p_col + 2'd1;
                end
            end
            if (s5_v && s5_f[0]) pix_out_left <= pix_out_left - 18'd1;
        end
    end

    // ================================================== LN per-pixel compute
    // T = the cycle the pixel's last beat is accepted.
    //   T+1  S^2 on a DSP, N*Q = (G*Q) << 2 by shift-add, S captured
    //   T+2  D, e by a leading-one detector, m by a barrel shift, LUT address
    //   T+3  R from the ROM; the pixel's parameters go to its slot
    // The totals are captured in the collect block at T, so they are stable
    // in cm1 even when the next pixel's beat 0 arrives at T+1.
    logic               cm1_v, cm2_v, cm3_v;
    logic signed [33:0] s2_q;
    logic [30:0]        nq_q;
    logic signed [16:0] s_cap;
    logic [4:0]         e_cap;
    logic [1:0]         px_par;
    logic               cm_par;         // parity of the pixel in cm1_v
    logic               px_sof_r, px_eol_r;

    function automatic logic [5:0] bitlen34(input logic [33:0] v);
        bitlen34 = 6'd0;
        for (int k = 0; k < 34; k++)
            if (v[k]) bitlen34 = 6'(k + 1);
    endfunction

    // G*Q by shifts: G <= 20, five partial products
    logic [28:0] gq;
    always_comb begin
        gq = 29'd0;
        for (int k = 0; k < 5; k++)
            if (g_r[k]) gq = gq + (29'(tot_q[cm_par]) << k);
    end

    wire [33:0] d_w   = 34'(nq_q) - 34'(s2_q) + 34'(LN_E);
    wire [5:0]  bl_w  = bitlen34(d_w);
    wire [4:0]  e_w   = 5'((bl_w + 6'd1) >> 1);
    wire [5:0]  sh2_w = {1'b0, e_w} << 1;
    wire [4:0]  lsh_w = (sh2_w <= 6'd10) ? 5'(6'd10 - sh2_w) : 5'd0;
    wire [4:0]  rsh_w = (sh2_w >  6'd10) ? 5'(sh2_w - 6'd10) : 5'd0;
    wire [33:0] m_w   = (sh2_w <= 6'd10) ? (d_w << lsh_w) : (d_w >> rsh_w);
    wire [9:0]  idx_w = m_w[9:0] - 10'd256;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cm1_v    <= 1'b0;
            cm2_v    <= 1'b0;
            cm3_v    <= 1'b0;
            s2_q     <= '0;
            nq_q     <= '0;
            s_cap    <= '0;
            e_cap    <= '0;
            lut_addr <= '0;
            px_par   <= 2'd0;
            cm_par   <= 1'b0;
            px_sof_r <= 1'b0;
            px_eol_r <= 1'b0;
            for (int k = 0; k < 4; k++) begin
                par_s[k]   <= '0;
                par_r[k]   <= '0;
                par_e[k]   <= '0;
                par_sof[k] <= 1'b0;
                par_eol[k] <= 1'b0;
                par_rdy[k] <= 1'b0;
            end
        end else if (start) begin
            cm1_v <= 1'b0;
            cm2_v <= 1'b0;
            cm3_v <= 1'b0;
        end else begin
            cm1_v <= ln_mode && in_accept && in_last;
            cm2_v <= cm1_v;
            cm3_v <= cm2_v;
            if (ln_mode && in_accept && in_last) begin
                px_par   <= p_col[1:0];
                cm_par   <= p_col[0];
                px_sof_r <= col_sof | in_sof;
                px_eol_r <= col_eol | in_eol;
            end
            if (cm1_v) begin
                s2_q  <= tot_s[cm_par] * tot_s[cm_par];
                nq_q  <= 31'(gq) << 2;
                s_cap <= tot_s[cm_par];
            end
            if (cm2_v) begin
                lut_addr <= idx_w;
                e_cap    <= e_w;
            end
            if (cm3_v) begin
                par_s[px_par]   <= s_cap;
                par_r[px_par]   <= 17'(lut_q);
                par_e[px_par]   <= e_cap;
                par_sof[px_par] <= px_sof_r;
                par_eol[px_par] <= px_eol_r;
                par_rdy[px_par] <= 1'b1;
            end
        end
    end

    // ================================================== emit / FILM pipeline
    // s1  pixel buffer read data (LN) / the input beat (FILM)
    // s2  u = N*x - S (LN)
    // s3  p1 = u*R (LN)
    // s4  affine operands: t and the coefficient word
    // s5  affine product; the FIFO write is in this cycle
    logic             s1_v, s2_v, s3_v, s4_v, s5_v;
    logic [2:0]       s1_f, s2_f, s3_f, s4_f, s5_f;
    logic [GBITS-1:0] s1_g, s2_g, s3_g;
    logic signed [16:0] s1_s, s1_r, s2_r;
    logic [4:0]       s1_e, s2_e, s3_e, s4_sh, s5_sh;
    logic signed [17:0] s2_u [4];
    logic signed [35:0] s3_pq [4];
    logic signed [17:0] s4_t [4];
    logic signed [17:0] s4_c [4];
    logic signed [26:0] s4_o [4];
    logic signed [35:0] s5_p [4];
    logic signed [26:0] s5_o [4];
    logic signed [17:0] f1_x [4];
    logic             f1_v;
    logic [2:0]       f1_f;
    logic [GBITS-1:0] f1_g;             // group of the beat in f1

    // ---- FILM input register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f1_v <= 1'b0;
            f1_f <= '0;
            f1_g <= '0;
            for (int j = 0; j < 4; j++) f1_x[j] <= '0;
        end else if (start) begin
            f1_v <= 1'b0;
        end else begin
            f1_v <= in_accept && !ln_mode;
            if (in_accept && !ln_mode) begin
                f1_f <= {in_sof, in_eol, in_last};
                f1_g <= beat_cnt;
                for (int j = 0; j < 4; j++) f1_x[j] <= 18'(in_lane[j]);
            end
        end
    end

    // ---- LN issue: pixel buffer read, per-pixel values into the pipeline
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_v <= 1'b0;
            s1_f <= '0;
            s1_g <= '0;
            s1_s <= '0;
            s1_r <= '0;
            s1_e <= '0;
        end else if (start) begin
            s1_v <= 1'b0;
        end else begin
            s1_v <= em_issue;
            if (em_issue) begin
                s1_f <= em_flags;
                s1_g <= em_beat;
                s1_s <= par_s[par_i];
                s1_r <= par_r[par_i];
                s1_e <= par_e[par_i];
            end
        end
    end

    // ---- s1 -> s2: u = N*x - S per lane
    // mul_nodsp is unsigned: x enters as its 10-bit pattern x_u = x + 1024, so
    // G*x = G*x_u - (G << 10) and N*x = (G*x) << 2.
    logic signed [17:0] u_w [4];
    for (genvar j = 0; j < 4; j++) begin : g_u
        wire [14:0] gp;
        wire signed [17:0] nx, n1024, sx;
        mul_nodsp #(.AW(5), .BW(10)) u_mul (
            .a(g_r), .b(pb_q[10*j +: 10]), .p(gp));
        assign nx    = $signed({1'b0, gp, 2'b00});
        assign n1024 = $signed({1'b0, g_r, 12'b0});
        assign sx    = $signed({{1{s1_s[16]}}, s1_s});
        assign u_w[j] = nx - n1024 - sx;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_v <= 1'b0;
            s2_r <= '0;
            s2_e <= '0;
            s2_g <= '0;
            s2_f <= '0;
            for (int j = 0; j < 4; j++) s2_u[j] <= '0;
        end else if (start) begin
            s2_v <= 1'b0;
        end else begin
            s2_v <= s1_v;
            if (s1_v) begin
                s2_r <= s1_r;
                s2_e <= s1_e;
                s2_g <= s1_g;
                s2_f <= s1_f;
                for (int j = 0; j < 4; j++) s2_u[j] <= u_w[j];
            end
        end
    end

    // ---- s2 -> s3: p1 = u*R, four DSP
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_v <= 1'b0;
            s3_e <= '0;
            s3_g <= '0;
            s3_f <= '0;
            for (int j = 0; j < 4; j++) s3_pq[j] <= '0;
        end else if (start) begin
            s3_v <= 1'b0;
        end else begin
            s3_v <= s2_v;
            if (s2_v) begin
                s3_e <= s2_e;
                s3_g <= s2_g;
                s3_f <= s2_f;
                for (int j = 0; j < 4; j++)
                    s3_pq[j] <= s2_u[j] * $signed({1'b0, s2_r});
            end
        end
    end

    // ---- t = (u*R + 2^(e+2)) >>> (e+3)   (LN);  x in FILM
    logic signed [17:0] t_w [4];
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            logic signed [35:0] p1, rnd;
            p1  = s3_pq[j];
            rnd = 36'sd1 << (s3_e + 5'd2);
            t_w[j] = 18'((p1 + rnd) >>> (s3_e + 5'd3));
        end
    end

    // ---- s4: affine operands, shared by both modes
    wire        s4_src_v = ln_mode ? s3_v : f1_v;
    wire [2:0]  s4_src_f = ln_mode ? s3_f : f1_f;

    // The ROM output is registered, so the address presented now is the one
    // whose data the affine takes in the next cycle: the group of the beat in
    // s4 (LN: one stage behind s2_g, FILM: the beat in f1).
    assign coef_addr = ln_mode ? s3_g : f1_g;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_v  <= 1'b0;
            s4_sh <= 5'(SH_LN);
            s4_f  <= '0;
            for (int j = 0; j < 4; j++) begin
                s4_t[j] <= '0;
                s4_c[j] <= '0;
                s4_o[j] <= '0;
            end
        end else if (start) begin
            s4_v <= 1'b0;
        end else begin
            s4_v <= s4_src_v;
            if (s4_src_v) begin
                s4_sh <= ln_mode ? 5'(SH_LN) : 5'(SH_FILM);
                s4_f  <= s4_src_f;
                for (int j = 0; j < 4; j++) begin
                    s4_t[j] <= ln_mode ? t_w[j] : f1_x[j];
                    s4_c[j] <= coef_mul_q[j];
                    s4_o[j] <= coef_off_q[j];
                end
            end
        end
    end

    // ---- s5: p2 = t*coef, four DSP
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5_v  <= 1'b0;
            s5_sh <= 5'(SH_LN);
            s5_f  <= '0;
            for (int j = 0; j < 4; j++) begin
                s5_p[j] <= '0;
                s5_o[j] <= '0;
            end
        end else if (start) begin
            s5_v <= 1'b0;
        end else begin
            s5_v <= s4_v;
            if (s4_v) begin
                s5_sh <= s4_sh;
                s5_f  <= s4_f;
                for (int j = 0; j < 4; j++) begin
                    s5_p[j] <= s4_t[j] * s4_c[j];
                    s5_o[j] <= s4_o[j];
                end
            end
        end
    end

    // ---- sum, shift, clamp
    logic [39:0] y_w;
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            logic signed [37:0] sum, rnd, y;
            rnd = 38'sd1 << (s5_sh - 5'd1);
            sum = 38'(s5_p[j]) + 38'(s5_o[j]) + rnd;
            y   = sum >>> s5_sh;
            if (y > 38'sd127)       y_w[10*j +: 10] = 10'sd127;
            else if (y < -38'sd127) y_w[10*j +: 10] = -10'sd127;
            else                    y_w[10*j +: 10] = 10'(y[9:0]);
        end
    end

    // -------------------------------------------------------- output FIFO
    fifo_sync_core #(.W(FW), .DEPTH(OUT_DEPTH)) u_ofifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .wen    (s5_v),
        .wdata  ({s5_f, y_w}),
        .wfull  (of_wfull),
        .rready (out_ready),
        .rvalid (of_rvalid),
        .rdata  ({out_sof, out_eol, out_last, out_data}),
        .level  (of_level)
    );

    assign out_valid = of_rvalid;

    wire of_empty = (of_level == '0) && !of_rvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          pend <= 5'd0;
        else if (start)      pend <= 5'd0;
        else                 pend <= pend + 5'(em_issue || (in_accept && !ln_mode))
                                         - 5'(s5_v);
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && s5_v && of_wfull)
            $error("st_norm: output FIFO overflow (credit broken)");
        if (rst_n && in_accept && (in_last !== (beat_cnt == 5'(g_r - 5'd1))))
            $error("st_norm: in_last on beat %0d of a %0d-beat pixel",
                   beat_cnt, g_r);
        if (rst_n && in_accept && ln_mode
            && ((in_lane[0] > 10'sd254) || (in_lane[0] < -10'sd254)
             || (in_lane[1] > 10'sd254) || (in_lane[1] < -10'sd254)
             || (in_lane[2] > 10'sd254) || (in_lane[2] < -10'sd254)
             || (in_lane[3] > 10'sd254) || (in_lane[3] < -10'sd254)))
            $error("st_norm: LN lane outside +-254");
    end
    always @(posedge clk)
        if (rst_n && start) begin
            if (cfg_mode != 2'(MODE_LN) && cfg_mode != 2'(MODE_FILM))
                $error("st_norm: bad cfg_mode %0d", cfg_mode);
            if (cfg_mode == 2'(MODE_LN) && cfg_g < 5'd8)
                $error("st_norm: LN needs cfg_g >= 8 (got %0d)", cfg_g);
            if (cfg_g == 5'd0 || cfg_g > 5'(GMAX))
                $error("st_norm: cfg_g %0d out of range", cfg_g);
            if (cfg_npix == 18'd0)
                $error("st_norm: cfg_npix is zero");
        end
`endif

    // ------------------------------------------------------------------ busy
    logic busy_q;

    wire pipe_empty = !em_act && (p_col == p_emit)
                   && !par_rdy[par_i]
                   && (pix_in_left == 18'd0) && (pix_out_left == 18'd0)
                   && !s1_v && !s2_v && !s3_v && !s4_v && !s5_v
                   && !cm1_v && !cm2_v && !cm3_v
                   && (pend == 5'd0) && of_empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else if (start) begin
            busy_q <= 1'b1;
        end else if (busy_q && pipe_empty) begin
            busy_q <= 1'b0;
        end
    end

    assign busy = busy_q;

    initial begin
        if (OUT_DEPTH < 8 || (1 << OF_AW) != OUT_DEPTH)
            $error("st_norm: OUT_DEPTH must be a power of two >= 8");
        if (PB_AW != 2 + GBITS || 4 * BW != (1 << PB_AW))
            $error("st_norm: pixel buffer address disagrees with the slots");
        if (CW != 3 + 27 + 18)
            $error("st_norm: coefficient word layout changed");
    end

endmodule
