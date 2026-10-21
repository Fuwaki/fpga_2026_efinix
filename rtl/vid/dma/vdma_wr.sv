// vdma_wr.sv -- write a stream of frames into a frame ring in DDR.
//
// Input: a vstream of words (any width that divides the AXI beat), framed by
// sof/eol.  Each frame is geom.h lines of geom.w pixels; a line starts at
// line_addr(slot_base, y) and is written with bursts of up to MAX_BURST beats.
//
// Frame handling, all on the AXI side of the input FIFO:
//   * a word tagged sof at the FIFO head starts a frame: acquire a slot;
//     no slot -> skip the frame;
//   * words are packed into AXI beats before the FIFO, so the FIFO holds
//     whole beats and W runs at one beat per clock (packing behind the FIFO
//     held the DDR port four clocks per beat);
//   * a burst is issued only when all of its beats are already in the FIFO,
//     so W never waits on the input;
//   * every beat's sof/eol tags are checked against the geometry, and the
//     packer marks a beat whose words carried a tag in the wrong place; a
//     short, long or torn frame is aborted, never committed;
//   * the frame is committed after the B response of its last burst, so a
//     consumer can never see a partly written frame.
//
// The signature is a rotate-xor over the frame's words in order, so a test
// or the host can predict it: sig = rotl(sig, 1) ^ word, starting at 0.
module vdma_wr
    import vid_pkg::*;
#(
    parameter int FIFO_BEATS = 512      // power of two, >= one burst
) (
    vstream_if.snk                  s,
    axi4_wr_if.mst                  m,
    ring_prod_if.user               ring,

    input  logic [AXI_AW-1:0]       ring_base,
    input  frame_geom_t             geom,       // sampled at each frame start
    input  logic [SEQ_W-1:0]        src_seq,    // sampled when the frame's slot is acquired

    output logic [SEQ_W-1:0]        st_frames,  // committed
    output logic [SEQ_W-1:0]        st_skipped, // no free slot
    output logic [SEQ_W-1:0]        st_errors,  // aborted or resynchronised
    output logic [31:0]             st_sig      // signature of the last committed frame
);
    localparam int IW  = $bits(s.data);
    localparam int R   = AXI_DW / IW;           // words per beat
    localparam int PPW = BEAT_PIX / R;          // pixels per word
    localparam int LW  = $clog2(FIFO_BEATS);
    localparam int RW  = $clog2(R + 1);

    initial begin
        if (AXI_DW % IW != 0 || BEAT_PIX % R != 0)
            $error("vdma_wr: word width %0d does not divide the AXI beat", IW);
        if (FIFO_BEATS < MAX_BURST)
            $warning("vdma_wr: FIFO_BEATS smaller than one full burst");
    end

    // ---------------------------------------------------------------- packer
    // Words fill a beat, word 0 lowest.  Tags are kept per beat: sof of word
    // 0, eol of the last word, and bad if any word carried a tag elsewhere.
    // An eol in mid-beat closes the beat early (bad), so the next line still
    // starts on a beat boundary.
    logic [AXI_DW-1:0] pk_data;
    logic [RW-1:0]     pk_n;
    logic              pk_sof, pk_bad;
    logic              pw_en;
    logic [AXI_DW+2:0] pw_data;           // {sof, eol, bad, beat}
    logic              f_full;

    assign s.ready = !f_full;

    always_ff @(posedge s.clk or negedge s.rst_n) begin
        if (!s.rst_n) begin
            pk_data <= '0;
            pk_n    <= '0;
            pk_sof  <= 1'b0;
            pk_bad  <= 1'b0;
            pw_en   <= 1'b0;
            pw_data <= '0;
        end else begin
            pw_en <= 1'b0;
            if (s.valid && s.ready) begin
                logic [AXI_DW-1:0] d;
                logic              first, last, sof_b, bad;
                first = (pk_n == 0);
                last  = (pk_n == RW'(R - 1)) || s.eol;
                d     = first ? '0 : pk_data;
                d[int'(pk_n) * IW +: IW] = s.data;
                sof_b = first ? s.sof : pk_sof;
                bad   = (first ? 1'b0 : pk_bad) || (s.sof && !first)
                      || (s.eol && pk_n != RW'(R - 1));
                if (last) begin
                    pw_en   <= 1'b1;
                    pw_data <= {sof_b, s.eol, bad, d};
                    pk_n    <= '0;
                end else begin
                    pk_data <= d;
                    pk_sof  <= sof_b;
                    pk_bad  <= bad;
                    pk_n    <= pk_n + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------ beat FIFO
    // The packer may still deliver one beat after full rises, so full is
    // raised one beat early.
    logic              f_valid, f_ready, f_sof, f_eol, f_bad;
    logic [AXI_DW-1:0] f_data;
    logic [LW:0]       f_level;
    logic              f_wfull;

    fifo_sync_core #(.W(AXI_DW + 3), .DEPTH(FIFO_BEATS)) u_fifo (
        .clk    (s.clk),
        .rst_n  (s.rst_n),
        .wen    (pw_en),
        .wdata  (pw_data),
        .wfull  (f_wfull),
        .rready (f_ready),
        .rvalid (f_valid),
        .rdata  ({f_sof, f_eol, f_bad, f_data}),
        .level  (f_level)
    );
    assign f_full = f_wfull || (f_level >= (LW + 1)'(FIFO_BEATS - 2));

    // Beats available, including the one on the FIFO output register.
    wire [LW+1:0] f_avail = (LW + 2)'(f_level) + (LW + 2)'(f_valid);

    // ---------------------------------------------------------- frame state
    typedef enum logic [3:0] {
        ST_IDLE, ST_ACQ, ST_SKIP, ST_PLAN, ST_AW, ST_DATA,
        ST_FIN, ST_COMMIT, ST_ABORT
    } state_e;
    state_e state;

    logic [AXI_AW-1:0] base;
    logic [12:0]       lines, beats_per_line;
    logic [12:0]       y;
    logic [12:0]       xb;          // beat index within the line
    logic [8:0]        n;           // beats in the current burst
    logic [8:0]        bi;          // beats of the burst sent to W so far
    logic              ferr;        // current frame is bad
    logic [31:0]       sig;
    logic [7:0]        b_out;       // bursts written but not yet acknowledged
    logic              skip_head;   // ST_SKIP must drop the sof word at the head
    logic              resync;      // discarding words that belong to no frame
    logic [SEQ_W-1:0]  f_src_seq;   // src_seq of the frame being written

    wire [12:0] remain   = beats_per_line - xb;
    wire [8:0]  burst_n  = (remain > 13'(MAX_BURST)) ? 9'(MAX_BURST) : 9'(remain);

    // W path: one beat per clock from the FIFO into the W register.
    wire w_free = !m.wvalid || m.wready;
    wire w_take = (state == ST_DATA) && f_valid && (bi != n) && w_free;
    wire w_done = (state == ST_DATA) && (bi == n) && (!m.wvalid || (m.wready && m.wlast));

    // Expected tags of the beat at the FIFO head.
    wire [12:0] beat_in_line = xb + 13'(bi);
    wire        exp_sof      = (y == 0) && (beat_in_line == 0);
    wire        exp_eol      = (beat_in_line == beats_per_line - 1'b1);

    // Signature over the beat's words in order.
    function automatic logic [31:0] sig_beat(input logic [31:0] sg, input logic [AXI_DW-1:0] b);
        for (int k = 0; k < R; k++)
            sg = {sg[30:0], sg[31]} ^ 32'(b[k * IW +: IW]);
        return sg;
    endfunction

    wire b_done = m.bvalid && m.bready;
    wire w_last = m.wvalid && m.wready && m.wlast;

    always_comb begin
        f_ready = 1'b0;
        unique case (state)
            ST_IDLE: f_ready = f_valid && !f_sof;            // resynchronise
            ST_SKIP: f_ready = f_valid && (skip_head || !f_sof);
            ST_DATA: f_ready = w_take;
            default: f_ready = 1'b0;
        endcase
    end

    assign m.awid   = '0;
    assign m.bready = 1'b1;

    always_ff @(posedge s.clk or negedge s.rst_n) begin
        if (!s.rst_n) begin
            state          <= ST_IDLE;
            base           <= '0;
            lines          <= '0;
            beats_per_line <= '0;
            y              <= '0;
            xb             <= '0;
            n              <= '0;
            bi             <= '0;
            ferr           <= 1'b0;
            sig            <= '0;
            b_out          <= '0;
            skip_head      <= 1'b0;
            resync         <= 1'b0;
            f_src_seq      <= '0;
            ring.req       <= 1'b0;
            ring.op        <= RING_P_ACQ;
            ring.src_seq   <= '0;
            m.awvalid      <= 1'b0;
            m.awaddr       <= '0;
            m.awlen        <= '0;
            m.wvalid       <= 1'b0;
            m.wdata        <= '0;
            m.wlast        <= 1'b0;
            st_frames      <= '0;
            st_skipped     <= '0;
            st_errors      <= '0;
            st_sig         <= '0;
        end else begin
            b_out <= b_out + (w_last ? 8'd1 : 8'd0) - (b_done ? 8'd1 : 8'd0);
            if (b_done && m.bresp != 2'b00)
                ferr <= 1'b1;

            unique case (state)
                ST_IDLE: begin
                    if (f_valid && f_sof) begin
                        resync   <= 1'b0;
                        ring.op  <= RING_P_ACQ;
                        ring.req <= 1'b1;
                        state    <= ST_ACQ;
                    end else if (f_valid && !resync) begin
                        resync    <= 1'b1;                 // words outside a frame
                        st_errors <= st_errors + 1'b1;
                    end
                end

                ST_ACQ: if (ring.ack) begin
                    ring.req <= 1'b0;
                    if (ring.ok) begin
                        base           <= slot_base(ring_base, ring.slot);
                        lines          <= geom.h;
                        beats_per_line <= geom.w / 13'(BEAT_PIX);
                        y              <= '0;
                        xb             <= '0;
                        ferr           <= 1'b0;
                        sig            <= '0;
                        f_src_seq      <= src_seq;
                        state          <= ST_PLAN;
                    end else begin
                        st_skipped <= st_skipped + 1'b1;
                        skip_head  <= 1'b1;
                        state      <= ST_SKIP;
                    end
                end

                ST_SKIP: begin
                    if (f_valid && f_ready)
                        skip_head <= 1'b0;
                    if (f_valid && f_sof && !skip_head)
                        state <= ST_IDLE;
                end

                ST_PLAN: begin
                    if (ferr) begin
                        state <= ST_ABORT;
                    end else if (y == lines) begin
                        state <= ST_FIN;
                    end else if (f_valid && f_sof && !(y == 0 && xb == 0)) begin
                        // The next frame started early: this one is short.
                        // Leave its sof at the head for the next frame.
                        ferr  <= 1'b1;
                        state <= ST_ABORT;
                    end else if (f_avail >= (LW + 2)'(burst_n)) begin
                        n         <= burst_n;
                        bi        <= '0;
                        m.awaddr  <= line_addr(base, y[11:0]) + AXI_AW'(xb) * AXI_AW'(BEAT_BYTES);
                        m.awlen   <= 8'(burst_n - 1'b1);
                        m.awvalid <= 1'b1;
                        state     <= ST_AW;
                    end
                end

                ST_AW: if (m.awready) begin
                    m.awvalid <= 1'b0;
                    state     <= ST_DATA;
                end

                ST_DATA: begin
                    // The W register empties when its beat is taken; a new
                    // beat below overrides this.
                    if (m.wvalid && m.wready) begin
                        m.wvalid <= 1'b0;
                        m.wlast  <= 1'b0;
                    end
                    if (w_take) begin
                        sig <= sig_beat(sig, f_data);
                        if (f_sof != exp_sof || f_eol != exp_eol || f_bad)
                            ferr <= 1'b1;
                        m.wvalid <= 1'b1;
                        m.wdata  <= f_data;
                        m.wlast  <= (bi == n - 1'b1);
                        bi       <= bi + 1'b1;
                    end
                    if (w_done) begin
                        if (xb + 13'(n) == beats_per_line) begin
                            xb <= '0;
                            y  <= y + 1'b1;
                        end else begin
                            xb <= xb + 13'(n);
                        end
                        state <= ST_PLAN;
                    end
                end

                ST_FIN: if (b_out == 0 && !b_done) begin
                    if (ferr) begin
                        state <= ST_ABORT;
                    end else begin
                        ring.op      <= RING_P_COMMIT;
                        ring.src_seq <= f_src_seq;
                        ring.req     <= 1'b1;
                        state        <= ST_COMMIT;
                    end
                end

                ST_COMMIT: if (ring.ack) begin
                    ring.req  <= 1'b0;
                    st_frames <= st_frames + 1'b1;
                    st_sig    <= sig;
                    state     <= ST_IDLE;
                end

                // Wait for outstanding writes, then give the slot back.
                ST_ABORT: begin
                    if (!ring.req && b_out == 0 && !b_done) begin
                        ring.op  <= RING_P_ABORT;
                        ring.req <= 1'b1;
                    end else if (ring.req && ring.ack) begin
                        ring.req  <= 1'b0;
                        st_errors <= st_errors + 1'b1;
                        state     <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
