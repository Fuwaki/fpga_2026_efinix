// st_pw.sv -- PW stage of the ST block engine (tiny_dw at 320x240).
//
// A group-stream stage: for every pixel it runs one or two 1x1 convolutions on
// one 8-output x 16-input int8 MAC array (st_mac8x16) and requantises the
// result with four st_requant lanes (docs/st-accel-engine-adr.md).
//
// Throughput.  A layer op (pixel, layer) costs NO*NI array cycles, NO =
// ceil(cout/8) output tiles and NI = ceil(cin/16) input tiles, one array cycle
// per (output tile, input tile); the four requant lanes take 2*NO cycles for
// the same op, so a pixel costs
//
//     max( sum_k NO_k*NI_k , 2 * sum_k NO_k )  + a small constant
//
// cycles, k over the configured layers, when the input keeps up and the output
// never stalls.  The requant term dominates only for cin <= 16.  The constant
// is the collector and array latency plus the last op's requant drain
// (6 + 2*NO cycles).  Layers are issued in the order L1(p), L2(p-1), so the two
// layers of consecutive pixels overlap on the array.
//
// Structure.
//   collector   group beats -> two 64 x int8 banks, one per pixel parity, so
//               pixel p+1 is collected while pixel p is on the array;
//   issue       one op at a time, one array cycle per (ot, it) with weight word
//               pw_base + ot*ceil(cin/16) + it;
//   MAC         st_pw_rom (registered, read one cycle behind the issue) ->
//               st_mac8x16 (LAT 4) -> tile FIFO (TILE_DEPTH entries: the 8
//               accumulators of an output tile and their 8 requant words);
//   requant     4 lanes, the two halves of an output tile back to back, LAT 6;
//               one half tile is 4 channels, exactly one group beat, so the
//               drain packs beats directly and layer-1 results land in the
//               layer-2 vector bank;
//   output      OUT_DEPTH-beat FIFO, credit-checked at issue, so no
//               fixed-latency pipeline is ever back-pressured.
//
// The layer-2 vector bank is also two banks (pixel parity): the issue order
// L1(p), L2(p-1) reads p-1's bank while p's results arrive in the other one.
// A layer-2 op waits for its pixel's layer-1 results (xl2_busy) and for output
// credits; a layer-1 op waits for the bank L2(p-2) is reading.
//
// Flags.  A pixel's sof/eol are ORed over its input beats; sof is placed on the
// first output group beat of the pixel, eol and last on the final one.
//
// A pass is cfg_npix pixels: the stage takes no input beyond them and ends
// when all of them are collected and every pipeline is empty, so input gaps
// of any length are harmless.
module st_pw #(
    parameter int    TILE_DEPTH = 8,        // accumulator tiles in the tile FIFO
    parameter int    OUT_DEPTH  = 32,       // output beats
    parameter string PW_HEX     = "rtl/st_accel_new/gen/tiny_dw/st_pw.hex",
    parameter string RQ_HEX     = "rtl/st_accel_new/gen/tiny_dw/st_rq.hex"
) (
    input  logic              clk,
    input  logic              rst_n,

    // group stream in
    input  logic              in_valid,
    output logic              in_ready,
    input  logic [39:0]       in_data,      // 4 int8 lanes in 10-bit fields
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
    input  logic [16:0]       cfg_npix,     // pixels of the pass
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
    logic [6:0]        cin_r  [2];
    logic [6:0]        cout_r [2];
    logic [9:0]        pw_r   [2];
    logic [10:0]       rq_r   [2];
    logic signed [9:0] lo_r   [2], hi_r [2];

    wire [4:0] g_l1 = div4(cout_r[0]);          // output beats, layer 1
    wire [4:0] g_l2 = div4(cout_r[1]);          // output beats, layer 2

    // ------------------------------------------------------- vector banks
    logic [511:0] xa  [2];          // input vectors, bank = pixel parity
    logic [511:0] xl2 [2];          // layer-2 input vectors, same parity
    logic [1:0]   xl2_busy;         // layer-1 results still arriving

    // ===================================================== input collector
    logic [1:0]  col_pix;           // pixel being collected, index mod 4
    logic [3:0]  col_beat;          // group beat of that pixel
    logic        col_act;           // pixel partially collected
    logic        col_sof, col_eol;
    logic        pix_sof [4];       // per pixel, index mod 4
    logic        pix_eol [4];
    logic [1:0]  p_free;            // next pixel whose input bank is free

    wire       col_bank  = col_pix[0];
    wire       col_room  = (2'(col_pix - p_free) < 2'd2);
    wire       in_accept = in_valid && in_ready;

    logic [16:0] pix_left;          // pixels of the pass still to collect
    assign in_ready = busy && (pix_left != 17'd0) && (col_act || col_room);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       pix_left <= 17'd0;
        else if (start)                   pix_left <= cfg_npix;
        else if (in_accept && in_last)    pix_left <= pix_left - 17'd1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_pix  <= 2'd0;
            col_beat <= 4'd0;
            col_act  <= 1'b0;
            col_sof  <= 1'b0;
            col_eol  <= 1'b0;
            for (int k = 0; k < 4; k++) begin
                pix_sof[k] <= 1'b0;
                pix_eol[k] <= 1'b0;
            end
        end else if (start) begin
            col_pix  <= 2'd0;
            col_beat <= 4'd0;
            col_act  <= 1'b0;
            col_sof  <= 1'b0;
            col_eol  <= 1'b0;
        end else if (in_accept) begin
            // the lanes carry int8 values in 10-bit fields: keep the low byte
            xa[col_bank][32*col_beat +: 32] <=
                {in_data[37:30], in_data[27:20], in_data[17:10], in_data[7:0]};
            // the flags of the pixel: ORed over its beats, cleared at its end
            col_sof <= col_sof | in_sof;
            col_eol <= col_eol | in_eol;
            if (in_last) begin
                pix_sof[col_pix] <= col_sof | in_sof;
                pix_eol[col_pix] <= col_eol | in_eol;
                col_sof  <= 1'b0;
                col_eol  <= 1'b0;
                col_pix  <= col_pix + 2'd1;
                col_beat <= 4'd0;
                col_act  <= 1'b0;
            end else begin
                col_beat <= col_beat + 4'd1;
                col_act  <= 1'b1;
            end
        end
    end

    // ============================================================== issue
    logic        op_act;
    logic        op_lyr;            // 0: layer 1, 1: layer 2
    logic        op_bank;           // vector bank: pixel parity
    logic [6:0]  op_cin;
    logic [9:0]  op_pw;
    logic [10:0] op_rq;
    logic signed [9:0] op_lo, op_hi;
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
    logic [5:0]     pend;           // output beats reserved but not pushed

    // Tile FIFO and drain bookkeeping.  The pointers carry one bit more than
    // the index so that full and empty differ; the level is their difference.
    logic [TF_AW:0]   tf_wp, tf_rp;
    logic             dr_phase;     // 0: first half of the head tile, 1: second
    wire  [TF_AW:0]   tile_occ = tf_wp - tf_rp;
    wire              tile_pop = dr_phase && (tile_occ != '0);
    wire              of_empty;
    wire  [OF_AW:0]   of_level;

    wire [4:0] l1_beats = (n_lay == 2'd1) ? g_l1 : 5'd0;
    wire [4:0] l2_beats = g_l2;

    // Output beats that would be spoken for if the op were issued; the sum
    // needs a bit more than the two fields so it cannot wrap.
    wire [8:0] of_allowed = 9'(OUT_DEPTH);
    wire [8:0] out_need_l1 = 9'(of_level) + 9'(pend) + 9'(l1_beats);
    wire [8:0] out_need_l2 = 9'(of_level) + 9'(pend) + 9'(l2_beats);
    wire out_room_l1 = (out_need_l1 <= of_allowed);
    wire out_room_l2 = (out_need_l2 <= of_allowed);

    // L1(p) writes the layer-2 bank of parity p, which L2(p-2) reads: it may
    // start only after L2(p-2) has been issued, i.e. p_iss - p_l2 <= 1.
    wire [1:0] l1_diff = 2'(p_iss - p_l2);
    wire l1_cand = (n_lay == 2'd1) ? ((col_pix != p_iss) && out_room_l1)
                                   : ((col_pix != p_iss) && (l1_diff <= 2'd1)
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

    wire [511:0] op_vec = op_lyr ? xl2[op_bank] : xa[op_bank];

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
    wire [9:0]  pw_off  = 10'(op_ot) * 10'(op_ni) + 10'(op_it);
    wire [8:0]  pw_addr = 9'(op_pw + pw_off);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_act  <= 1'b0;
            op_lyr  <= 1'b0;
            op_bank <= 1'b0;
            op_cin  <= 7'd0;
            op_pw   <= 10'd0;
            op_rq   <= 11'd0;
            op_lo   <= 10'sd0;
            op_hi   <= 10'sd0;
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
                op_rq   <= l2_go ? rq_r[1]   : rq_r[0];
                op_lo   <= l2_go ? lo_r[1]   : lo_r[0];
                op_hi   <= l2_go ? hi_r[1]   : hi_r[0];
                op_sof  <= pix_sof[iss_pix];
                op_eol  <= pix_eol[iss_pix];
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
    logic             s0_vld, s0_first, s0_last;
    logic [15:0][7:0] s0_x;
    logic             s1_vld, s1_first, s1_last;
    logic [15:0][7:0] s1_x;
    logic [1023:0]    s1_w;
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
            if (fire) s0_x <= x_tile;
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
            if (s0_vld) begin
                s1_x <= s0_x;
                s1_w <= pw_dout;
            end
        end
    end

    st_pw_rom #(.DEPTH(512), .HEX(PW_HEX)) u_pw_rom (
        .clk  (clk),
        .addr (pw_addr),
        .dout (pw_dout)
    );

    logic               mac_done;
    logic signed [23:0] mac_acc [8];

    st_mac8x16 u_mac (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_valid(s1_vld),
        .in_x    (s1_x),
        .in_w    (s1_w),
        .in_first(s1_first),
        .in_last (s1_last),
        .done    (mac_done),
        .acc_out (mac_acc)
    );

    // --------------------------------------------------------- requant ROM
    // The requant words of a tile are wanted in the mac_done cycle, six
    // cycles after the tile's last input beat was accepted; the ROM address
    // is registered, so it is driven one cycle earlier (index 4 below).
    // tag: clamp limits, output tile, vector bank, layer, sof, eol
    logic [10:0] te_rq  [6];
    logic [27:0] te_tag [6];
    logic [5:0]  te_vld;

    wire [27:0] beat_tag = {op_lo, op_hi, op_ot, op_bank, op_lyr, op_sof, op_eol};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            te_vld <= 6'd0;
            for (int k = 0; k < 6; k++) begin
                te_rq[k]  <= 11'd0;
                te_tag[k] <= 28'd0;
            end
        end else if (start) begin
            te_vld <= 6'd0;
        end else begin
            te_vld[0] <= fire && tile_end;
            // the tile's first requant word: rq_base + 8*ot
            te_rq[0]  <= 11'(op_rq + 11'({7'd0, op_ot}) * 11'd8);
            te_tag[0] <= beat_tag;
            for (int k = 1; k < 6; k++) begin
                te_vld[k] <= te_vld[k-1];
                te_rq[k]  <= te_rq[k-1];
                te_tag[k] <= te_tag[k-1];
            end
        end
    end

    logic [511:0] rq_dout;

    // eight banks of 256 words: the eight channels of an output tile
    logic [7:0][63:0] rq_banks;
    st_rq_rom #(.NB(8), .DEPTH(256), .HEX(RQ_HEX)) u_rq_rom (
        .clk  (clk),
        .addr (8'(te_rq[4] >> 3)),
        .dout (rq_banks)
    );
    assign rq_dout = rq_banks;

    // ---------------------------------------------------------- tile FIFO
    logic [191:0] tf_acc [TILE_DEPTH];
    logic [511:0] tf_rq  [TILE_DEPTH];
    logic [27:0]  tf_tag [TILE_DEPTH];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tf_wp <= '0;
        end else if (start) begin
            tf_wp <= '0;
        end else if (mac_done && te_vld[5]) begin
            tf_acc[tf_wp[TF_AW-1:0]] <= {mac_acc[7], mac_acc[6], mac_acc[5], mac_acc[4],
                                         mac_acc[3], mac_acc[2], mac_acc[1], mac_acc[0]};
            tf_rq [tf_wp[TF_AW-1:0]] <= rq_dout;
            tf_tag[tf_wp[TF_AW-1:0]] <= te_tag[5];
            tf_wp <= tf_wp + 1'(1);
        end
    end


    wire [191:0] dr_acc = tf_acc[tf_rp[TF_AW-1:0]];
    wire [511:0] dr_rq  = tf_rq [tf_rp[TF_AW-1:0]];
    wire [27:0]  dr_tag = tf_tag[tf_rp[TF_AW-1:0]];

    // ------------------------------------------------------------- drain
    // No idle state: the head tile of the FIFO is fed to the lanes as soon as
    // it is there, first half and then second half.  A tile is popped when its
    // second half has been issued, so dr_phase is back at 0 for the next one.
    wire         dr_half  = dr_phase;
    wire         dr_valid = (tile_occ != '0);
    wire [255:0] rq_sel   = dr_half ? dr_rq[511:256] : dr_rq[255:0];
    wire [95:0]  acc_sel  = dr_half ? dr_acc[191:96] : dr_acc[95:0];

    wire [4:0]  dr_g   = {dr_tag[7:4], dr_half};         // output beat of the op
    wire [9:0]  dr_lo  = dr_tag[27:18];
    wire [9:0]  dr_hi  = dr_tag[17:8];

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
    wire [6:0] wb_cout  = wb_lyr ? cout_r[1] : cout_r[0];   // 1..64
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

    logic [42:0]    ofifo [OUT_DEPTH];
    logic [OF_AW:0] of_wp, of_rp;    // one bit more than the index

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            of_wp    <= '0;
            of_rp    <= '0;
            xl2_busy <= 2'd0;
        end else if (start) begin
            of_wp    <= '0;
            of_rp    <= '0;
            xl2_busy <= 2'd0;
        end else begin
            if (issue && !l2_go) xl2_busy[p_iss[0]] <= 1'b1;
            if (lane_out_valid && !wb_final && wb_keep) begin
                xl2[wb_bank][32*wb_g +: 32] <= vec4;
                if (wb_g == (wb_need - 5'd1)) xl2_busy[wb_bank] <= 1'b0;
            end
            if (beat_push) begin
                ofifo[of_wp[OF_AW-1:0]] <= of_din;
                of_wp <= of_wp + 1'(1);
            end
            if (out_valid && out_ready) of_rp <= of_rp + 1'(1);
        end
    end

    assign of_empty  = (of_wp == of_rp);
    assign of_level  = of_wp - of_rp;
    assign out_valid = !of_empty;
    assign {out_sof, out_eol, out_last, out_data} = ofifo[of_rp[OF_AW-1:0]];

    // output beats reserved by issued ops, released one per push
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      pend <= 6'd0;
        else if (start)  pend <= 6'd0;
        else             pend <= pend + 6'(issue && iss_final ? iss_beats : 5'd0)
                                     - 6'(beat_push);
    end

    // ---------------------------------------------------------------- busy
    logic busy_q;

    wire pipe_empty = !op_act && (tile_used == '0) && (tile_occ == '0)
                   && (dr_phase == 1'b0) && !lane_out_valid && of_empty
                   && (pend == 6'd0) && !col_act && (col_pix == p_free)
                   && (n_lay == 2'd1 || (p_l2 == p_iss));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else if (start) begin
            busy_q <= 1'b1;
        end else if (busy_q && pipe_empty && (pix_left == 17'd0)) begin
            busy_q <= 1'b0;
        end
    end

    assign busy = busy_q;

    // ------------------------------------------------- configuration latches
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_lay <= 2'd1;
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



    initial begin
        if (LAT_RQ != 6 || $clog2(OUT_DEPTH) != OF_AW)
            $error("st_pw: pipeline constants disagree with the delay lines");
    end

endmodule
