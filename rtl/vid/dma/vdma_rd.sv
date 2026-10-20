// vdma_rd.sv -- read frames from a frame ring in DDR as a stream.
//
// On each start pulse: acquire a frame from the ring (policy decides whether
// the same frame may come again), read geom.h lines of the crop window
// [x0_beat, x0_beat + nbeats) beats, and release the frame after its last
// beat has arrived.  A start while a frame is still being read is counted as
// late and ignored; the frame in progress completes.
//
// Output words carry sof on the first word of the frame and eol on the last
// word of every line, so the consumer can re-align at any line boundary.
//
// Reads are issued against a credit budget, so the output FIFO cannot
// overflow: words in the FIFO + words requested but not yet arrived + the new
// burst <= FIFO_WORDS.  With ASYNC = 1 the FIFO is dual-clock and o may run on
// another clock (the display), which saves a second FIFO.
module vdma_rd
    import vid_pkg::*;
#(
    parameter int FIFO_WORDS = 512,      // power of two
    parameter int RD_BURST   = 32,       // beats per read burst
    parameter bit ASYNC      = 0
) (
    axi4_rd_if.mst                  m,
    ring_cons_if.user               ring,
    vstream_if.src                  o,

    input  logic [AXI_AW-1:0]       ring_base,
    input  logic                    start,
    input  acq_policy_e             policy,
    input  frame_geom_t             geom,
    input  logic [7:0]              x0_beat,   // crop, sampled at acquire
    input  logic [7:0]              nbeats,

    output logic                    busy,
    output frame_token_t            token,     // frame being read
    output logic [SEQ_W-1:0]        st_frames,
    output logic [SEQ_W-1:0]        st_miss,   // no frame to acquire
    output logic [SEQ_W-1:0]        st_late    // start while still busy
);
    localparam int OW  = $bits(o.data);
    localparam int R   = AXI_DW / OW;
    localparam int LW  = $clog2(FIFO_WORDS);

    initial begin
        if (AXI_DW % OW != 0)
            $error("vdma_rd: word width %0d does not divide the AXI beat", OW);
        if (RD_BURST * R > FIFO_WORDS)
            $error("vdma_rd: one burst does not fit the FIFO");
    end

    // ---------------------------------------------------------- output FIFO
    logic          q_wen;
    logic [OW+1:0] q_wdata;
    logic          q_full;
    logic [LW:0]   q_wlevel;

    if (ASYNC) begin : g_async
        logic [LW:0] unused_rlevel;
        fifo_async_core #(.W(OW + 2), .DEPTH(FIFO_WORDS)) u_fifo (
            .wclk   (m.clk),   .wrst_n (m.rst_n),
            .wen    (q_wen),   .wdata  (q_wdata), .wfull (q_full), .wlevel (q_wlevel),
            .rclk   (o.clk),   .rrst_n (o.rst_n),
            .rready (o.ready), .rvalid (o.valid),
            .rdata  ({o.sof, o.eol, o.data}),     .rlevel (unused_rlevel));
    end else begin : g_sync
        logic [LW:0] lvl;
        fifo_sync_core #(.W(OW + 2), .DEPTH(FIFO_WORDS)) u_fifo (
            .clk    (m.clk),   .rst_n  (m.rst_n),
            .wen    (q_wen),   .wdata  (q_wdata), .wfull (q_full),
            .rready (o.ready), .rvalid (o.valid),
            .rdata  ({o.sof, o.eol, o.data}),     .level (lvl));
        // The word on the output register still occupies a slot.
        assign q_wlevel = lvl + (LW + 1)'(o.valid);
    end

    // ------------------------------------------------------------- control
    typedef enum logic [1:0] { ST_IDLE, ST_ACQ, ST_RUN, ST_REL } state_e;
    state_e state;

    logic [AXI_AW-1:0] base;
    logic [12:0]       lines;
    logic [7:0]        x0, nb;

    // Request side.
    logic [12:0]       y_q;              // line being requested
    logic [7:0]        xb_q;             // beats of that line already requested
    logic [LW+1:0]     inflight;         // words requested, not yet in the FIFO

    // Receive side.
    logic [12:0]       y_r;
    logic [7:0]        xb_r;             // beats of the line received
    logic [AXI_DW-1:0] gear;             // beat being split into words
    logic [$clog2(R+1)-1:0] gear_n;      // words left in gear
    logic [$clog2(R+1)-1:0] gear_i;      // word index within the beat

    wire [7:0] q_remain = nb - xb_q;
    wire [7:0] q_n      = (q_remain > 8'(RD_BURST)) ? 8'(RD_BURST) : q_remain;
    wire       q_more   = (y_q != lines);
    wire       credit   = ((LW + 2)'(q_wlevel) + inflight + (LW + 2)'(q_n) * (LW + 2)'(R))
                          <= (LW + 2)'(FIFO_WORDS);

    wire last_word_of_beat = (gear_i == ($clog2(R+1))'(R - 1));
    wire rx_done           = (y_r == lines);

    assign busy    = (state != ST_IDLE);
    assign m.arid  = '0;
    assign m.rready = (state == ST_RUN) && (gear_n == 0);

    // Words leave gear one per cycle; credit guarantees FIFO room.
    assign q_wen   = (gear_n != 0);
    assign q_wdata = {(y_r == 0) && (xb_r == 0) && (gear_i == 0),        // sof
                      (xb_r == nb - 1'b1) && last_word_of_beat,          // eol
                      gear[OW-1:0]};

    always_ff @(posedge m.clk or negedge m.rst_n) begin
        if (!m.rst_n) begin
            state     <= ST_IDLE;
            base      <= '0;
            lines     <= '0;
            x0        <= '0;
            nb        <= '0;
            y_q       <= '0;
            xb_q      <= '0;
            inflight  <= '0;
            y_r       <= '0;
            xb_r      <= '0;
            gear      <= '0;
            gear_n    <= '0;
            gear_i    <= '0;
            m.arvalid <= 1'b0;
            m.araddr  <= '0;
            m.arlen   <= '0;
            ring.req    <= 1'b0;
            ring.op     <= RING_C_ACQ;
            ring.policy <= ACQ_REPEAT_OK;
            token     <= '0;
            st_frames <= '0;
            st_miss   <= '0;
            st_late   <= '0;
        end else begin
            if (start && state != ST_IDLE)
                st_late <= st_late + 1'b1;

            // Words in flight: + a burst when its AR is accepted, - a word
            // as it enters the FIFO.
            inflight <= inflight
                      + ((m.arvalid && m.arready) ? (LW + 2)'(m.arlen + 1'b1) * (LW + 2)'(R) : '0)
                      - (q_wen ? (LW + 2)'(1) : '0);

            // Split each received beat into words, word 0 first (lowest).
            if (m.rvalid && m.rready) begin
                gear   <= m.rdata;
                gear_n <= ($clog2(R+1))'(R);
                gear_i <= '0;
            end else if (gear_n != 0) begin
                gear   <= gear >> OW;
                gear_n <= gear_n - 1'b1;
                gear_i <= gear_i + 1'b1;
                if (last_word_of_beat) begin
                    if (xb_r == nb - 1'b1) begin
                        xb_r <= '0;
                        y_r  <= y_r + 1'b1;
                    end else begin
                        xb_r <= xb_r + 1'b1;
                    end
                end
            end

            unique case (state)
                ST_IDLE: if (start) begin
                    ring.op     <= RING_C_ACQ;
                    ring.policy <= policy;
                    ring.req    <= 1'b1;
                    state       <= ST_ACQ;
                end

                ST_ACQ: if (ring.ack) begin
                    ring.req <= 1'b0;
                    if (ring.ok) begin
                        token <= ring.token;
                        base  <= slot_base(ring_base, ring.token.slot);
                        lines <= geom.h;
                        x0    <= x0_beat;
                        nb    <= nbeats;
                        y_q   <= '0;
                        xb_q  <= '0;
                        y_r   <= '0;
                        xb_r  <= '0;
                        state <= ST_RUN;
                    end else begin
                        st_miss <= st_miss + 1'b1;
                        state   <= ST_IDLE;
                    end
                end

                ST_RUN: begin
                    if (m.arvalid) begin
                        if (m.arready)
                            m.arvalid <= 1'b0;
                    end else if (q_more && credit) begin
                        m.araddr  <= line_addr(base, y_q[11:0])
                                   + AXI_AW'(x0 + xb_q) * AXI_AW'(BEAT_BYTES);
                        m.arlen   <= q_n - 1'b1;
                        m.arvalid <= 1'b1;
                        if (xb_q + q_n == nb) begin
                            xb_q <= '0;
                            y_q  <= y_q + 1'b1;
                        end else begin
                            xb_q <= xb_q + q_n;
                        end
                    end
                    if (rx_done && gear_n == 0 && !m.arvalid) begin
                        ring.op  <= RING_C_REL;
                        ring.req <= 1'b1;
                        state    <= ST_REL;
                    end
                end

                ST_REL: if (ring.ack) begin
                    ring.req    <= 1'b0;
                    token.valid <= 1'b0;
                    st_frames   <= st_frames + 1'b1;
                    state       <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
