// axi2_pri_arb.v -- 2-master AXI4 priority arbiter (M0 > M1), 128-bit
// M0 = frame_buffer (hi). M1 = st_accel (lo). Slave = ddr3_top.
// Lock-based grant + combinational mux (no registered beat path).
module axi2_pri_arb #(
    parameter AW = 32,
    parameter DW = 128,
    parameter IW = 4
) (
    input  wire clk,
    input  wire rst_n,

    input  wire [IW-1:0]   m0_awid,  input  wire [AW-1:0] m0_awaddr,
    input  wire [7:0] m0_awlen, input wire [2:0] m0_awsize, input wire [1:0] m0_awburst,
    input  wire m0_awlock, input wire [3:0] m0_awcache, input wire [2:0] m0_awprot,
    input  wire m0_awvalid, output wire m0_awready,
    input  wire [DW-1:0] m0_wdata, input wire [DW/8-1:0] m0_wstrb,
    input  wire m0_wlast, input wire m0_wvalid, output wire m0_wready,
    output wire [IW-1:0] m0_bid, output wire [1:0] m0_bresp,
    output wire m0_bvalid, input wire m0_bready,
    input  wire [IW-1:0] m0_arid, input wire [AW-1:0] m0_araddr,
    input  wire [7:0] m0_arlen, input wire [2:0] m0_arsize, input wire [1:0] m0_arburst,
    input  wire m0_arlock, input wire [3:0] m0_arcache, input wire [2:0] m0_arprot,
    input  wire m0_arvalid, output wire m0_arready,
    output wire [IW-1:0] m0_rid, output wire [DW-1:0] m0_rdata, output wire [1:0] m0_rresp,
    output wire m0_rlast, output wire m0_rvalid, input wire m0_rready,

    input  wire [IW-1:0]   m1_awid,  input  wire [AW-1:0] m1_awaddr,
    input  wire [7:0] m1_awlen, input wire [2:0] m1_awsize, input wire [1:0] m1_awburst,
    input  wire m1_awlock, input wire [3:0] m1_awcache, input wire [2:0] m1_awprot,
    input  wire m1_awvalid, output wire m1_awready,
    input  wire [DW-1:0] m1_wdata, input wire [DW/8-1:0] m1_wstrb,
    input  wire m1_wlast, input wire m1_wvalid, output wire m1_wready,
    output wire [IW-1:0] m1_bid, output wire [1:0] m1_bresp,
    output wire m1_bvalid, input wire m1_bready,
    input  wire [IW-1:0] m1_arid, input wire [AW-1:0] m1_araddr,
    input  wire [7:0] m1_arlen, input wire [2:0] m1_arsize, input wire [1:0] m1_arburst,
    input  wire m1_arlock, input wire [3:0] m1_arcache, input wire [2:0] m1_arprot,
    input  wire m1_arvalid, output wire m1_arready,
    output wire [IW-1:0] m1_rid, output wire [DW-1:0] m1_rdata, output wire [1:0] m1_rresp,
    output wire m1_rlast, output wire m1_rvalid, input wire m1_rready,

    output wire [IW-1:0] s_awid, output wire [AW-1:0] s_awaddr,
    output wire [7:0] s_awlen, output wire [2:0] s_awsize, output wire [1:0] s_awburst,
    output wire s_awlock, output wire [3:0] s_awcache, output wire [2:0] s_awprot,
    output wire s_awvalid, input wire s_awready,
    output wire [DW-1:0] s_wdata, output wire [DW/8-1:0] s_wstrb,
    output wire s_wlast, output wire s_wvalid, input wire s_wready,
    input  wire [IW-1:0] s_bid, input wire [1:0] s_bresp,
    input  wire s_bvalid, output wire s_bready,
    output wire [IW-1:0] s_arid, output wire [AW-1:0] s_araddr,
    output wire [7:0] s_arlen, output wire [2:0] s_arsize, output wire [1:0] s_arburst,
    output wire s_arlock, output wire [3:0] s_arcache, output wire [2:0] s_arprot,
    output wire s_arvalid, input wire s_arready,
    input  wire [IW-1:0] s_rid, input wire [DW-1:0] s_rdata, input wire [1:0] s_rresp,
    input  wire s_rlast, input wire s_rvalid, output wire s_rready
);
    // w_grant/r_grant: 0 idle, 1 M0, 2 M1
    reg [1:0] w_grant, r_grant;
    wire w_idle = (w_grant == 2'd0);
    wire r_idle = (r_grant == 2'd0);
    wire w_m0 = (w_grant == 2'd1);
    wire w_m1 = (w_grant == 2'd2);
    wire r_m0 = (r_grant == 2'd1);
    wire r_m1 = (r_grant == 2'd2);

    // Select master for AW while idle (priority M0) or while granted
    wire aw_sel_m1 = w_idle ? (m1_awvalid & ~m0_awvalid) : w_m1;
    wire aw_sel_m0 = w_idle ?  m0_awvalid                 : w_m0;
    wire ar_sel_m1 = r_idle ? (m1_arvalid & ~m0_arvalid) : r_m1;
    wire ar_sel_m0 = r_idle ?  m0_arvalid                 : r_m0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) w_grant <= 2'd0;
        else if (w_idle) begin
            if (m0_awvalid & s_awready) w_grant <= 2'd1;
            else if (m1_awvalid & s_awready) w_grant <= 2'd2;
        end else if (w_m0 & s_bvalid & m0_bready) w_grant <= 2'd0;
        else if (w_m1 & s_bvalid & m1_bready) w_grant <= 2'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_grant <= 2'd0;
        else if (r_idle) begin
            if (m0_arvalid & s_arready) r_grant <= 2'd1;
            else if (m1_arvalid & s_arready) r_grant <= 2'd2;
        end else if (r_m0 & s_rvalid & m0_rready & s_rlast) r_grant <= 2'd0;
        else if (r_m1 & s_rvalid & m1_rready & s_rlast) r_grant <= 2'd0;
    end

    // AW
    assign s_awid    = aw_sel_m1 ? m1_awid    : m0_awid;
    assign s_awaddr  = aw_sel_m1 ? m1_awaddr  : m0_awaddr;
    assign s_awlen   = aw_sel_m1 ? m1_awlen   : m0_awlen;
    assign s_awsize  = aw_sel_m1 ? m1_awsize  : m0_awsize;
    assign s_awburst = aw_sel_m1 ? m1_awburst : m0_awburst;
    assign s_awlock  = aw_sel_m1 ? m1_awlock  : m0_awlock;
    assign s_awcache = aw_sel_m1 ? m1_awcache : m0_awcache;
    assign s_awprot  = aw_sel_m1 ? m1_awprot  : m0_awprot;
    assign s_awvalid = (aw_sel_m0 & m0_awvalid) | (aw_sel_m1 & m1_awvalid);
    assign m0_awready = aw_sel_m0 & s_awready;
    assign m1_awready = aw_sel_m1 & s_awready;

    // W — only after grant (AXI allows W with/after AW; FB typically overlaps)
    // On the AW-accept cycle grant is still idle; allow W for the master being accepted.
    wire w_sel_m0 = w_idle ? (m0_awvalid) : w_m0;
    wire w_sel_m1 = w_idle ? (m1_awvalid & ~m0_awvalid) : w_m1;
    assign s_wdata  = w_sel_m1 ? m1_wdata  : m0_wdata;
    assign s_wstrb  = w_sel_m1 ? m1_wstrb  : m0_wstrb;
    assign s_wlast  = w_sel_m1 ? m1_wlast  : m0_wlast;
    assign s_wvalid = (w_sel_m0 & m0_wvalid) | (w_sel_m1 & m1_wvalid);
    assign m0_wready = w_sel_m0 & s_wready;
    assign m1_wready = w_sel_m1 & s_wready;

    // B
    assign m0_bid = s_bid; assign m0_bresp = s_bresp;
    assign m1_bid = s_bid; assign m1_bresp = s_bresp;
    assign m0_bvalid = w_m0 & s_bvalid;
    assign m1_bvalid = w_m1 & s_bvalid;
    assign s_bready  = (w_m0 & m0_bready) | (w_m1 & m1_bready);

    // AR
    assign s_arid    = ar_sel_m1 ? m1_arid    : m0_arid;
    assign s_araddr  = ar_sel_m1 ? m1_araddr  : m0_araddr;
    assign s_arlen   = ar_sel_m1 ? m1_arlen   : m0_arlen;
    assign s_arsize  = ar_sel_m1 ? m1_arsize  : m0_arsize;
    assign s_arburst = ar_sel_m1 ? m1_arburst : m0_arburst;
    assign s_arlock  = ar_sel_m1 ? m1_arlock  : m0_arlock;
    assign s_arcache = ar_sel_m1 ? m1_arcache : m0_arcache;
    assign s_arprot  = ar_sel_m1 ? m1_arprot  : m0_arprot;
    assign s_arvalid = (ar_sel_m0 & m0_arvalid) | (ar_sel_m1 & m1_arvalid);
    assign m0_arready = ar_sel_m0 & s_arready;
    assign m1_arready = ar_sel_m1 & s_arready;

    // R
    assign m0_rid = s_rid; assign m0_rdata = s_rdata; assign m0_rresp = s_rresp; assign m0_rlast = s_rlast;
    assign m1_rid = s_rid; assign m1_rdata = s_rdata; assign m1_rresp = s_rresp; assign m1_rlast = s_rlast;
    assign m0_rvalid = r_m0 & s_rvalid;
    assign m1_rvalid = r_m1 & s_rvalid;
    assign s_rready  = (r_m0 & m0_rready) | (r_m1 & m1_rready);
endmodule
