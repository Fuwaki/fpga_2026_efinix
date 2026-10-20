// tb_ring.sv -- frame_ring against a reference model.
//
// One producer and NCONS consumers act at random: the producer acquires,
// "writes" for a while, then commits or (sometimes) aborts; consumer 0 uses
// REPEAT_OK like the display, the others NEW_ONLY like a processing stage.
// Every ack is checked against ring_model, and every cycle the TB checks the
// property the whole contract exists for: the slot being written is never
// held by a consumer.
package tb_ring_pkg;
    import vid_pkg::*;

    class ring_model;
        int slots, ncons;
        bit wr_busy;  int wr_slot;
        bit latest_v; int latest;
        int seq_ctr;
        int rc[], seq[], src[];
        bit held_v[], seen_v[];
        int held[], last_seq[];

        function new(int s, int n);
            slots = s; ncons = n;
            rc = new[s]; seq = new[s]; src = new[s];
            held_v = new[n]; seen_v = new[n]; held = new[n]; last_seq = new[n];
        endfunction

        function bit is_free(int k);
            return !(wr_busy && wr_slot == k) && !(latest_v && latest == k) && rc[k] == 0;
        endfunction

        function void p_op(ring_p_op_e op, int src_seq, output bit ok, output int slot);
            ok = 0; slot = -1;
            case (op)
                RING_P_ACQ:
                    for (int k = 0; k < slots; k++)
                        if (!wr_busy && is_free(k)) begin
                            ok = 1; slot = k; wr_busy = 1; wr_slot = k;
                            break;
                        end
                RING_P_COMMIT:
                    if (wr_busy) begin
                        ok = 1; latest_v = 1; latest = wr_slot;
                        seq[wr_slot] = seq_ctr % (1 << SEQ_W); src[wr_slot] = src_seq;
                        seq_ctr++; wr_busy = 0;
                    end
                RING_P_ABORT:
                    if (wr_busy) begin
                        ok = 1; wr_busy = 0;
                    end
                default: ;
            endcase
        endfunction

        function void c_op(int i, ring_c_op_e op, acq_policy_e pol,
                           output bit ok, output frame_token_t tok);
            ok = 0; tok = '0;
            if (op == RING_C_ACQ) begin
                if (!held_v[i] && latest_v
                    && !(pol == ACQ_NEW_ONLY && seen_v[i] && seq[latest] == last_seq[i])) begin
                    ok = 1;
                    tok = '{valid: 1'b1, slot: RING_SLOT_W'(latest),
                            seq: SEQ_W'(seq[latest]), src_seq: SEQ_W'(src[latest])};
                    rc[latest]++; held_v[i] = 1; held[i] = latest;
                    seen_v[i] = 1; last_seq[i] = seq[latest];
                end
            end else if (held_v[i]) begin
                ok = 1; rc[held[i]]--; held_v[i] = 0;
            end
        endfunction
    endclass
endpackage


module tb_ring #(
    parameter int SLOTS  = 4,
    parameter int NCONS  = 2,
    parameter int CYCLES = 200000
);
    import vid_pkg::*;
    import tb_ring_pkg::*;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1;
    end

    ring_prod_if p ();
    ring_cons_if c [NCONS] ();
    ring_status_t status;

    frame_ring #(.SLOTS(SLOTS), .NCONS(NCONS)) dut (
        .clk(clk), .rst_n(rst_n), .p(p), .c(c), .status(status));

    ring_model model = new(SLOTS, NCONS);
    int errors = 0;

    // Timing discipline: the DUT changes on posedge, the scoreboard samples on
    // negedge, and the agents act 1 ps after negedge.  Nothing samples and
    // drives at the same instant, so the result does not depend on the
    // simulator's scheduling order.
    task automatic tick();
        @(negedge clk);
        #1ps;
    endtask

    // ---------------------------------------------------------- producer
    int p_writing_slot = -1;
    int n_commit = 0, n_abort = 0, n_drop = 0;

    initial begin
        p.req = 0; p.op = RING_P_ACQ; p.src_seq = '0;
        wait (rst_n);
        forever begin
            repeat ($urandom_range(30)) tick();
            p.op = RING_P_ACQ; p.req = 1;
            do tick(); while (!p.ack);
            p.req = 0;
            if (!p.ok) begin
                n_drop++;
                continue;
            end
            p_writing_slot = int'(p.slot);
            repeat ($urandom_range(60, 5)) tick();
            p.op      = ($urandom_range(9) == 0) ? RING_P_ABORT : RING_P_COMMIT;
            p.src_seq = SEQ_W'($urandom());
            p.req     = 1;
            do tick(); while (!p.ack);
            p.req = 0;
            p_writing_slot = -1;
            if (p.op == RING_P_COMMIT) n_commit++; else n_abort++;
        end
    end

    // --------------------------------------------------------- consumers
    int c_ok_cnt [NCONS];
    int c_miss   [NCONS];
    int held_slot[NCONS];

    for (genvar i = 0; i < NCONS; i++) begin : g_cons
        initial begin
            c[i].req = 0; c[i].op = RING_C_ACQ;
            c[i].policy = (i == 0) ? ACQ_REPEAT_OK : ACQ_NEW_ONLY;
            c_ok_cnt[i] = 0; c_miss[i] = 0; held_slot[i] = -1;
            wait (rst_n);
            forever begin
                repeat ($urandom_range(40)) tick();
                c[i].op = RING_C_ACQ; c[i].req = 1;
                do tick(); while (!c[i].ack);
                c[i].req = 0;
                if (!c[i].ok) begin
                    c_miss[i]++;
                    continue;
                end
                c_ok_cnt[i]++;
                held_slot[i] = int'(c[i].token.slot);
                repeat ($urandom_range(120, 1)) tick();
                c[i].op = RING_C_REL; c[i].req = 1;
                do tick(); while (!c[i].ack);
                c[i].req = 0;
                held_slot[i] = -1;
            end
        end
    end

    // ------------------------------------------- scoreboard and invariant
    logic [NCONS-1:0] c_ack_v, c_ok_v;
    ring_c_op_e       c_op_v  [NCONS];
    acq_policy_e      c_pol_v [NCONS];
    frame_token_t     c_tok_v [NCONS];
    for (genvar i = 0; i < NCONS; i++) begin : g_tap
        assign c_ack_v[i] = c[i].ack;
        assign c_ok_v[i]  = c[i].ok;
        assign c_op_v[i]  = c[i].op;
        assign c_pol_v[i] = c[i].policy;
        assign c_tok_v[i] = c[i].token;
    end

    always @(negedge clk) begin
        if (rst_n) begin
            if (p.ack) begin
                bit ok; int slot;
                model.p_op(p.op, int'(p.src_seq), ok, slot);
                if (ok != p.ok || (p.op == RING_P_ACQ && ok && slot != int'(p.slot))) begin
                    errors++;
                    $error("producer op %s: dut ok %0b slot %0d, model ok %0b slot %0d",
                           p.op.name(), p.ok, p.slot, ok, slot);
                end
            end
            for (int i = 0; i < NCONS; i++) begin
                if (c_ack_v[i]) begin
                    bit ok; frame_token_t tok;
                    model.c_op(i, c_op_v[i], c_pol_v[i], ok, tok);
                    if (ok != c_ok_v[i] || (c_op_v[i] == RING_C_ACQ && ok && tok != c_tok_v[i])) begin
                        errors++;
                        $error("consumer %0d op %s: dut ok %0b tok %p, model ok %0b tok %p",
                               i, c_op_v[i].name(), c_ok_v[i], c_tok_v[i], ok, tok);
                    end
                end
                if (p_writing_slot >= 0 && held_slot[i] == p_writing_slot) begin
                    errors++;
                    $error("consumer %0d holds slot %0d while the producer writes it", i, p_writing_slot);
                end
            end
        end
    end

    initial begin
        wait (rst_n);
        repeat (CYCLES) @(posedge clk);
        $display("tb_ring SLOTS=%0d NCONS=%0d: commits %0d aborts %0d drops %0d (dut %0d/%0d/%0d)",
                 SLOTS, NCONS, n_commit, n_abort, n_drop,
                 status.commits, status.aborts, status.drops);
        for (int i = 0; i < NCONS; i++)
            $display("  consumer %0d (%s): %0d frames, %0d misses", i,
                     (i == 0) ? "REPEAT_OK" : "NEW_ONLY", c_ok_cnt[i], c_miss[i]);
        if (errors != 0 || status.proto_err || n_commit < 100)
            $fatal(1, "tb_ring FAIL: %0d errors, proto_err %0b", errors, status.proto_err);
        if (SLOTS >= NCONS + 2 && n_drop != 0)
            $fatal(1, "tb_ring FAIL: %0d drops with SLOTS >= NCONS + 2", n_drop);
        $display("tb_ring PASS");
        $finish;
    end
endmodule
