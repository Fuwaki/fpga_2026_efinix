// st_pw.sv -- PW stage of the ST block engine (guided net at 640x360).
//
// A group-stream stage: for every pixel it runs one or two 1x1 convolutions on
// one 8-output x 16-input int8 MAC array (st_mac8x16) and requantises the
// result with four st_requant lanes (docs/st-accel-engine-adr.md,
// docs/st-guided-adr.md).
//
// Throughput.  A layer op (pixel, layer) costs NO*NI array cycles, NO =
// ceil(cout/8) output tiles and NI = ceil(cin/16) input tiles, one array cycle
// per (output tile, input tile); the four requant lanes take 2*NO cycles for
// the same op, so a pixel costs
//
//     max( sum_k NO_k*NI_k , 2 * sum_k NO_k )  + a small constant
//
// cycles, k over the configured layers, when the input keeps up and the output
// never stalls.  cin <= 80 (NI <= 5) and cout <= 80 (NO <= 10), so the worst
// 1x1 layer is 50 array cycles, 80 -> 80; the requant term dominates only for
// cin <= 16.  The constant is the collector and array latency plus the last
// op's requant drain (6 + 2*NO cycles).  Layers are issued in the order
// L1(p), L2(p-1), so the two layers of consecutive pixels overlap on the
// array.
//
// Structure.
//   collector   group beats -> two 80 x int8 banks, one per pixel parity, so
//               pixel p+1 is collected while pixel p is on the array.  Wide
//               mode (cfg_wide) takes 16 int8 values per beat on in_wide,
//               byte k of beat b = element 16b + k, which is what the DW
//               stage's im2col port emits (a 27-element vector is 2 beats);
//               narrow mode keeps 4 lanes per beat, low 8 bits of each lane
//               (a 80-channel vector is 20 beats);
//   issue       one op at a time, one array cycle per (ot, it) with weight word
//               pw_base + ot*ceil(cin/16) + it;
//   MAC         st_pw_rom (registered) -> st_mac8x16 (LAT 4) -> tile FIFO
//               (TILE_DEPTH entries: the 8 accumulators of an output tile and
//               the tile's 8-bit tag);
//   requant     4 lanes, the two halves of an output tile back to back, LAT 6;
//               one half tile is 4 channels, exactly one group beat, so the
//               drain packs beats directly and layer-1 results land in the
//               layer-2 vector bank.  The 512 bits of requant words of a tile
//               are not stored: they are a function of the tile's output tile
//               and layer, so the drain reads them from st_rq_rom, one read
//               per half tile with the address presented one cycle ahead;
//   output      OUT_DEPTH-beat FIFO in block RAM, credit-checked at issue, so
//               no fixed-latency pipeline is ever back-pressured.  An op of
//               cout = 80 speaks for 20 beats and the credit must admit the
//               next op while those are still queued, so OUT_DEPTH has to hold
//               two of them: 64, not 32 (32 cost 3 cycles per pixel on the
//               16 -> 80 layer).
//
// The layer-2 vector bank is also two banks (pixel parity): the issue order
// L1(p), L2(p-1) reads p-1's bank while p's results arrive in the other one.
// A layer-2 op waits for its pixel's layer-1 results (xl2_busy) and for output
// credits; a layer-1 op waits for the bank L2(p-2) is reading.
//
// Flags.  A pixel's sof/eol are ORed over its input beats; sof is placed on the
// first output group beat of the pixel, eol and last on the final one.
//
// A pass is cfg_npix pixels (18 bits: 640x360 = 230400): the stage takes no
// input beyond them and ends when all of them are collected and every pipeline
// is empty, so input gaps of any length are harmless.
//
// Resources.  The two vector families are flip-flop banks, 2 x 80 bytes each:
// 2560 flops.  The PW ROM is PW_DEPTH words of 1024 bits (256 x 1024 = 26
// RAM10 at 1024x10, the guided net's 204 words), the requant ROM RQ_DEPTH x
// 4 x 64 bits (512 x 4 words per bank: 1496 words in all).
module st_pw #(
    parameter int    TILE_DEPTH = 8,        // accumulator tiles in the tile FIFO
    parameter int    OUT_DEPTH  = 64,       // output beats (>= 2 ops of 20)
    parameter int    PW_DEPTH   = 256,      // PW weight words
    parameter int    RQ_DEPTH   = 512,      // requant words per bank (4 banks)
    parameter string PW_HEX     = "rtl/st_accel_new/gen/guided/st_pw.hex",
    parameter string RQ_HEX     = "rtl/st_accel_new/gen/guided/st_rq.hex"
) (
    input  logic              clk,
    input  logic              rst_n,

    // group stream in
    input  logic              in_valid,
    output logic              in_ready,
    input  logic [39:0]       in_data,      // 4 int8 lanes in 10-bit fields
    input  logic [127:0]      in_wide,      // 16 int8 values, cfg_wide = 1
    input  logic              in_last,
    input  logic              in_eol,
    input  logic              in_sof,

    // group stream out
    output logic              out_valid,
    input  logic              out_ready,
    output logic [39:0]       out_data,
    output logic              out_last,
    output logic              out_eol,
    output logic              out_sof,

    // one-cycle start pulse while idle; busy until the last beat is accepted
    input  logic              start,
    output logic              busy,

    // configuration, sampled on start
    input  logic [17:0]       cfg_npix,     // pixels of the pass
    input  logic              cfg_wide,     // input beats are in_wide[127:0]
    input  logic [1:0]        cfg_n,
    input  logic [6:0]        cfg_cin0,
    input  logic [6:0]        cfg_cin1,
    input  logic [6:0]        cfg_cout0,
    input  logic [6:0]        cfg_cout1,
    input  logic [9:0]        cfg_pw_base0,
    input  logic [9:0]        cfg_pw_base1,
    input  logic [10:0]       cfg_rq_base0,
    input  logic [10:0]       cfg_rq_base1,
    input  logic signed [9:0] cfg_lo0,
    input  logic signed [9:0] cfg_lo1,
    input  logic signed [9:0] cfg_hi0,
    input  logic signed [9:0] cfg_hi1
);
    // st_requant in_valid -> out_valid.
    localparam int LAT_RQ = 6;

    localparam int TF_AW = (TILE_DEPTH > 1) ? $clog2(TILE_DEPTH) : 1;
    localparam int OF_AW = $clog2(OUT_DEPTH);
    localparam int PW_AW = $clog2(PW_DEPTH);
    localparam int RQ_AW = $clog2(RQ_DEPTH);

    // The vector banks: 80 int8, the widest cin (NI = 5).
    localparam int XB    = 80;              // bytes per bank
    localparam int XW    = 8 * XB;          // bits per bank

    // Output beats of a layer: ceil(cout/4) <= 20, five bits.
    function automatic logic [4:0] div4(input logic [6:0] v);
        div4 = 5'((8'(v) + 8'd3) >> 2);
    endfunction
    function automatic logic [3:0] div8(input logic [6:0] v);
        div8 = 4'((8'(v) + 8'd7) >> 3);
    endfunction
    function automatic logic [3:0] div16(input logic [6:0] v);
        div16 = 4'((8'(v) + 8'd15) >> 4);
    endfunction

    // ------------------------------------------------------- configuration
    logic [1:0]        n_lay;
    logic              wide_r;
    logic [6:0]        cin_r  [2];
    logic [6:0]        cout_r [2];
    logic [9:0]        pw_r   [2];
    logic [10:0]       rq_r   [2];
    logic signed [9:0] lo_r   [2], hi_r [2];

    wire [4:0] g_l1 = div4(cout_r[0]);          // output beats, layer 1
    wire [4:0] g_l2 = div4(cout_r[1]);          // output beats, layer 2

    // ------------------------------------------------------- vector banks
    logic [XW-1:0] xa  [2];         // input vectors, bank = pixel parity
    logic [XW-1:0] xl2 [2];         // layer-2 input vectors, same parity
    logic [1:0]    xl2_busy;        // layer-1 results still arriving

    // ===================================================== input collector
    logic [1:0]  col_pix;           // pixel being collected, index mod 4
    logic [4:0]  col_beat;          // beat of that pixel (<= 5 wide, <= 20 narrow)
    logic        col_act;           // pixel partially collected
    logic        col_sof, col_eol;
    logic        pix_sof [4];       // per pixel, index mod 4
    logic        pix_eol [4];
    logic [1:0]  p_free;            // next pixel whose input bank is free

    wire       col_bank  = col_pix[0];
    wire       col_room  = (2'(col_pix - p_free) < 2'd2);
    wire       in_accept = in_valid && in_ready;
    // The pixel is complete at this clock edge: its bank is written now and
    // read by the op's first fire next cycle, so the op may start in this
    // cycle instead of waiting for col_pix to move (one cycle per pixel).
    wire       col_fin   = in_accept && in_last;

    logic [17:0] pix_left;          // pixels of the pass still to collect
    assign in_ready = busy && (pix_left != 18'd0) && (col_act || col_room);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       pix_left <= 18'd0;
        else if (start)                   pix_left <= cfg_npix;
        else if (in_accept && in_last)    pix_left <= pix_left - 18'd1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_pix  <= 2'd0;
            col_beat <= 5'd0;
            col_act  <= 1'b0;
            col_sof  <= 1'b0;
            col_eol  <= 1'b0;
            for (int k = 0; k < 4; k++) begin
                pix_sof[k] <= 1'b0;
                pix_eol[k] <= 1'b0;
            end
        end else if (start) begin
            col_pix  <= 2'd0;
            col_beat <= 5'd0;
            col_act  <= 1'b0;
            col_sof  <= 1'b0;
            col_eol  <= 1'b0;
        end else if (in_accept) begin
            // The bank is XB bytes, so a legal pixel (cin <= 80) fits: wide
            // mode has at most 5 beats of 16 and narrow at most 20 of 4.  The
            // write is gated on that, and an over-long pixel is a stream error
            // (the same bound the simulation checks).
            if (wide_r ? (col_beat < 5) : (col_beat < 20)) begin
                if (wide_r) begin
                    // 16 int8 per beat, byte k = element 16b + k
                    for (int j = 0; j < 16; j++)
                        xa[col_bank][8*(16*int'(col_beat) + j) +: 8] <= in_wide[8*j +: 8];
                end else begin
                    // 4 lanes of int8 in 10-bit fields: keep the low byte
                    for (int j = 0; j < 4; j++)
                        xa[col_bank][8*(4*int'(col_beat) + j) +: 8] <= in_data[10*j +: 8];
                end
            end
            // the flags of the pixel: ORed over its beats, cleared at its end
            col_sof <= col_sof | in_sof;
            col_eol <= col_eol | in_eol;
            if (in_last) begin
                pix_sof[col_pix] <= col_sof | in_sof;
                pix_eol[col_pix] <= col_eol | in_eol;
                col_sof  <= 1'b0;
                col_eol  <= 1'b0;
                col_pix  <= col_pix + 2'd1;
                col_beat <= 5'd0;
                col_act  <= 1'b0;
            end else begin
                col_beat <= col_beat + 5'd1;
                col_act  <= 1'b1;
            end
`ifndef SYNTHESIS
            if (wide_r ? (col_beat == 5'd5) : (col_beat == 5'd20))
                $error("st_pw: pixel beat %0d exceeds the %0d-byte bank", col_beat, XB);
`endif
        end
    end

    // ============================================================== issue
    logic        op_act;
    logic        op_lyr;            // 0: layer 1, 1: layer 2
    logic        op_bank;           // vector bank: pixel parity
    logic [6:0]  op_cin;
    logic [9:0]  op_pw;
    logic        op_sof, op_eol;
    logic [3:0]  op_ot, op_it;
    logic [3:0]  op_no, op_ni;
    logic [1:0]  p_iss;             // next pixel whose layer 1 is issued
    logic [1:0]  p_l2;              // next pixel whose layer 2 is issued

    // Tiles fired but not yet drained: in the array pipeline, the tile FIFO
    // and the requant lanes.  The array writes the FIFO six cycles after a
    // tile's last input beat, so a credit based on tf_wp - tf_rp alone would
    // let a burst overwrite entries that are not written yet.
    logic [TF_AW:0] tile_used;
    // Beats reserved but not pushed: at most the credit (OUT_DEPTH), so one
    // bit more than the depth's log2.
    logic [OF_AW:0] pend;

    // Tile FIFO and drain bookkeeping.  The pointers carry one bit more than
    // the index so that full and empty differ; the level is their difference.
    // of_level is the output FIFO's level, same scheme.
    logic [TF_AW:0]   tf_wp, tf_rp;
    logic             dr_phase;     // 0: first half of the head tile, 1: second
    wire  [TF_AW:0]   tile_occ = tf_wp - tf_rp;
    wire              tile_pop = dr_phase && (tile_occ != '0);
    wire  [OF_AW:0]   of_level;     // output beats queued, RAM side
    wire              of_empty;

    wire [4:0] l1_beats = (n_lay == 2'd1) ? g_l1 : 5'd0;
    wire [4:0] l2_beats = g_l2;

    // Output beats that would be spoken for if the op were issued; the sum
    // needs a bit more than the two fields so it cannot wrap.  of_level counts
    // the words in the FIFO's RAM only, not the one on its read port, so the
    // credit bounds the RAM side at OUT_DEPTH words and a push never meets
    // the full flag (a push needs an outstanding reservation, pend > 0).
    wire [8:0] of_allowed = 9'(OUT_DEPTH);
    wire [8:0] out_need_l1 = 9'(of_level) + 9'(pend) + 9'(l1_beats);
    wire [8:0] out_need_l2 = 9'(of_level) + 9'(pend) + 9'(l2_beats);
    wire out_room_l1 = (out_need_l1 <= of_allowed);
    wire out_room_l2 = (out_need_l2 <= of_allowed);

    // L1(p) writes the layer-2 bank of parity p, which L2(p-2) reads: it may
    // start only after L2(p-2) has been issued, i.e. p_iss - p_l2 <= 1.
    // The pixel is either already collected (col_pix moved past it) or being
    // completed in this cycle by its last input beat (col_fin).
    wire       col_here = (col_pix == p_iss);
    wire       col_ok   = !col_here || col_fin;
    wire [1:0] l1_diff  = 2'(p_iss - p_l2);
    wire l1_cand = (n_lay == 2'd1) ? (col_ok && out_room_l1)
                                   : (col_ok && (l1_diff <= 2'd1)
                                      && !xl2_busy[p_iss[0]] && out_room_l1);
    wire l2_cand = (n_lay == 2'd2) && (p_l2 != p_iss)
                && !xl2_busy[p_l2[0]] && out_room_l2;

    wire tile_end = (op_it == (op_ni - 4'd1));
    wire op_end   = tile_end && (op_ot == (op_no - 4'd1));
    wire tile_ok  = (tile_used != (TF_AW+1)'(TILE_DEPTH));
    wire fire     = op_act && (!tile_end || tile_ok);

    // An op can start in the cycle the previous one's last beat is accepted:
    // the array then runs without a bubble between ops.
    wire chain = fire && op_end;
    wire take  = busy && (l1_cand || l2_cand) && (!op_act || chain);
    wire l2_go = take && !l1_cand && l2_cand;
    wire issue = take;

    wire [1:0] iss_pix = l2_go ? p_l2 : p_iss;
    wire       iss_final = l2_go || (n_lay == 2'd1);
    wire [4:0] iss_beats = l2_go ? g_l2 : ((n_lay == 2'd1) ? g_l1 : 5'd0);

    wire [XW-1:0] op_vec = op_lyr ? xl2[op_bank] : xa[op_bank];

    // the beat's operand tile: 16 int8 lanes, zero beyond cin
    logic [15:0][7:0] x_tile;
    always_comb begin
        int idx;
        for (int j = 0; j < 16; j++) begin
            idx = 16 * int'(op_it) + j;
            x_tile[j] = (idx < int'(op_cin)) ? op_vec[8*idx +: 8] : 8'd0;
        end
    end

    // weight word: pw_base + ot*ni + it (the ROM is tile-major)
    wire [9:0]       pw_off  = 10'(op_ot) * 10'(op_ni) + 10'(op_it);
    wire [9:0]       pw_sum  = 10'(op_pw) + pw_off;
    wire [PW_AW-1:0] pw_addr = PW_AW'(pw_sum);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_act  <= 1'b0;
            op_lyr  <= 1'b0;
            op_bank <= 1'b0;
            op_cin  <= 7'd0;
            op_pw   <= 10'd0;
            op_sof  <= 1'b0;
            op_eol  <= 1'b0;
            op_ot   <= 4'd0;
            op_it   <= 4'd0;
            op_no   <= 4'd1;
            op_ni   <= 4'd1;
            p_iss   <= 2'd0;
            p_l2    <= 2'd0;
            p_free  <= 2'd0;
            tile_used <= '0;
        end else if (start) begin
            op_act  <= 1'b0;
            op_ot   <= 4'd0;
            op_it   <= 4'd0;
            p_iss   <= 2'd0;
            p_l2    <= 2'd0;
            p_free  <= 2'd0;
            tile_used <= '0;
        end else begin
            // issue wins over fire: when the last beat of an op is accepted
            // and the next op can start, the descriptor is replaced this cycle
            // and the new op's first beat fires next cycle, with no bubble.
            if (issue) begin
                op_act  <= 1'b1;
                op_lyr  <= l2_go;
                op_bank <= iss_pix[0];
                op_cin  <= l2_go ? cin_r[1]  : cin_r[0];
                op_pw   <= l2_go ? pw_r[1]   : pw_r[0];
                // a layer-1 op may start on the cycle its pixel's last input
                // beat is taken; that pixel's flags are still in the running
                // OR then, not in pix_sof yet
                op_sof  <= (l2_go || !(col_fin && (iss_pix == col_pix)))
                           ? pix_sof[iss_pix] : (col_sof | in_sof);
                op_eol  <= (l2_go || !(col_fin && (iss_pix == col_pix)))
                           ? pix_eol[iss_pix] : (col_eol | in_eol);
                op_ot   <= 4'd0;
                op_it   <= 4'd0;
                op_no   <= div8(l2_go ? cout_r[1] : cout_r[0]);
                op_ni   <= div16(l2_go ? cin_r[1] : cin_r[0]);
                if (l2_go) p_l2  <= p_l2 + 2'd1;
                else       p_iss <= p_iss + 2'd1;
            end else if (fire) begin
                if (tile_end) begin
                    op_it <= 4'd0;
                    op_ot <= op_ot + 4'd1;
                    if (op_end) op_act <= 1'b0;
                end else begin
                    op_it <= op_it + 4'd1;
                end
            end
            // the input bank of a pixel is free once its layer-1 op is done
            if (chain && !op_lyr) p_free <= p_free + 2'd1;
            // one slot per tile, from the last input beat to the drain
            tile_used <= tile_used + 1'(fire && tile_end) - 1'(tile_pop);
        end
    end

    // ============================================== array pipeline and ROMs
    // The ROM output is registered, so its address is registered one stage
    // later than the operand tile: a beat's weight word then leaves the ROM in
    // the cycle the array's input register takes it, and the array's own w_s1
    // is the only weight register behind the ROM (s0_pwaddr -> pw_dout ->
    // w_s1).
    logic             s0_vld, s0_first, s0_last;
    logic [15:0][7:0] s0_x;
    logic [PW_AW-1:0] s0_pwaddr;
    logic             s1_vld, s1_first, s1_last;
    logic [15:0][7:0] s1_x;
    logic [1023:0]    pw_dout;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_vld   <= 1'b0;
            s0_first <= 1'b0;
            s0_last  <= 1'b0;
        end else begin
            s0_vld   <= fire;
            s0_first <= fire && (op_it == 4'd0);
            s0_last  <= fire && tile_end;
            if (fire) begin
                s0_x      <= x_tile;
                s0_pwaddr <= pw_addr;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_vld   <= 1'b0;
            s1_first <= 1'b0;
            s1_last  <= 1'b0;
        end else begin
            s1_vld   <= s0_vld;
            s1_first <= s0_first;
            s1_last  <= s0_last;
            if (s0_vld) s1_x <= s0_x;
        end
    end

    st_pw_rom #(.DEPTH(PW_DEPTH), .HEX(PW_HEX)) u_pw_rom (
        .clk  (clk),
        .addr (s0_pwaddr),
        .dout (pw_dout)
    );

    logic               mac_done;
    logic signed [23:0] mac_acc [8];

    st_mac8x16 u_mac (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_valid(s1_vld),
        .in_x    (s1_x),
        .in_w    (pw_dout),
        .in_first(s1_first),
        .in_last (s1_last),
        .done    (mac_done),
        .acc_out (mac_acc)
    );

    // --------------------------------------------------------- requant ROM
    // The tag of a tile is wanted in the mac_done cycle, six cycles after the
    // tile's last input beat was accepted: clamp limits, output tile, vector
    // bank, layer, sof, eol.  The clamp limits are the layer's, so the tag
    // carries the layer and the drain takes them from the configuration.
    logic [7:0] te_tag [6];
    logic [5:0] te_vld;

    wire [7:0] beat_tag = {op_ot, op_bank, op_lyr, op_sof, op_eol};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            te_vld <= 6'd0;
            for (int k = 0; k < 6; k++) te_tag[k] <= 8'd0;
        end else if (start) begin
            te_vld <= 6'd0;
        end else begin
            te_vld[0] <= fire && tile_end;
            te_tag[0] <= beat_tag;
            for (int k = 1; k < 6; k++) begin
                te_vld[k] <= te_vld[k-1];
                te_tag[k] <= te_tag[k-1];
            end
        end
    end

    // ---------------------------------------------------------- tile FIFO
    // tag: output tile, vector bank, layer, sof, eol
    logic [191:0] tf_acc [TILE_DEPTH];
    logic [7:0]   tf_tag [TILE_DEPTH];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tf_wp <= '0;
        end else if (start) begin
            tf_wp <= '0;
        end else if (mac_done && te_vld[5]) begin
            tf_acc[tf_wp[TF_AW-1:0]] <= {mac_acc[7], mac_acc[6], mac_acc[5], mac_acc[4],
                                         mac_acc[3], mac_acc[2], mac_acc[1], mac_acc[0]};
            tf_tag[tf_wp[TF_AW-1:0]] <= te_tag[5];
            tf_wp <= tf_wp + 1'(1);
        end
    end

    // ------------------------------------------------------------- drain
    // No idle state: the head tile of the FIFO is fed to the lanes as soon as
    // it is there, first half and then second half.  A tile is popped when its
    // second half has been issued, so dr_phase is back at 0 for the next one.
    //
    // The requant words of a tile are the eight words at the tile's first
    // address rq_base + 8*ot, so they are read from the ROM here instead of
    // being carried through the FIFO.  The ROM read is registered, so the
    // address on the port is that of the NEXT beat's tile -- the head tile
    // again for its second half, the next one for a first half.  The pointers
    // only move when there is a tile to feed, so the address, like the beat,
    // repeats while the drain stalls.
    wire [191:0] dr_acc = tf_acc[tf_rp[TF_AW-1:0]];
    wire [7:0]   dr_tag = tf_tag[tf_rp[TF_AW-1:0]];

    wire         dr_half  = dr_phase;
    wire         dr_valid = (tile_occ != '0);
    // the half of the beat the ROM must present next cycle
    wire         nx_half  = dr_valid ? ~dr_phase : dr_phase;
    wire [95:0]  acc_sel  = dr_half ? dr_acc[191:96] : dr_acc[95:0];

    wire [4:0]  dr_g   = {dr_tag[7:4], dr_half};         // output beat of the op
    wire [9:0]  dr_lo  = dr_tag[2] ? lo_r[1] : lo_r[0];
    wire [9:0]  dr_hi  = dr_tag[2] ? hi_r[1] : hi_r[0];

    wire              mac_wr = mac_done && te_vld[5];
    wire [TF_AW-1:0]  nx_tile = tf_rp[TF_AW-1:0]
                              + TF_AW'((dr_valid && dr_phase) ? 1'b1 : 1'b0);
    // The tile the drain feeds next cycle may be the one being written now:
    // its tag is not in the FIFO yet, the write tag is the same value.
    wire [7:0]        nx_tag  = (mac_wr && (nx_tile == tf_wp[TF_AW-1:0]))
                              ? te_tag[5] : tf_tag[nx_tile];
    // the tile's first requant word, rq_base + 8*ot; the half is the ROM's
    // word index within the tile, so one read covers one half tile
    wire [10:0]       nx_word = (nx_tag[2] ? rq_r[1] : rq_r[0])
                              + 11'({7'd0, nx_tag[7:4]}) * 11'd8
                              + 11'(nx_half ? 11'd4 : 11'd0);

    // four banks of RQ_DEPTH words: a read returns the four channels of one
    // half tile
    logic [3:0][63:0] rq_banks;
    st_rq_rom #(.NB(4), .DEPTH(RQ_DEPTH), .HEX(RQ_HEX)) u_rq_rom (
        .clk  (clk),
        .addr (RQ_AW'(nx_word >> 2)),
        .dout (rq_banks)
    );

    wire [255:0] rq_sel = {rq_banks[3], rq_banks[2], rq_banks[1], rq_banks[0]};

    logic [63:0]        lane_w [4];
    logic signed [24:0] lane_x [4];
    logic signed [31:0] lane_sum [4];
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            lane_w[j]   = rq_sel[64*j +: 64];
            lane_sum[j] = $signed({{8{acc_sel[24*j + 23]}}, acc_sel[24*j +: 24]})
                        + $signed(lane_w[j][31:0]);
            lane_x[j]   = lane_sum[j][24:0];    // |acc + bias| < 2**22
        end
    end

    wire              lane_valid = dr_valid;
    // tag: output beat, vector bank, layer, sof, eol
    wire [8:0]        lane_tag   = {dr_g, dr_tag[3], dr_tag[2], dr_tag[1], dr_tag[0]};
    // The four lanes run in lockstep, so only lane 0's handshake is used.
    wire              lane_ovld [4];
    wire signed [9:0] lane_y [4];
    wire [8:0]        lane_otag [4];
    wire              lane_out_valid = lane_ovld[0];
    wire [8:0]        lane_out_tag   = lane_otag[0];

    for (genvar j = 0; j < 4; j++) begin : g_lane
        st_requant #(.XW(25), .TW(9)) u_rq (
            .clk      (clk),
            .rst_n    (rst_n),
            .in_valid (lane_valid),
            .in_x     (lane_x[j]),
            .in_mant  (lane_w[j][55:32]),
            .in_k     (lane_w[j][61:56]),
            .in_lo    (dr_lo),
            .in_hi    (dr_hi),
            .in_tag   (lane_tag),
            .out_valid(lane_ovld[j]),
            .out_y    (lane_y[j]),
            .out_tag  (lane_otag[j])
        );
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dr_phase <= 1'b0;
            tf_rp    <= '0;
        end else if (start) begin
            dr_phase <= 1'b0;
            tf_rp    <= '0;
        end else if (tile_occ != '0) begin
            dr_phase <= ~dr_phase;
            if (dr_phase) tf_rp <= tf_rp + 1'(1);
        end
    end

    // --------------------------------------------------------- writeback
    wire [4:0] wb_g    = lane_out_tag[8:4];
    wire       wb_bank = lane_out_tag[3];
    wire       wb_lyr  = lane_out_tag[2];
    wire       wb_sof  = lane_out_tag[1];
    wire       wb_eol  = lane_out_tag[0];

    // layer 2, or the only layer of a one-layer pass, is the output
    wire       wb_final = wb_lyr || (n_lay == 2'd1);
    wire [6:0] wb_cout  = wb_lyr ? cout_r[1] : cout_r[0];   // 1..80
    wire [4:0] wb_need  = wb_lyr ? g_l2 : g_l1;
    wire       wb_keep  = (wb_g < wb_need);

    // One group beat and one 4-byte vector from the four lanes; channels
    // beyond cout are zero.
    logic [39:0] beat;
    logic [31:0] vec4;
    for (genvar j = 0; j < 4; j++) begin : g_pack
        wire [7:0] ch = 8'(4 * int'(wb_g) + j);
        assign beat[10*j +: 10] = (ch < {1'b0, wb_cout}) ? lane_y[j] : 10'sd0;
        assign vec4[8*j  +: 8]  = (ch < {1'b0, wb_cout}) ? lane_y[j][7:0] : 8'd0;
    end

    wire        beat_push = lane_out_valid && wb_final && wb_keep;
    wire [42:0] of_din    = {wb_sof && (wb_g == 5'd0),
                             wb_eol && (wb_g == (wb_need - 5'd1)),
                             (wb_g == (wb_need - 5'd1)), beat};

    // -------------------------------------------------------- output FIFO
    // Block RAM (fifo_sync_core), so the beats cost RAM10 blocks, not 43
    // flip-flops each.  Its first-word fall-through read register is also the
    // output register of the stage.
    logic        of_we;
    logic [42:0] of_dout;
    logic        of_wfull;

    fifo_sync_core #(.W(43), .DEPTH(OUT_DEPTH)) u_ofifo (
        .clk    (clk),
        .rst_n  (rst_n),
        .wen    (of_we),
        .wdata  (of_din),
        .wfull  (of_wfull),
        .rready (out_ready),
        .rvalid (out_valid),
        .rdata  (of_dout),
        .level  (of_level)
    );

    assign {out_sof, out_eol, out_last, out_data} = of_dout;

    // Empty: no word in the RAM and none on the read port.  The pointers of
    // the FIFO only move when it is written and read, so this is also what the
    // previous pass left behind -- empty, since a pass only ends drained.
    assign of_empty = (of_level == '0) && !out_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xl2_busy <= 2'd0;
        end else if (start) begin
            xl2_busy <= 2'd0;
        end else begin
            if (issue && !l2_go) xl2_busy[p_iss[0]] <= 1'b1;
            if (lane_out_valid && !wb_final && wb_keep) begin
                xl2[wb_bank][32*wb_g +: 32] <= vec4;
                if (wb_g == (wb_need - 5'd1)) xl2_busy[wb_bank] <= 1'b0;
            end
        end
    end

    // The FIFO takes the beat in the cycle it is offered: the credit scheme
    // reserves a slot before the beat can be produced, so it is never full.
    assign of_we = beat_push;

`ifndef SYNTHESIS
    always @(posedge clk)
        if (rst_n && of_we && of_wfull)
            $error("st_pw: output FIFO overflow (credit broken)");
`endif

    // output beats reserved by issued ops, released one per push
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      pend <= '0;
        else if (start)  pend <= '0;
        else             pend <= pend + (OF_AW+1)'(issue && iss_final ? iss_beats : 5'd0)
                                     - 1'(beat_push);
    end

    // ---------------------------------------------------------------- busy
    logic busy_q;

    wire pipe_empty = !op_act && (tile_used == '0) && (tile_occ == '0)
                   && (dr_phase == 1'b0) && !lane_out_valid && of_empty
                   && (pend == '0) && !col_act && (col_pix == p_free)
                   && (n_lay == 2'd1 || (p_l2 == p_iss));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else if (start) begin
            busy_q <= 1'b1;
        end else if (busy_q && pipe_empty && (pix_left == 18'd0)) begin
            busy_q <= 1'b0;
        end
    end

    assign busy = busy_q;

    // ------------------------------------------------- configuration latches
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_lay  <= 2'd1;
            wide_r <= 1'b0;
            for (int k = 0; k < 2; k++) begin
                cin_r[k]  <= 7'd1;
                cout_r[k] <= 7'd1;
                pw_r[k]   <= 10'd0;
                rq_r[k]   <= 11'd0;
                lo_r[k]   <= 10'sd0;
                hi_r[k]   <= 10'sd0;
            end
        end else if (start) begin
            n_lay     <= cfg_n;
            wide_r    <= cfg_wide;
            cin_r[0]  <= cfg_cin0;
            cin_r[1]  <= cfg_cin1;
            cout_r[0] <= cfg_cout0;
            cout_r[1] <= cfg_cout1;
            pw_r[0]   <= cfg_pw_base0;
            pw_r[1]   <= cfg_pw_base1;
            rq_r[0]   <= cfg_rq_base0;
            rq_r[1]   <= cfg_rq_base1;
            lo_r[0]   <= cfg_lo0;
            lo_r[1]   <= cfg_lo1;
            hi_r[0]   <= cfg_hi0;
            hi_r[1]   <= cfg_hi1;
        end
    end

    // Configuration bounds: the ROMs are addressed by their parameterised
    // depths, so a layer outside them would wrap the address instead of
    // failing.  (Synthesis of a configuration is a build-time decision, so
    // these checks are for simulation.)
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && start) begin
            for (int k = 0; k < 2; k++) begin
                if (k >= int'(cfg_n)) continue;
                if (cfg_cin0 < 7'd1 || (k == 1 && cfg_cin1 < 7'd1) ||
                    cfg_cout0 < 7'd1 || (k == 1 && cfg_cout1 < 7'd1))
                    $error("st_pw: layer %0d has a zero channel count", k);
                if (int'(cfg_cin0) > 80 || (k == 1 && int'(cfg_cin1) > 80) ||
                    int'(cfg_cout0) > 80 || (k == 1 && int'(cfg_cout1) > 80))
                    $error("st_pw: layer %0d exceeds 80 channels", k);
                if ((k == 0 ? int'(cfg_pw_base0) : int'(cfg_pw_base1))
                    + int'(div8(k == 0 ? cfg_cout0 : cfg_cout1))
                      * int'(div16(k == 0 ? cfg_cin0 : cfg_cin1)) > PW_DEPTH)
                    $error("st_pw: layer %0d weights exceed PW_DEPTH", k);
                if ((k == 0 ? int'(cfg_rq_base0) : int'(cfg_rq_base1)) % 4 != 0)
                    $error("st_pw: layer %0d rq base is not a multiple of 4", k);
                if ((k == 0 ? int'(cfg_rq_base0) : int'(cfg_rq_base1))
                    + 8 * int'(div8(k == 0 ? cfg_cout0 : cfg_cout1)) > 4 * RQ_DEPTH)
                    $error("st_pw: layer %0d requant words exceed the rq ROM", k);
            end
        end
    end
`endif

    initial begin
        if (LAT_RQ != 6 || $clog2(OUT_DEPTH) != OF_AW)
            $error("st_pw: pipeline constants disagree with the delay lines");
        if (PW_DEPTH < 2 || (1 << PW_AW) != PW_DEPTH)
            $error("st_pw: PW_DEPTH must be a power of two");
        if (RQ_DEPTH < 2 || (1 << RQ_AW) != RQ_DEPTH)
            $error("st_pw: RQ_DEPTH must be a power of two");
    end

endmodule
