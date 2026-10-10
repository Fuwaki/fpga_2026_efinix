// st_vid_pipe.v -- Phase-6c: BRAM-latency PiP align (kill vertical seam); TILE=16
module st_vid_pipe #(
    parameter integer TILE=16, SCALE=16, H_FULL=1920, V_FULL=1080
)(
    input wire vid_clk, vid_rst_n, sys_clk, sys_rst_n,
    input wire in_de, in_hs, in_vs,
    input wire [7:0] in_r, in_g, in_b,
    output reg out_de, out_hs, out_vs,
    output reg [7:0] out_r, out_g, out_b,
    output reg hw_x_we,
    output reg [9:0] hw_x_addr,
    output reg [7:0] hw_x_data,
    output reg hw_load_w, hw_start,
    input wire hw_busy, hw_done,
    output reg [11:0] hw_y_addr,
    input wire [7:0] hw_y_data,
    output reg [31:0] frame_cnt,
    output reg pipe_busy
);
    localparam X_STEP=H_FULL/TILE, Y_STEP=V_FULL/TILE;
    localparam PIP_W=TILE*SCALE, PIP_H=TILE*SCALE;
    localparam integer NP=TILE*TILE;

    reg cap_we; reg [7:0] cap_waddr; reg [7:0] cap_wr,cap_wg,cap_wb;
    reg [7:0] sys_cap_raddr; wire [7:0] sys_cr,sys_cg,sys_cb;
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_cr (
        .we1(cap_we),.we2(1'b0),.clka(vid_clk),.clkb(sys_clk),
        .din1(cap_wr),.din2(8'd0),.addr1(cap_waddr),.addr2(sys_cap_raddr),
        .dout1(),.dout2(sys_cr));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_cg (
        .we1(cap_we),.we2(1'b0),.clka(vid_clk),.clkb(sys_clk),
        .din1(cap_wg),.din2(8'd0),.addr1(cap_waddr),.addr2(sys_cap_raddr),
        .dout1(),.dout2(sys_cg));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_cb (
        .we1(cap_we),.we2(1'b0),.clka(vid_clk),.clkb(sys_clk),
        .din1(cap_wb),.din2(8'd0),.addr1(cap_waddr),.addr2(sys_cap_raddr),
        .dout1(),.dout2(sys_cb));

    reg y_we; reg [7:0] y_waddr; reg [7:0] y_wdata; reg [1:0] y_plane;
    reg [7:0] vid_y_raddr; wire [7:0] yr,yg,yb;
    wire we_r=y_we&(y_plane==2'd0), we_g=y_we&(y_plane==2'd1), we_b=y_we&(y_plane==2'd2);
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_yr (
        .we1(we_r),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(y_wdata),.din2(8'd0),.addr1(y_waddr),.addr2(vid_y_raddr),
        .dout1(),.dout2(yr));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_yg (
        .we1(we_g),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(y_wdata),.din2(8'd0),.addr1(y_waddr),.addr2(vid_y_raddr),
        .dout1(),.dout2(yg));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_yb (
        .we1(we_b),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(y_wdata),.din2(8'd0),.addr1(y_waddr),.addr2(vid_y_raddr),
        .dout1(),.dout2(yb));

    reg vs_d,cap_active; reg [11:0] xcnt,ycnt; reg [7:0] cap_wx,cap_wy;
    reg cap_tog_vid; reg [1:0] cap_tog_sync;

    // Pipeline PiP readout 1 cycle to match TDP BRAM read latency.
    // Without this, each SCALE tile boundary shows a 1px ghost of the left
    // tile (most noticeable as a vertical line near image center).
    reg        pip_pend, border_pend;
    reg [7:0]  in_r_d, in_g_d, in_b_d;
    reg        in_de_d, in_hs_d, in_vs_d;

    always @(posedge vid_clk or negedge vid_rst_n) begin
        if(!vid_rst_n) begin
            vs_d<=0;xcnt<=0;ycnt<=0;cap_active<=0;cap_we<=0;cap_waddr<=0;
            cap_wx<=0;cap_wy<=0;cap_tog_vid<=0;
            out_de<=0;out_hs<=0;out_vs<=0;out_r<=0;out_g<=0;out_b<=0;vid_y_raddr<=0;
            pip_pend<=0; border_pend<=0;
            in_r_d<=0; in_g_d<=0; in_b_d<=0; in_de_d<=0; in_hs_d<=0; in_vs_d<=0;
        end else begin
            vs_d<=in_vs; cap_we<=0;
            if(in_vs & ~vs_d) begin xcnt<=0;ycnt<=0;cap_active<=1;cap_wx<=0;cap_wy<=0; end
            if(in_de) begin
                if(cap_active && (xcnt%X_STEP==0) && (ycnt%Y_STEP==0) &&
                   (cap_wx<TILE[7:0]) && (cap_wy<TILE[7:0])) begin
                    cap_we<=1;
                    cap_wr<=in_r>>1; cap_wg<=in_g>>1; cap_wb<=in_b>>1;
                    cap_waddr <= {cap_wy[3:0], cap_wx[3:0]};
                    if(cap_wx==TILE[7:0]-1) begin
                        cap_wx<=0;
                        if(cap_wy==TILE[7:0]-1) begin cap_active<=0; cap_tog_vid<=~cap_tog_vid; end
                        else cap_wy<=cap_wy+1;
                    end else cap_wx<=cap_wx+1;
                end
                if(xcnt==H_FULL-1) begin xcnt<=0; ycnt<=ycnt+1; end else xcnt<=xcnt+1;
            end else if(~in_hs) xcnt<=0;

            // Stage A: issue Y-plane address; remember PiP/border for next beat
            begin : ov_addr
                reg [11:0] px,py; reg [7:0] sx,sy;
                px=xcnt; py=ycnt;
                in_r_d<=in_r; in_g_d<=in_g; in_b_d<=in_b;
                in_de_d<=in_de; in_hs_d<=in_hs; in_vs_d<=in_vs;
                if(in_de && px<PIP_W && py<PIP_H) begin
                    sx=px/SCALE; sy=py/SCALE;
                    vid_y_raddr <= {sy[3:0], sx[3:0]};
                    pip_pend <= 1'b1;
                    border_pend <= (px<2||py<2||px>=PIP_W-2||py>=PIP_H-2);
                end else begin
                    pip_pend <= 1'b0;
                    border_pend <= 1'b0;
                end
            end

            // Stage B: BRAM data (yr/yg/yb) now matches pending addr from prior cycle
            out_de<=in_de_d; out_hs<=in_hs_d; out_vs<=in_vs_d;
            if(in_de_d && pip_pend) begin
                if(border_pend) begin
                    out_r<=8'hC0; out_g<=8'h00; out_b<=8'hC0;
                end else begin
                    out_r<=yr; out_g<=yg; out_b<=yb;
                end
            end else begin
                out_r<=in_r_d; out_g<=in_g_d; out_b<=in_b_d;
            end
        end
    end

    localparam SS_IDLE=0, SS_PRE_R=1, SS_PRE_G=2, SS_PRE_B=3,
               SS_CH=4, SS_COPYX=5, SS_START=6, SS_WAIT=7, SS_COPYY=8;
    reg [3:0] ss; reg [9:0] copy_idx; reg [1:0] ch; reg cap_tog_sys_d, hw_done_d;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            ss<=SS_IDLE; copy_idx<=0; pipe_busy<=0; frame_cnt<=0; ch<=0;
            hw_x_we<=0; hw_x_addr<=0; hw_x_data<=0; hw_load_w<=0; hw_start<=0;
            hw_y_addr<=0; y_we<=0; y_waddr<=0; y_wdata<=0; y_plane<=0;
            cap_tog_sync<=0; sys_cap_raddr<=0; hw_done_d<=0; cap_tog_sys_d<=0;
        end else begin
            hw_x_we<=0; hw_load_w<=0; hw_start<=0; y_we<=0;
            cap_tog_sync <= {cap_tog_sync[0], cap_tog_vid};
            hw_done_d<=hw_done;
            case(ss)
                SS_IDLE: begin
                    pipe_busy<=0;
                    if(cap_tog_sync[1]!=cap_tog_sys_d && !hw_busy) begin
                        cap_tog_sys_d<=cap_tog_sync[1];
                        pipe_busy<=1; copy_idx<=0; sys_cap_raddr<=0; ss<=SS_PRE_R;
                    end
                end
                // Prefill PiP with live camera (guaranteed follow)
                SS_PRE_R: begin
                    sys_cap_raddr<=copy_idx[7:0];
                    if(copy_idx>0) begin
                        y_we<=1; y_plane<=2'd0; y_waddr<=copy_idx[7:0]-8'd1; y_wdata<=sys_cr;
                    end
                    if(copy_idx==NP[9:0]) begin copy_idx<=0; ss<=SS_PRE_G; end
                    else copy_idx<=copy_idx+1;
                end
                SS_PRE_G: begin
                    sys_cap_raddr<=copy_idx[7:0];
                    if(copy_idx>0) begin
                        y_we<=1; y_plane<=2'd1; y_waddr<=copy_idx[7:0]-8'd1; y_wdata<=sys_cg;
                    end
                    if(copy_idx==NP[9:0]) begin copy_idx<=0; ss<=SS_PRE_B; end
                    else copy_idx<=copy_idx+1;
                end
                SS_PRE_B: begin
                    sys_cap_raddr<=copy_idx[7:0];
                    if(copy_idx>0) begin
                        y_we<=1; y_plane<=2'd2; y_waddr<=copy_idx[7:0]-8'd1; y_wdata<=sys_cb;
                    end
                    if(copy_idx==NP[9:0]) begin ch<=0; copy_idx<=0; ss<=SS_CH; end
                    else copy_idx<=copy_idx+1;
                end
                SS_CH: begin
                    hw_load_w<=1; hw_x_data<={4'd0,ch,2'b00};
                    ss<=SS_COPYX; copy_idx<=0; sys_cap_raddr<=0;
                end
                SS_COPYX: begin
                    if(copy_idx==0) begin sys_cap_raddr<=0; copy_idx<=1; end
                    else if(copy_idx<=NP[9:0]) begin
                        hw_x_we<=1; hw_x_addr<={2'b0, copy_idx[7:0]-8'd1};
                        case(ch)
                          2'd0: hw_x_data<=sys_cr;
                          2'd1: hw_x_data<=sys_cg;
                          default: hw_x_data<=sys_cb;
                        endcase
                        sys_cap_raddr<=copy_idx[7:0]; copy_idx<=copy_idx+1;
                    end else if(ch!=2'd2) begin ch<=ch+2'd1; ss<=SS_CH;
                    end else ss<=SS_START;
                end
                SS_START: begin hw_start<=1; ss<=SS_WAIT; end
                SS_WAIT: if(hw_done & ~hw_done_d) begin
                    ss<=SS_COPYY; copy_idx<=0; hw_y_addr<=0;
                end
                // out_raddr->out_rdata_m->hw_y_data = 2-cycle latency
                SS_COPYY: begin
                    if(copy_idx==0) begin hw_y_addr<=0; copy_idx<=1; end
                    else if(copy_idx==1) begin hw_y_addr<=1; copy_idx<=2; end // wait 2nd beat
                    else if(copy_idx<=10'd769) begin
                        begin : cy
                            reg [9:0] i; reg [7:0] pix; reg [1:0] c;
                            i=copy_idx-10'd2; c=i%3; pix=i/3;
                            y_we<=1; y_plane<=c; y_waddr<=pix; y_wdata<=hw_y_data;
                        end
                        hw_y_addr<= {2'b0, copy_idx[9:0]}; copy_idx<=copy_idx+1;
                    end else begin
                        frame_cnt<=frame_cnt+1; ss<=SS_IDLE; pipe_busy<=0;
                    end
                end
                default: ss<=SS_IDLE;
            endcase
        end
    end
endmodule
