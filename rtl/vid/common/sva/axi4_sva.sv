// axi4_sva.sv -- AXI4 protocol checkers for axi4_wr_if / axi4_rd_if,
// simulation only.  Bound to every instance by sim/bind/vid_bind.sv.
//
// Checked: valid/ready stability on every channel, wlast exactly on beat
// len+1, rlast exactly on beat len+1 of the matching burst, no burst crosses a
// 4 KiB boundary, no response without an outstanding request.

module axi4_wr_sva #(
    parameter int AW = 32,
    parameter int DW = 128,
    parameter int IW = 4
) (
    input logic          clk,
    input logic          rst_n,
    input logic [IW-1:0] awid,
    input logic [AW-1:0] awaddr,
    input logic [7:0]    awlen,
    input logic          awvalid,
    input logic          awready,
    input logic [DW-1:0] wdata,
    input logic          wlast,
    input logic          wvalid,
    input logic          wready,
    input logic [IW-1:0] bid,
    input logic [1:0]    bresp,
    input logic          bvalid,
    input logic          bready
);
    localparam int BB = DW / 8;

    a_aw_hold: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid && !awready |=> awvalid && $stable({awid, awaddr, awlen}))
        else $error("%m: AW changed before acceptance");
    a_w_hold: assert property (@(posedge clk) disable iff (!rst_n)
        wvalid && !wready |=> wvalid && $stable({wdata, wlast}))
        else $error("%m: W changed before acceptance");
    a_b_hold: assert property (@(posedge clk) disable iff (!rst_n)
        bvalid && !bready |=> bvalid && $stable({bid, bresp}))
        else $error("%m: B changed before acceptance");

    a_aw_4k: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid |-> (int'(awaddr[11:0]) + (int'(awlen) + 1) * BB) <= 4096)
        else $error("%m: write burst crosses 4 KiB: addr %h len %0d", awaddr, awlen);
    a_aw_align: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid |-> awaddr[$clog2(BB)-1:0] == '0)
        else $error("%m: unaligned write address %h", awaddr);

    // W beats follow AW order (AXI4 has no write interleaving).
    int unsigned lens[$];
    int unsigned beat;
    int unsigned outstanding_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lens.delete();
            beat          <= 0;
            outstanding_b <= 0;
        end else begin
            if (awvalid && awready)
                lens.push_back(int'(awlen));
            if (wvalid && wready) begin
                if (lens.size() == 0 && !(awvalid && awready))
                    $error("%m: W beat with no accepted AW");
                else begin
                    int unsigned want;
                    want = (lens.size() != 0) ? lens[0] : int'(awlen);
                    if (wlast != (beat == want))
                        $error("%m: wlast %0b on beat %0d of a %0d-beat burst", wlast, beat, want + 1);
                    if (wlast) begin
                        void'(lens.pop_front());
                        beat <= 0;
                    end else begin
                        beat <= beat + 1;
                    end
                end
            end
            outstanding_b <= outstanding_b
                           + ((wvalid && wready && wlast) ? 1 : 0)
                           - ((bvalid && bready) ? 1 : 0);
            if (bvalid && bready && outstanding_b == 0 && !(wvalid && wready && wlast))
                $error("%m: B response with no completed write burst");
        end
    end
endmodule


module axi4_rd_sva #(
    parameter int AW = 32,
    parameter int DW = 128,
    parameter int IW = 4
) (
    input logic          clk,
    input logic          rst_n,
    input logic [IW-1:0] arid,
    input logic [AW-1:0] araddr,
    input logic [7:0]    arlen,
    input logic          arvalid,
    input logic          arready,
    input logic [IW-1:0] rid,
    input logic [DW-1:0] rdata,
    input logic [1:0]    rresp,
    input logic          rlast,
    input logic          rvalid,
    input logic          rready
);
    localparam int BB = DW / 8;

    a_ar_hold: assert property (@(posedge clk) disable iff (!rst_n)
        arvalid && !arready |=> arvalid && $stable({arid, araddr, arlen}))
        else $error("%m: AR changed before acceptance");
    a_r_hold: assert property (@(posedge clk) disable iff (!rst_n)
        rvalid && !rready |=> rvalid && $stable({rid, rdata, rresp, rlast}))
        else $error("%m: R changed before acceptance");
    a_ar_4k: assert property (@(posedge clk) disable iff (!rst_n)
        arvalid |-> (int'(araddr[11:0]) + (int'(arlen) + 1) * BB) <= 4096)
        else $error("%m: read burst crosses 4 KiB: addr %h len %0d", araddr, arlen);
    a_ar_align: assert property (@(posedge clk) disable iff (!rst_n)
        arvalid |-> araddr[$clog2(BB)-1:0] == '0)
        else $error("%m: unaligned read address %h", araddr);

    // Per-ID in-order bursts; different IDs may interleave between bursts.
    int unsigned pend[int][$];
    int unsigned beat[int];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend.delete();
            beat.delete();
        end else begin
            if (arvalid && arready)
                pend[int'(arid)].push_back(int'(arlen));
            if (rvalid && rready) begin
                int id;
                id = int'(rid);
                if (!pend.exists(id) || pend[id].size() == 0)
                    $error("%m: R beat for id %0d with no outstanding burst", id);
                else begin
                    int unsigned b;
                    b = beat.exists(id) ? beat[id] : 0;
                    if (rlast != (b == pend[id][0]))
                        $error("%m: rlast %0b on beat %0d of a %0d-beat burst (id %0d)",
                               rlast, b, pend[id][0] + 1, id);
                    if (rlast) begin
                        void'(pend[id].pop_front());
                        beat[id] = 0;
                    end else begin
                        beat[id] = b + 1;
                    end
                end
            end
        end
    end
endmodule
