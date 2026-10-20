// frame_ring_core.sv -- slot bookkeeping for one producer and NCONS consumers.
//
// Flat ports on purpose: this is the piece worth checking exhaustively, and
// flat ports keep it usable by tools that do not handle interfaces.  The
// interface view is frame_ring.sv; the contract is in ring_if.sv.
//
// State is kept as facts, and a slot's role is derived from them:
//   WRITING  wr_busy && wr_slot == k
//   LATEST   latest_v && latest == k
//   HELD     rc[k] != 0                (number of consumers reading it)
//   FREE     none of the above
// A slot can be LATEST and HELD at once.  When a newer frame is committed the
// old latest stays HELD until its readers release it, then becomes FREE.
//
// With SLOTS >= NCONS + 2 the producer always finds a free slot: at most
// NCONS slots are held, one is latest, so one more is always free.
module frame_ring_core
    import vid_pkg::*;
#(
    parameter int SLOTS = 4,
    parameter int NCONS = 2
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    p_req,
    input  ring_p_op_e              p_op,
    input  logic [SEQ_W-1:0]        p_src_seq,
    output logic                    p_ack,
    output logic                    p_ok,
    output logic [RING_SLOT_W-1:0]  p_slot,

    input  logic [NCONS-1:0]        c_req,
    input  ring_c_op_e              c_op     [NCONS],
    input  acq_policy_e             c_policy [NCONS],
    output logic [NCONS-1:0]        c_ack,
    output logic [NCONS-1:0]        c_ok,
    output frame_token_t            c_token  [NCONS],

    // Status, for telemetry.  Counters wrap.
    output logic [SEQ_W-1:0]        st_commits,
    output logic [SEQ_W-1:0]        st_drops,     // producer found no free slot
    output logic [SEQ_W-1:0]        st_aborts,
    output logic                    st_proto_err  // sticky: a rule in ring_if.sv was broken
);
    localparam int NREQ = NCONS + 1;           // index 0 = producer
    localparam int RCW  = $clog2(NCONS + 1);
    localparam int SXW  = $clog2(SLOTS);       // bits that index the per-slot arrays

    initial begin
        if (SLOTS > (1 << RING_SLOT_W))
            $error("frame_ring_core: SLOTS exceeds RING_SLOT_W");
        if (SLOTS < NCONS + 2)
            $warning("frame_ring_core: SLOTS < NCONS + 2, the producer can be starved");
    end

    // ----------------------------------------------------------------- state
    logic                    wr_busy;
    logic [RING_SLOT_W-1:0]  wr_slot;
    logic                    latest_v;
    logic [RING_SLOT_W-1:0]  latest;
    logic [SEQ_W-1:0]        seq_ctr;

    logic [RCW-1:0]          rc      [SLOTS];
    logic [SEQ_W-1:0]        seq     [SLOTS];
    logic [SEQ_W-1:0]        src_seq [SLOTS];

    logic [NCONS-1:0]        held_v;
    logic [RING_SLOT_W-1:0]  held    [NCONS];
    logic [NCONS-1:0]        seen_v;   // consumer has acquired something before
    logic [SEQ_W-1:0]        last_seq[NCONS];

    // Slot numbers are RING_SLOT_W wide; the arrays have SLOTS entries.
    function automatic logic [SXW-1:0] sx(input logic [RING_SLOT_W-1:0] slot);
        return slot[SXW-1:0];
    endfunction

    function automatic logic is_free(input int k);
        return !(wr_busy && wr_slot == RING_SLOT_W'(k))
            && !(latest_v && latest == RING_SLOT_W'(k))
            && rc[k] == '0;
    endfunction

    // Lowest free slot.
    logic                   any_free;
    logic [RING_SLOT_W-1:0] free_slot;
    always_comb begin
        any_free  = 1'b0;
        free_slot = '0;
        for (int k = SLOTS - 1; k >= 0; k--) begin
            if (is_free(k)) begin
                any_free  = 1'b1;
                free_slot = RING_SLOT_W'(k);
            end
        end
    end

    // ------------------------------------------------------- arbitration
    // Round robin over {consumers, producer}.  A requester whose ack is out
    // this cycle still has req high; it is masked so it is not served twice.
    logic [NREQ-1:0]         reqv, acked, elig;
    logic [$clog2(NREQ)-1:0] rr, gidx;
    logic                    gvalid;

    assign reqv  = {c_req, p_req};
    assign acked = {c_ack, p_ack};
    assign elig  = reqv & ~acked;

    always_comb begin
        gvalid = 1'b0;
        gidx   = '0;
        for (int n = NREQ - 1; n >= 0; n--) begin
            int i;
            i = (int'(rr) + n) % NREQ;
            if (elig[i]) begin
                gvalid = 1'b1;
                gidx   = ($clog2(NREQ))'(i);
            end
        end
    end

    // ------------------------------------------------------------ update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_busy      <= 1'b0;
            wr_slot      <= '0;
            latest_v     <= 1'b0;
            latest       <= '0;
            seq_ctr      <= '0;
            held_v       <= '0;
            seen_v       <= '0;
            for (int k = 0; k < SLOTS; k++) begin
                rc[k]      <= '0;
                seq[k]     <= '0;
                src_seq[k] <= '0;
            end
            for (int i = 0; i < NCONS; i++) begin
                held[i]     <= '0;
                last_seq[i] <= '0;
                c_token[i]  <= '0;
            end
            p_ack        <= 1'b0;
            p_ok         <= 1'b0;
            p_slot       <= '0;
            c_ack        <= '0;
            c_ok         <= '0;
            rr           <= '0;
            st_commits   <= '0;
            st_drops     <= '0;
            st_aborts    <= '0;
            st_proto_err <= 1'b0;
        end else begin
            p_ack <= 1'b0;
            c_ack <= '0;

            if (gvalid) begin
                rr <= ($clog2(NREQ))'((int'(gidx) + 1) % NREQ);

                if (gidx == 0) begin
                    // ---------------------------------------------- producer
                    p_ack <= 1'b1;
                    unique case (p_op)
                        RING_P_ACQ: begin
                            if (wr_busy) begin
                                p_ok         <= 1'b0;
                                st_proto_err <= 1'b1;
                            end else if (any_free) begin
                                p_ok    <= 1'b1;
                                p_slot  <= free_slot;
                                wr_busy <= 1'b1;
                                wr_slot <= free_slot;
                            end else begin
                                p_ok     <= 1'b0;
                                st_drops <= st_drops + 1'b1;
                            end
                        end
                        RING_P_COMMIT: begin
                            p_ok <= wr_busy;
                            if (wr_busy) begin
                                latest_v         <= 1'b1;
                                latest           <= wr_slot;
                                seq[sx(wr_slot)]     <= seq_ctr;
                                src_seq[sx(wr_slot)] <= p_src_seq;
                                seq_ctr          <= seq_ctr + 1'b1;
                                wr_busy          <= 1'b0;
                                st_commits       <= st_commits + 1'b1;
                            end else begin
                                st_proto_err <= 1'b1;
                            end
                        end
                        RING_P_ABORT: begin
                            p_ok <= wr_busy;
                            if (wr_busy) begin
                                wr_busy   <= 1'b0;
                                st_aborts <= st_aborts + 1'b1;
                            end else begin
                                st_proto_err <= 1'b1;
                            end
                        end
                        default: begin
                            p_ok         <= 1'b0;
                            st_proto_err <= 1'b1;
                        end
                    endcase
                end else begin
                    // ---------------------------------------------- consumer
                    int i;
                    i = int'(gidx) - 1;
                    c_ack[i] <= 1'b1;
                    unique case (c_op[i])
                        RING_C_ACQ: begin
                            if (held_v[i]) begin
                                c_ok[i]      <= 1'b0;
                                st_proto_err <= 1'b1;
                            end else if (!latest_v
                                      || (c_policy[i] == ACQ_NEW_ONLY && seen_v[i]
                                          && seq[sx(latest)] == last_seq[i])) begin
                                c_ok[i] <= 1'b0;
                            end else begin
                                c_ok[i]     <= 1'b1;
                                c_token[i]  <= '{valid: 1'b1, slot: latest,
                                                 seq: seq[sx(latest)], src_seq: src_seq[sx(latest)]};
                                rc[sx(latest)]  <= rc[sx(latest)] + 1'b1;
                                held_v[i]   <= 1'b1;
                                held[i]     <= latest;
                                seen_v[i]   <= 1'b1;
                                last_seq[i] <= seq[sx(latest)];
                            end
                        end
                        RING_C_REL: begin
                            c_ok[i] <= held_v[i];
                            if (held_v[i]) begin
                                rc[sx(held[i])]      <= rc[sx(held[i])] - 1'b1;
                                held_v[i]        <= 1'b0;
                                c_token[i].valid <= 1'b0;
                            end else begin
                                st_proto_err <= 1'b1;
                            end
                        end
                        default: begin
                            c_ok[i]      <= 1'b0;
                            st_proto_err <= 1'b1;
                        end
                    endcase
                end
            end
        end
    end

`ifdef VID_SVA
    // ------------------------------------------------------------ checks
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (gvalid && gidx == 0 && p_op == RING_P_ACQ && !wr_busy && any_free)
                assert (is_free(int'(free_slot)))
                    else $error("%m: producer granted a slot that is not free");
            for (int k = 0; k < SLOTS; k++)
                assert (int'(rc[k]) <= NCONS)
                    else $error("%m: slot %0d has %0d readers", k, rc[k]);
            if (SLOTS >= NCONS + 2)
                assert (!(gvalid && gidx == 0 && p_op == RING_P_ACQ && !wr_busy && !any_free))
                    else $error("%m: no free slot although SLOTS >= NCONS + 2");
            assert (!st_proto_err)
                else $error("%m: ring protocol violated by a requester");
        end
    end
`endif

endmodule
