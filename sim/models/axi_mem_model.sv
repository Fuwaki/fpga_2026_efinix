// axi_mem_model.sv -- behavioural DDR behind an AXI4 write/read port pair.
//
// Sparse memory (associative array of beats), random back-pressure on every
// channel the slave controls, a configurable read latency, and any number of
// outstanding bursts per direction.  Reads return in request order; writes are
// answered with one B per burst, also in order.  Never-written beats read as
// FILL so a test sees stale or missing data instead of zeros.
//
// Backdoor access for scoreboards: peek()/poke() by byte address.
module axi_mem_model #(
    parameter int          AW        = 32,
    parameter int          DW        = 128,
    parameter int          IW        = 4,
    parameter int          READY_PCT = 70,   // chance each ready/valid the slave drives is high
    parameter int          RLAT_MIN  = 4,    // cycles from AR accept to first R beat
    parameter int          RLAT_MAX  = 24,
    parameter logic [DW-1:0] FILL    = {(DW / 32) {32'hDEAD_BEEF}},
    // 1 = do not echo IDs: rid/bid carry the ID of the most recently accepted
    // request instead.  Models a controller that only works for in-order,
    // single-ID masters, so the interconnect must not rely on IDs.
    parameter bit          BAD_IDS   = 0
) (
    axi4_wr_if.slv wr,
    axi4_rd_if.slv rd
);
    localparam int BB = DW / 8;

    logic [DW-1:0] mem [longint unsigned];

    function automatic logic [DW-1:0] peek(input longint unsigned byte_addr);
        longint unsigned k = byte_addr / longint'(BB);
        return mem.exists(k) ? mem[k] : FILL;
    endfunction

    function automatic void poke(input longint unsigned byte_addr, input logic [DW-1:0] v);
        mem[byte_addr / longint'(BB)] = v;
    endfunction

    function automatic bit coin(input int pct);
        return $urandom_range(99) < pct;
    endfunction

    // ---------------------------------------------------------------- write
    typedef struct {
        longint unsigned addr;
        int unsigned     len;
        logic [IW-1:0]   id;
    } burst_t;

    burst_t        aw_q[$];
    logic [IW-1:0] last_awid, last_arid;
    always_ff @(posedge wr.clk) if (wr.awvalid && wr.awready) last_awid <= wr.awid;
    always_ff @(posedge rd.clk) if (rd.arvalid && rd.arready) last_arid <= rd.arid;
    logic [IW-1:0] b_q[$];
    int unsigned   w_beat;

    always_ff @(posedge wr.clk or negedge wr.rst_n) begin
        if (!wr.rst_n) begin
            aw_q.delete();
            b_q.delete();
            w_beat     <= 0;
            wr.awready <= 1'b0;
            wr.wready  <= 1'b0;
            wr.bvalid  <= 1'b0;
            wr.bid     <= '0;
            wr.bresp   <= 2'b00;
        end else begin
            if (wr.awvalid && wr.awready)
                aw_q.push_back('{addr: longint'(wr.awaddr), len: int'(wr.awlen), id: wr.awid});

            if (wr.wvalid && wr.wready) begin
                burst_t h;
                h = aw_q[0];
                mem[(h.addr / longint'(BB)) + longint'(w_beat)] = wr.wdata;
                if (wr.wlast) begin
                    if (w_beat != h.len)
                        $error("%m: wlast on beat %0d, burst has %0d", w_beat, h.len + 1);
                    b_q.push_back(h.id);
                    void'(aw_q.pop_front());
                    w_beat <= 0;
                end else begin
                    w_beat <= w_beat + 1;
                end
            end

            if (wr.bvalid && wr.bready)
                wr.bvalid <= 1'b0;
            if ((!wr.bvalid || wr.bready) && b_q.size() != 0 && coin(READY_PCT)) begin
                wr.bid    <= BAD_IDS ? last_awid : b_q.pop_front();
                if (BAD_IDS) void'(b_q.pop_front());
                wr.bvalid <= 1'b1;
            end

            wr.awready <= coin(READY_PCT);
            // W only once its AW is in (the interconnect would enforce this).
            wr.wready  <= (aw_q.size() != 0 || (wr.awvalid && wr.awready)) && coin(READY_PCT);
        end
    end

    // ----------------------------------------------------------------- read
    typedef struct {
        burst_t      b;
        longint      due;     // cycle the first beat may go out
    } rreq_t;

    rreq_t       ar_q[$];
    int unsigned r_beat;
    longint      cyc;

    always_ff @(posedge rd.clk or negedge rd.rst_n) begin
        if (!rd.rst_n) begin
            ar_q.delete();
            r_beat     <= 0;
            cyc        <= 0;
            rd.arready <= 1'b0;
            rd.rvalid  <= 1'b0;
            rd.rlast   <= 1'b0;
            rd.rid     <= '0;
            rd.rdata   <= '0;
            rd.rresp   <= 2'b00;
        end else begin
            cyc <= cyc + 1;

            if (rd.arvalid && rd.arready)
                ar_q.push_back('{b: '{addr: longint'(rd.araddr), len: int'(rd.arlen), id: rd.arid},
                                 due: cyc + longint'($urandom_range(RLAT_MAX, RLAT_MIN))});

            if (rd.rvalid && rd.rready) begin
                rd.rvalid <= 1'b0;
                if (rd.rlast) begin
                    void'(ar_q.pop_front());
                    r_beat <= 0;
                end else begin
                    r_beat <= r_beat + 1;
                end
            end

            // Present the next beat when the channel is free.
            if (!rd.rvalid || rd.rready) begin
                int unsigned nb;
                // Queue methods act immediately, so if the beat just accepted
                // ended a burst, ar_q[0] is already the next one.
                nb = (rd.rvalid && rd.rready) ? (rd.rlast ? 0 : r_beat + 1) : r_beat;
                if (ar_q.size() != 0 && ar_q[0].due <= cyc && coin(READY_PCT)) begin
                    rreq_t q;
                    q = ar_q[0];
                    rd.rvalid <= 1'b1;
                    rd.rid    <= BAD_IDS ? last_arid : q.b.id;
                    rd.rdata  <= peek(q.b.addr + longint'(nb) * BB);
                    rd.rlast  <= (nb == q.b.len);
                    rd.rresp  <= 2'b00;
                end
            end

            rd.arready <= coin(READY_PCT);
        end
    end
endmodule
