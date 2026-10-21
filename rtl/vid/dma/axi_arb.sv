// axi_arb.sv -- N write masters and M read masters onto one AXI4 port.
//
// Write and read are arbitrated independently.  Within a direction the lower
// master index has priority, except that a master waiting longer than STARVE
// cycles goes first (so a low-priority master is slowed, never stopped).
//
// AXI rules kept:
//   * once an address is offered downstream it stays, unchanged, until
//     accepted: the grant is locked while valid && !ready;
//   * W beats follow AW order: each accepted AW pushes its master index into
//     a small FIFO, and W is taken from the master at its head;
//   * responses go back in issue order, not by ID.  Every request goes
//     downstream with the same ID, so AXI requires the slave to answer in
//     order, and each accepted address pushes {master, master's ID} into an
//     order FIFO that routes the matching response.  The board's DDR
//     controller is encrypted and cannot be shown to echo IDs; with a single
//     ID it does not have to.
//
// Outstanding bursts (address accepted, response not yet complete) are
// limited to MAX_WR writes and MAX_RD reads.  MAX_* = 1 serialises each
// direction the way the original arbiter did.
module axi_arb
    import vid_pkg::*;
#(
    parameter int NW       = 2,
    parameter int NR       = 2,
    parameter int STARVE   = 256,
    parameter int WQ_DEPTH = 8,
    parameter int RQ_DEPTH = 8,
    parameter int MAX_WR   = WQ_DEPTH,
    parameter int MAX_RD   = RQ_DEPTH
) (
    axi4_wr_if.slv sw [NW],
    axi4_rd_if.slv sr [NR],
    axi4_wr_if.mst mw,
    axi4_rd_if.mst mr
);
    localparam int WXW  = $clog2((NW > 1) ? NW : 2);       // write master index bits
    localparam int RXW  = $clog2((NR > 1) ? NR : 2);       // read master index bits

    // ------------------------------------------------- flatten interfaces
    logic [NW-1:0]     aw_v, w_v, w_l, b_r;
    logic [AXI_AW-1:0] aw_a  [NW];
    logic [7:0]        aw_n  [NW];
    logic [AXI_IW-1:0] aw_id [NW];
    logic [AXI_DW-1:0] w_d   [NW];
    logic [NW-1:0]     aw_rdy, w_rdy, b_vld;
    logic [AXI_IW-1:0] b_id, r_id;              // ID of the response being returned

    for (genvar i = 0; i < NW; i++) begin : g_w
        assign aw_v[i]  = sw[i].awvalid;
        assign aw_a[i]  = sw[i].awaddr;
        assign aw_n[i]  = sw[i].awlen;
        assign aw_id[i] = sw[i].awid;
        assign w_v[i]   = sw[i].wvalid;
        assign w_d[i]   = sw[i].wdata;
        assign w_l[i]   = sw[i].wlast;
        assign b_r[i]   = sw[i].bready;
        assign sw[i].awready = aw_rdy[i];
        assign sw[i].wready  = w_rdy[i];
        assign sw[i].bvalid  = b_vld[i];
        assign sw[i].bid     = b_id;
        assign sw[i].bresp   = mw.bresp;
    end

    logic [NR-1:0]     ar_v, r_r;
    logic [AXI_AW-1:0] ar_a  [NR];
    logic [7:0]        ar_n  [NR];
    logic [AXI_IW-1:0] ar_id [NR];
    logic [NR-1:0]     ar_rdy, r_vld;

    for (genvar i = 0; i < NR; i++) begin : g_r
        assign ar_v[i]  = sr[i].arvalid;
        assign ar_a[i]  = sr[i].araddr;
        assign ar_n[i]  = sr[i].arlen;
        assign ar_id[i] = sr[i].arid;
        assign r_r[i]   = sr[i].rready;
        assign sr[i].arready = ar_rdy[i];
        assign sr[i].rvalid  = r_vld[i];
        assign sr[i].rid     = r_id;
        assign sr[i].rdata   = mr.rdata;
        assign sr[i].rresp   = mr.rresp;
        assign sr[i].rlast   = mr.rlast;
    end

    // ------------------------------------------------------ write address
    logic [WXW-1:0]  aw_sel, aw_lock_idx;
    logic           aw_any, aw_locked;
    logic [15:0]    aw_wait [NW];
    logic           wq_full, wq_empty, bq_full;
    logic [WXW-1:0]  wq_head;

    always_comb begin
        aw_any = 1'b0;
        aw_sel = '0;
        for (int i = NW - 1; i >= 0; i--)
            if (aw_v[i]) begin aw_any = 1'b1; aw_sel = WXW'(i); end
        for (int i = NW - 1; i >= 0; i--)
            if (aw_v[i] && aw_wait[i] >= 16'(STARVE)) begin aw_sel = WXW'(i); end
        if (aw_locked)
            aw_sel = aw_lock_idx;
    end

    // Writes outstanding: + AW accepted, - B accepted.
    logic [$clog2(WQ_DEPTH+1):0] wr_out;
    wire aw_go = aw_any && !wq_full && !bq_full && (int'(wr_out) < MAX_WR);

    always_comb begin
        aw_rdy = '0;
        if (aw_go)
            aw_rdy[aw_sel] = mw.awready;
    end
    assign mw.awvalid = aw_go && aw_v[aw_sel];
    assign mw.awaddr  = aw_a[aw_sel];
    assign mw.awlen   = aw_n[aw_sel];
    assign mw.awid    = '0;

    wire aw_fire = mw.awvalid && mw.awready;

    always_ff @(posedge mw.clk or negedge mw.rst_n) begin
        if (!mw.rst_n) begin
            aw_locked   <= 1'b0;
            aw_lock_idx <= '0;
            for (int i = 0; i < NW; i++) aw_wait[i] <= '0;
        end else begin
            aw_locked   <= mw.awvalid && !mw.awready;
            aw_lock_idx <= aw_sel;
            for (int i = 0; i < NW; i++)
                aw_wait[i] <= (aw_v[i] && !(aw_fire && aw_sel == WXW'(i)))
                            ? ((aw_wait[i] != 16'hFFFF) ? aw_wait[i] + 1'b1 : aw_wait[i]) : '0;
        end
    end

    // ------------------------------------------------- write data order
    logic [$clog2(WQ_DEPTH):0] wq_level;
    logic          wq_valid;
    logic          w_fire_last;

    fifo_sync_core #(.W(WXW), .DEPTH(WQ_DEPTH)) u_wq (
        .clk    (mw.clk),
        .rst_n  (mw.rst_n),
        .wen    (aw_fire),
        .wdata  (aw_sel),
        .wfull  (wq_full),
        .rready (w_fire_last),
        .rvalid (wq_valid),
        .rdata  (wq_head),
        .level  (wq_level)
    );
    assign wq_empty = !wq_valid;

    assign mw.wvalid = wq_valid && w_v[wq_head];
    assign mw.wdata  = w_d[wq_head];
    assign mw.wlast  = w_l[wq_head];
    always_comb begin
        w_rdy = '0;
        if (wq_valid)
            w_rdy[wq_head] = mw.wready;
    end
    assign w_fire_last = mw.wvalid && mw.wready && mw.wlast;

    // ----------------------------------------------------- write response
    logic          bq_valid;
    logic [WXW-1:0] b_idx;
    logic [$clog2(WQ_DEPTH):0] bq_level;
    wire           b_fire = mw.bvalid && mw.bready;

    fifo_sync_core #(.W(WXW + AXI_IW), .DEPTH(WQ_DEPTH)) u_bq (
        .clk    (mw.clk),
        .rst_n  (mw.rst_n),
        .wen    (aw_fire),
        .wdata  ({aw_sel, aw_id[aw_sel]}),
        .wfull  (bq_full),
        .rready (b_fire),
        .rvalid (bq_valid),
        .rdata  ({b_idx, b_id}),
        .level  (bq_level)
    );

    always_comb begin
        b_vld = '0;
        b_vld[b_idx] = mw.bvalid && bq_valid;
    end

    always_ff @(posedge mw.clk or negedge mw.rst_n)
        if (!mw.rst_n) wr_out <= '0;
        else           wr_out <= wr_out + $bits(wr_out)'(aw_fire) - $bits(wr_out)'(b_fire);
    assign mw.bready = bq_valid && b_r[b_idx];

    // ------------------------------------------------------- read address
    logic [RXW-1:0] ar_sel, ar_lock_idx;
    logic          ar_any, ar_locked, rq_full;
    logic [15:0]   ar_wait [NR];

    always_comb begin
        ar_any = 1'b0;
        ar_sel = '0;
        for (int i = NR - 1; i >= 0; i--)
            if (ar_v[i]) begin ar_any = 1'b1; ar_sel = RXW'(i); end
        for (int i = NR - 1; i >= 0; i--)
            if (ar_v[i] && ar_wait[i] >= 16'(STARVE)) begin ar_sel = RXW'(i); end
        if (ar_locked)
            ar_sel = ar_lock_idx;
    end

    // Reads outstanding: + AR accepted, - last R beat accepted.
    logic [$clog2(RQ_DEPTH+1):0] rd_out;
    wire ar_go = ar_any && !rq_full && (int'(rd_out) < MAX_RD);

    always_comb begin
        ar_rdy = '0;
        if (ar_go)
            ar_rdy[ar_sel] = mr.arready;
    end
    assign mr.arvalid = ar_go && ar_v[ar_sel];
    assign mr.araddr  = ar_a[ar_sel];
    assign mr.arlen   = ar_n[ar_sel];
    assign mr.arid    = '0;

    wire ar_fire = mr.arvalid && mr.arready;

    always_ff @(posedge mr.clk or negedge mr.rst_n) begin
        if (!mr.rst_n) begin
            ar_locked   <= 1'b0;
            ar_lock_idx <= '0;
            for (int i = 0; i < NR; i++) ar_wait[i] <= '0;
        end else begin
            ar_locked   <= mr.arvalid && !mr.arready;
            ar_lock_idx <= ar_sel;
            for (int i = 0; i < NR; i++)
                ar_wait[i] <= (ar_v[i] && !(ar_fire && ar_sel == RXW'(i)))
                            ? ((ar_wait[i] != 16'hFFFF) ? ar_wait[i] + 1'b1 : ar_wait[i]) : '0;
        end
    end

    // ------------------------------------------------------- read data
    logic          rq_valid;
    logic [RXW-1:0] r_idx;
    logic [$clog2(RQ_DEPTH):0] rq_level;
    wire           r_fire_last = mr.rvalid && mr.rready && mr.rlast;

    fifo_sync_core #(.W(RXW + AXI_IW), .DEPTH(RQ_DEPTH)) u_rq (
        .clk    (mr.clk),
        .rst_n  (mr.rst_n),
        .wen    (ar_fire),
        .wdata  ({ar_sel, ar_id[ar_sel]}),
        .wfull  (rq_full),
        .rready (r_fire_last),
        .rvalid (rq_valid),
        .rdata  ({r_idx, r_id}),
        .level  (rq_level)
    );

    always_comb begin
        r_vld = '0;
        r_vld[r_idx] = mr.rvalid && rq_valid;
    end

    always_ff @(posedge mr.clk or negedge mr.rst_n)
        if (!mr.rst_n) rd_out <= '0;
        else           rd_out <= rd_out + $bits(rd_out)'(ar_fire) - $bits(rd_out)'(r_fire_last);
    assign mr.rready = rq_valid && r_r[r_idx];

endmodule
