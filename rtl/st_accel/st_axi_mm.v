// st_axi_mm.v -- lightweight AXI4 master (128-bit) for st_accel DDR access
// Single outstanding read OR write burst. awsize/arsize = 4 (16 bytes).
module st_axi_mm #(
    parameter AW = 32,
    parameter DW = 128,
    parameter IW = 4
) (
    input  wire             clk,
    input  wire             rst_n,

    // cmd
    input  wire             req,       // pulse start
    input  wire             write,     // 1=write, 0=read
    input  wire [AW-1:0]    addr,      // 16-byte aligned
    input  wire [7:0]       beats,     // axlen = beats-1, beats>=1
    input  wire [DW-1:0]    wdata,
    output reg              w_ready,   // consume next wdata
    output reg  [DW-1:0]    rdata,
    output reg              r_valid,   // rdata beat valid
    input  wire             r_ready,
    output reg              busy,
    output reg              done,      // 1-cycle pulse
    output reg  [1:0]       resp_err,

    // AXI
    output reg  [IW-1:0]    awid,
    output reg  [AW-1:0]    awaddr,
    output reg  [7:0]       awlen,
    output reg  [2:0]       awsize,
    output reg  [1:0]       awburst,
    output reg              awlock,
    output reg  [3:0]       awcache,
    output reg  [2:0]       awprot,
    output reg              awvalid,
    input  wire             awready,
    output reg  [DW-1:0]    axi_wdata,
    output reg  [DW/8-1:0]  wstrb,
    output reg              wlast,
    output reg              wvalid,
    input  wire             wready,
    input  wire [IW-1:0]    bid,
    input  wire [1:0]       bresp,
    input  wire             bvalid,
    output reg              bready,
    output reg  [IW-1:0]    arid,
    output reg  [AW-1:0]    araddr,
    output reg  [7:0]       arlen,
    output reg  [2:0]       arsize,
    output reg  [1:0]       arburst,
    output reg              arlock,
    output reg  [3:0]       arcache,
    output reg  [2:0]       arprot,
    output reg              arvalid,
    input  wire             arready,
    input  wire [IW-1:0]    rid,
    input  wire [DW-1:0]    axi_rdata,
    input  wire [1:0]       rresp,
    input  wire             rlast,
    input  wire             rvalid,
    output reg              rready_m
);
    localparam S_IDLE=0, S_AW=1, S_W=2, S_B=3, S_AR=4, S_R=5, S_DONE=6;
    reg [2:0] st;
    reg [7:0] left;
    reg       is_wr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0; resp_err<=0;
            awvalid<=0; wvalid<=0; bready<=0; arvalid<=0; rready_m<=0;
            w_ready<=0; r_valid<=0; rdata<=0;
            awid<=0; arid<=0; awsize<=3'd4; arsize<=3'd4;
            awburst<=2'b01; arburst<=2'b01;
            awlock<=0; arlock<=0; awcache<=4'd3; arcache<=4'd3;
            awprot<=0; arprot<=0; wstrb<={DW/8{1'b1}};
            awaddr<=0; araddr<=0; awlen<=0; arlen<=0;
            axi_wdata<=0; wlast<=0; left<=0; is_wr<=0;
        end else begin
            done<=0; w_ready<=0;
            if (r_valid && r_ready) r_valid<=0;

            case (st)
            S_IDLE: begin
                busy<=0; bready<=0; rready_m<=0;
                if (req) begin
                    busy<=1; is_wr<=write; left<= (beats==0)?8'd1:beats;
                    resp_err<=0;
                    if (write) begin
                        awaddr<=addr; awlen<=(beats==0)?8'd0:(beats-8'd1);
                        awvalid<=1; st<=S_AW;
                    end else begin
                        araddr<=addr; arlen<=(beats==0)?8'd0:(beats-8'd1);
                        arvalid<=1; st<=S_AR;
                    end
                end
            end
            S_AW: begin
                if (awvalid && awready) begin
                    awvalid<=0; wvalid<=0; st<=S_W;
                end
            end
            S_W: begin
                if (!wvalid) begin
                    w_ready<=1; // request data this cycle
                    axi_wdata<=wdata;
                    wlast<=(left<=8'd1);
                    wvalid<=1;
                end else if (wready) begin
                    wvalid<=0;
                    if (left<=8'd1) begin
                        bready<=1; st<=S_B;
                    end else begin
                        left<=left-8'd1;
                    end
                end
            end
            S_B: begin
                if (bvalid && bready) begin
                    bready<=0; resp_err<=bresp; st<=S_DONE;
                end
            end
            S_AR: begin
                if (arvalid && arready) begin
                    arvalid<=0; rready_m<=1; st<=S_R;
                end
            end
            S_R: begin
                if (rvalid && rready_m) begin
                    rdata<=axi_rdata; r_valid<=1; resp_err<=rresp;
                    if (rlast) begin
                        rready_m<=0; st<=S_DONE;
                    end
                end
            end
            S_DONE: begin
                done<=1; busy<=0; st<=S_IDLE;
            end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule
