// axi4_if.sv -- AXI4 write and read channel pairs, one interface each.
//
// Read and write are independent everywhere in this subsystem: a DMA either
// reads or writes, and the arbiter grants the two directions separately.  So
// they are separate interfaces rather than one interface with modports.
//
// Only INCR bursts of full-width beats are used.  Attributes that never vary
// (size, burst type, cache, prot, lock, qos, strobes) are fixed at the DDR
// boundary in vid_subsystem and are not carried here.
//
// Contract (checked by sva/axi4_sva.sv): standard AXI4 valid/ready stability,
// wlast on beat len+1, no burst crosses a 4 KiB boundary, responses only for
// outstanding IDs.

interface axi4_wr_if #(
    parameter int AW = 32,
    parameter int DW = 128,
    parameter int IW = 4
) (
    input logic clk,
    input logic rst_n
);
    logic [IW-1:0]   awid;
    logic [AW-1:0]   awaddr;
    logic [7:0]      awlen;
    logic            awvalid;
    logic            awready;

    logic [DW-1:0]   wdata;
    logic            wlast;
    logic            wvalid;
    logic            wready;

    logic [IW-1:0]   bid;
    logic [1:0]      bresp;
    logic            bvalid;
    logic            bready;

    modport mst (input  clk, rst_n, awready, wready, bid, bresp, bvalid,
                 output awid, awaddr, awlen, awvalid, wdata, wlast, wvalid, bready);
    modport slv (input  clk, rst_n, awid, awaddr, awlen, awvalid, wdata, wlast, wvalid, bready,
                 output awready, wready, bid, bresp, bvalid);
    modport mon (input  clk, rst_n, awid, awaddr, awlen, awvalid, awready,
                        wdata, wlast, wvalid, wready, bid, bresp, bvalid, bready);
endinterface

interface axi4_rd_if #(
    parameter int AW = 32,
    parameter int DW = 128,
    parameter int IW = 4
) (
    input logic clk,
    input logic rst_n
);
    logic [IW-1:0]   arid;
    logic [AW-1:0]   araddr;
    logic [7:0]      arlen;
    logic            arvalid;
    logic            arready;

    logic [IW-1:0]   rid;
    logic [DW-1:0]   rdata;
    logic [1:0]      rresp;
    logic            rlast;
    logic            rvalid;
    logic            rready;

    modport mst (input  clk, rst_n, arready, rid, rdata, rresp, rlast, rvalid,
                 output arid, araddr, arlen, arvalid, rready);
    modport slv (input  clk, rst_n, arid, araddr, arlen, arvalid, rready,
                 output arready, rid, rdata, rresp, rlast, rvalid);
    modport mon (input  clk, rst_n, arid, araddr, arlen, arvalid, arready,
                        rid, rdata, rresp, rlast, rvalid, rready);
endinterface
