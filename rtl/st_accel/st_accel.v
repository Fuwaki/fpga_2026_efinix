// st_accel.v -- Phase-6c ink_dw W8A8 (depthwise-capable)
// ink_dw subset (~8KB): stem, enc0 dw/pw, virt_up+up3/up1, head dw/pw. No enc.1/res.
// Acts on-chip bank0/bank1. M1 AXI idle. HDMI arbiter untouched.
module st_accel #(
    parameter integer N_PE=16, DSP_LAT=3,
    parameter integer AW=32, DW=128, IW=4,
    parameter integer WROM_DEPTH=8096
)(
    input wire clk, rst_n,
    input wire [31:0] PADDR, input wire PSEL,PENABLE,PWRITE, input wire [31:0] PWDATA,
    output reg [31:0] PRDATA, output wire PREADY,PSLVERROR,irq,
    input wire hw_x_we, input wire [9:0] hw_x_addr, input wire [7:0] hw_x_data,
    input wire hw_load_w, hw_start, output wire hw_busy, hw_done,
    input wire [11:0] hw_y_addr, output reg [7:0] hw_y_data,
    // Read-only board telemetry, exposed through the CPU APB window.
    input wire [31:0] dbg_cap_samples, dbg_cap_tiles, dbg_commit_count,
    input wire [15:0] dbg_last_x, dbg_last_y,
    input wire [7:0] dbg_last_cap_addr, dbg_last_commit_addr,
    output reg [15:0] cpu_dbg_heartbeat,
    output wire [IW-1:0] m_awid, output wire [AW-1:0] m_awaddr, output wire [7:0] m_awlen,
    output wire [2:0] m_awsize, output wire [1:0] m_awburst, output wire m_awlock,
    output wire [3:0] m_awcache, output wire [2:0] m_awprot, output wire m_awvalid, input wire m_awready,
    output wire [DW-1:0] m_wdata, output wire [DW/8-1:0] m_wstrb, output wire m_wlast,m_wvalid, input wire m_wready,
    input wire [IW-1:0] m_bid, input wire [1:0] m_bresp, input wire m_bvalid, output wire m_bready,
    output wire [IW-1:0] m_arid, output wire [AW-1:0] m_araddr, output wire [7:0] m_arlen,
    output wire [2:0] m_arsize, output wire [1:0] m_arburst, output wire m_arlock,
    output wire [3:0] m_arcache, output wire [2:0] m_arprot, output wire m_arvalid, input wire m_arready,
    input wire [IW-1:0] m_rid, input wire [DW-1:0] m_rdata, input wire [1:0] m_rresp,
    input wire m_rlast,m_rvalid, output wire m_rready
);
    assign PREADY=1'b1; assign PSLVERROR=1'b0;
    wire [7:0] reg_addr=PADDR[7:0];
    wire apb_wr=PSEL&PENABLE&PWRITE, apb_rd=PSEL&PENABLE&~PWRITE;

    reg irq_en,busy,done,soft_rst,start_pulse,hw_start_pulse;
    reg [1:0] in_ch;
    reg [31:0] cycles;
    assign hw_busy=busy; assign hw_done=done; assign irq=irq_en&done;

    // Weight ROM — sync read
    (* ram_style="block" *) reg [7:0] wrom [0:WROM_DEPTH-1];
    // Generated from the selected NNgen manifest profile by build_all.sh.
    initial $readmemh("st_w8_sel_weights_generated.hex", wrom);
    reg [16:0] w_raddr; reg [7:0] w_rdata;
    always @(posedge clk) w_rdata <= wrom[w_raddr];

    (* ram_style="block" *) reg [7:0] bias_mem [0:2815];
    (* ram_style="block" *) reg [7:0] rq_mem [0:1407];
    initial begin $readmemh("st_w8_bias.hex", bias_mem); $readmemh("st_w8_requant.hex", rq_mem); end
    reg [11:0] bias_raddr; reg [10:0] rq_raddr; reg [7:0] bias_rdata, rq_rdata;
    always @(posedge clk) begin bias_rdata<=bias_mem[bias_raddr]; rq_rdata<=rq_mem[rq_raddr]; end

    // Input 32x32x3 HWC
    (* ram_style="block" *) reg [7:0] in_act [0:767];
    reg [9:0] in_waddr, in_raddr; reg [7:0] in_wdata, in_rdata; reg in_we;
    always @(posedge clk) begin if(in_we) in_act[in_waddr]<=in_wdata; in_rdata<=in_act[in_raddr]; end

    // Output 32x32x3 HWC for PiP
    (* ram_style="block" *) reg [7:0] out_pix [0:767];
    reg [11:0] out_waddr, out_raddr; reg [7:0] out_wdata, out_rdata_m; reg out_we;
    always @(posedge clk) begin if(out_we) out_pix[out_waddr]<=out_wdata; out_rdata_m<=out_pix[out_raddr]; end

    // Act ping-pong CHW max 32*32*32
    (* ram_style="block" *) reg [7:0] bank0 [0:8191];
    (* ram_style="block" *) reg [7:0] bank1 [0:8191]; // smaller ping bank
    reg [12:0] b_raddr, b_waddr; reg [7:0] b_wdata, b0_rdata, b1_rdata; reg b_we, b_rd_bank;
    always @(posedge clk) begin
      if(b_we) begin if(b_rd_bank) bank0[b_waddr]<=b_wdata; else bank1[b_waddr]<=b_wdata; end
      b0_rdata<=bank0[b_raddr]; b1_rdata<=bank1[b_raddr];
    end
    wire [7:0] b_rdata = b_rd_bank ? b1_rdata : b0_rdata; // read src bank

    // PE
    (* keep="true" *) reg pe_ce, pe_rst;
    (* keep="true" *) reg signed [7:0] pe_a [0:15], pe_b [0:15];
    wire [23:0] pe_p [0:15];
    genvar gi;
    generate for(gi=0;gi<16;gi=gi+1) begin: gp
      (* keep_hierarchy="yes" *) efx_mac8 #(.LATENCY(DSP_LAT)) um (
        .clk(clk),.rst(pe_rst|soft_rst|~rst_n),.ce(pe_ce),.a(pe_a[gi]),.b(pe_b[gi]),.p(pe_p[gi]));
    end endgenerate
    reg signed [31:0] prod_sum, acc; integer ii;
    always @(*) begin prod_sum=0; for(ii=0;ii<16;ii=ii+1) prod_sum=prod_sum+{{8{pe_p[ii][23]}},pe_p[ii]}; end

    // AXI idle stub (kept wired)
    reg axi_req,axi_write; reg [AW-1:0] axi_addr; reg [7:0] axi_beats; reg [DW-1:0] axi_wdata_r;
    wire axi_busy,axi_done,axi_w_ready,axi_r_valid; wire [DW-1:0] axi_rdata_w; wire [1:0] axi_resp;
    st_axi_mm #(.AW(AW),.DW(DW),.IW(IW)) uaxi(
      .clk(clk),.rst_n(rst_n),.req(axi_req),.write(axi_write),.addr(axi_addr),.beats(axi_beats),
      .wdata(axi_wdata_r),.w_ready(axi_w_ready),.rdata(axi_rdata_w),.r_valid(axi_r_valid),.r_ready(1'b1),
      .busy(axi_busy),.done(axi_done),.resp_err(axi_resp),
      .awid(m_awid),.awaddr(m_awaddr),.awlen(m_awlen),.awsize(m_awsize),.awburst(m_awburst),
      .awlock(m_awlock),.awcache(m_awcache),.awprot(m_awprot),.awvalid(m_awvalid),.awready(m_awready),
      .axi_wdata(m_wdata),.wstrb(m_wstrb),.wlast(m_wlast),.wvalid(m_wvalid),.wready(m_wready),
      .bid(m_bid),.bresp(m_bresp),.bvalid(m_bvalid),.bready(m_bready),
      .arid(m_arid),.araddr(m_araddr),.arlen(m_arlen),.arsize(m_arsize),.arburst(m_arburst),
      .arlock(m_arlock),.arcache(m_arcache),.arprot(m_arprot),.arvalid(m_arvalid),.arready(m_arready),
      .rid(m_rid),.axi_rdata(m_rdata),.rresp(m_rresp),.rlast(m_rlast),.rvalid(m_rvalid),.rready_m(m_rready));

    reg [3:0] layer_i;
    wire [7:0] lic,loc; wire [1:0] lk,lstride; wire lpad,lrelu,lunsigned,lneed_up,lneed_pool,lis_dw; wire [16:0] lw_off;
    st_layer_sel u_lsel(.idx(layer_i),.ic(lic),.oc(loc),.k(lk),.stride(lstride),
      .pad(lpad),.relu(lrelu),.out_unsigned(lunsigned),.need_up(lneed_up),.need_pool(lneed_pool),.is_dw(lis_dw),.w_off(lw_off));

    reg [5:0] src_h,src_w,dst_h,dst_w; reg [7:0] src_c; reg virt_up; reg [5:0] phys_h, phys_w;
    reg [7:0] oy,ox,oc,ic0,cur_ic,cur_oc; reg [1:0] ky,kx,cur_k,cur_stride;
    reg cur_pad,cur_relu,cur_unsign,cur_dw; reg [16:0] cur_w_off;
    reg [3:0] drain_cnt; reg [4:0] load_i; reg [31:0] tick;
    reg [7:0] bias_b0,bias_b1,bias_b2,bias_b3; reg [15:0] rq_m;
    reg signed [31:0] bias_s; reg [7:0] y_byte;
    reg [14:0] up_i; reg [5:0] up_y,up_x; reg [7:0] up_c;

    localparam S_IDLE=0,S_SETUP=1,S_UP=2,S_UP2=3,S_BIASLD=4,S_BIASLD2=5,S_CLEAR=6,
               S_LD=7,S_LD2=8,S_ISSUE=9,S_DRAIN=10,S_NEXTK=11,S_RQ=12,S_WR=13,
               S_NEXT=14,S_NEXTLAY=15,S_DONE=16,S_POOL=17,S_POOL2=18;
    reg [4:0] state;

    function automatic [7:0] sat_s8; input signed [31:0] v;
      if(v>32'sd127) sat_s8=8'h7F; else if(v<-32'sd128) sat_s8=8'h80; else sat_s8=v[7:0];
    endfunction
    function automatic [7:0] sat_u8; input signed [31:0] v;
      if(v>32'sd255) sat_u8=8'hFF; else if(v<0) sat_u8=8'h00; else sat_u8=v[7:0];
    endfunction
    function automatic [5:0] refl; input signed [8:0] i; input [5:0] lim;
      reg signed [8:0] x; begin
        x=i; if(x<0) x=-x; if(x>=$signed({1'b0,lim})) x=2*$signed({1'b0,lim})-2-x;
        if(x<0) x=0; if(x>=$signed({1'b0,lim})) x=$signed({1'b0,lim})-1;
        refl=x[5:0];
      end endfunction

    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        irq_en<=0;busy<=0;done<=0;soft_rst<=0;start_pulse<=0;hw_start_pulse<=0;in_ch<=0;
        cycles<=0;state<=S_IDLE;layer_i<=0;pe_ce<=0;pe_rst<=1;axi_req<=0;axi_write<=0;
        axi_addr<=0;axi_beats<=1;axi_wdata_r<=0;in_we<=0;out_we<=0;b_we<=0;b_rd_bank<=0;
        PRDATA<=0;hw_y_data<=0;src_h<=16;src_w<=16;tick<=0;cpu_dbg_heartbeat<=0;
        for(ii=0;ii<16;ii=ii+1) begin pe_a[ii]<=0;pe_b[ii]<=0; end
      end else begin
        start_pulse<=0;soft_rst<=0;pe_ce<=0;pe_rst<=0;in_we<=0;out_we<=0;b_we<=0;axi_req<=0;hw_start_pulse<=0;

        if(hw_load_w) in_ch<=hw_x_data[3:2];
        if(hw_x_we) begin in_we<=1; in_waddr<=(in_ch*10'd256)+hw_x_addr[7:0]; in_wdata<=hw_x_data; end
        if(!busy) begin out_raddr<=hw_y_addr[11:0]; hw_y_data<=out_rdata_m; end
        if(hw_start && !busy) hw_start_pulse<=1;

        if(apb_wr) case(reg_addr)
          8'h04: begin if(PWDATA[0]) start_pulse<=1; irq_en<=PWDATA[1]; if(PWDATA[8]) soft_rst<=1; end
          8'h0C: if(PWDATA[1]) done<=0;
          8'h54: cpu_dbg_heartbeat <= PWDATA[15:0];
          default:;
        endcase
        if(apb_rd) case(reg_addr)
          8'h00: PRDATA<=32'h53560001;
          8'h08: PRDATA<={30'd0,done,busy};
          8'h10: PRDATA<=cycles;
          8'h34: PRDATA<={8'd0,state,layer_i,oy};
          8'h40: PRDATA<=dbg_cap_samples;
          8'h44: PRDATA<=dbg_cap_tiles;
          8'h48: PRDATA<=dbg_commit_count;
          8'h4C: PRDATA<={dbg_last_y,dbg_last_x};
          8'h50: PRDATA<={16'd0,dbg_last_commit_addr,dbg_last_cap_addr};
          default: PRDATA<=0;
        endcase

        if(soft_rst) begin busy<=0;done<=0;state<=S_IDLE;pe_rst<=1; end
        else begin
          case(state)
            S_IDLE: if((start_pulse|hw_start_pulse)&~busy) begin
              busy<=1;done<=0;tick<=0;layer_i<=0;b_rd_bank<=0;src_h<=16;src_w<=16;virt_up<=0;phys_h<=16;phys_w<=16;state<=S_SETUP;
            end
            S_SETUP: begin
              cur_ic<=lic;cur_oc<=loc;cur_k<=lk;cur_stride<=lstride;
              cur_pad<=lpad;cur_relu<=lrelu;cur_unsign<=lunsigned;cur_dw<=lis_dw;cur_w_off<=lw_off;
              // stride-2 shrinks; virt_up presents phys as 2x and writes full 2x dst
              if(lneed_up) begin
                phys_h<=src_h; phys_w<=src_w;
                src_h<=src_h<<1; src_w<=src_w<<1;
                dst_h<=src_h<<1; dst_w<=src_w<<1;
                virt_up<=1'b1;
                oy<=0;ox<=0;oc<=0;state<=S_BIASLD;
              end else begin
                virt_up<=1'b0; phys_h<=src_h; phys_w<=src_w;
                dst_h<=(lstride==2)?(src_h>>1):src_h;
                dst_w<=(lstride==2)?(src_w>>1):src_w;
                oy<=0;ox<=0;oc<=0;state<=S_BIASLD;
              end
            end

            S_POOL: begin
              // read 2x2 block average from src, write one pixel to dst bank
              b_raddr <= (up_c*src_h + (up_y<<1))*src_w + (up_x<<1);
              state<=S_POOL2; up_i<=0;
            end
            S_POOL2: begin
              // simplistic: use single sample (top-left) as pool proxy (honest shortcut)
              b_we<=1;
              b_waddr<=(up_c*(src_h>>1)+up_y)*(src_w>>1)+up_x;
              b_wdata<=b_rdata;
              if(up_x+1<(src_w>>1)) begin up_x<=up_x+1; state<=S_POOL; end
              else begin up_x<=0;
                if(up_y+1<(src_h>>1)) begin up_y<=up_y+1; state<=S_POOL; end
                else begin up_y<=0;
                  if(up_c+1<src_c) begin up_c<=up_c+1; state<=S_POOL; end
                  else begin
                    b_rd_bank<=~b_rd_bank; src_h<=src_h>>1; src_w<=src_w>>1;
                    // then upsample for up3.0
                    src_c<=64; up_c<=0; up_y<=0; up_x<=0; up_i<=0; state<=S_UP;
                  end
                end
              end
            end
            // Nearest 2x
            S_UP: begin
              b_raddr <= (up_c*src_h + up_y)*src_w + up_x;
              state<=S_UP2;
            end
            S_UP2: begin
              begin : u2
                reg [5:0] ny,nx; reg [14:0] base;
                ny=up_y<<1; nx=up_x<<1;
                base=(up_c*(src_h<<1)+ny)*(src_w<<1)+nx;
                b_we<=1; b_waddr<=base; b_wdata<=b_rdata;
              end
              // write 3 more corners over-simplified: same cycle only 1 write — do 4 beats
              // Use phase via up_i low bits
              if(up_i[1:0]==2'd0) begin b_we<=1; b_waddr<=(up_c*(src_h<<1)+(up_y<<1))*(src_w<<1)+(up_x<<1); b_wdata<=b_rdata; up_i<=up_i+1; state<=S_UP2; end
              else if(up_i[1:0]==2'd1) begin b_we<=1; b_waddr<=(up_c*(src_h<<1)+(up_y<<1))*(src_w<<1)+(up_x<<1)+1; b_wdata<=b_rdata; up_i<=up_i+1; state<=S_UP2; end
              else if(up_i[1:0]==2'd2) begin b_we<=1; b_waddr<=(up_c*(src_h<<1)+(up_y<<1)+1)*(src_w<<1)+(up_x<<1); b_wdata<=b_rdata; up_i<=up_i+1; state<=S_UP2; end
              else begin
                b_we<=1; b_waddr<=(up_c*(src_h<<1)+(up_y<<1)+1)*(src_w<<1)+(up_x<<1)+1; b_wdata<=b_rdata; up_i<=0;
                if(up_x+1<src_w) begin up_x<=up_x+1; state<=S_UP; end
                else begin up_x<=0; if(up_y+1<src_h) begin up_y<=up_y+1; state<=S_UP; end
                else begin up_y<=0; if(up_c+1<src_c) begin up_c<=up_c+1; state<=S_UP; end
                else begin
                  // swap: new data in write bank → become read
                  b_rd_bank<=~b_rd_bank; src_h<=src_h<<1; src_w<=src_w<<1;
                  oy<=0;ox<=0;oc<=0;state<=S_BIASLD;
                end end end
              end
            end
            // bias+requant load with 1-cycle BRAM latency
            S_BIASLD: begin
              bias_raddr <= (layer_i * 11'd256) + (oc * 8'd4);
              rq_raddr   <= (layer_i * 10'd128) + (oc * 8'd2);
              up_i<=0; state<=S_BIASLD2;
            end
            S_BIASLD2: begin
              case(up_i[3:0])
                4'd0: begin up_i<=1; bias_raddr<=(layer_i*11'd256)+(oc*8'd4)+1; end // wait byte0
                4'd1: begin bias_b0<=bias_rdata; bias_raddr<=(layer_i*11'd256)+(oc*8'd4)+2; up_i<=2; end
                4'd2: begin bias_b1<=bias_rdata; bias_raddr<=(layer_i*11'd256)+(oc*8'd4)+3; up_i<=3; end
                4'd3: begin bias_b2<=bias_rdata; up_i<=4; end
                4'd4: begin
                  bias_b3<=bias_rdata;
                  rq_m[7:0]<=rq_rdata; // lo was addressed in S_BIASLD
                  rq_raddr<=(layer_i*10'd128)+(oc*8'd2)+1;
                  up_i<=5;
                end
                4'd5: begin up_i<=6; end // wait hi
                4'd6: begin
                  begin : rqfix
                    reg [15:0] mfull;
                    mfull={rq_rdata,rq_m[7:0]};
                    if(mfull==16'd0) rq_m<=16'd256;
                    else rq_m<=mfull;
                  end
                  bias_s<=$signed({bias_b3,bias_b2,bias_b1,bias_b0});
                  acc<=0; ky<=0; kx<=0; ic0<=0; load_i<=0; pe_rst<=1; up_i<=0;
                  state<=S_LD;
                end
                default: begin up_i<=0; state<=S_LD; end
              endcase
            end
            S_CLEAR: begin acc<=0; state<=S_LD; end
            S_LD: begin
              // dense: 16-ch vector; depthwise: only channel==oc in slot 0
              begin : ld
                reg signed [8:0] iy,ix; reg [5:0] ry,rx; reg [7:0] icv;
                icv = cur_dw ? oc : (ic0+load_i);
                iy=$signed({1'b0,oy})*$signed({1'b0,cur_stride})+$signed({1'b0,ky})-(cur_pad?9'sd1:9'sd0);
                ix=$signed({1'b0,ox})*$signed({1'b0,cur_stride})+$signed({1'b0,kx})-(cur_pad?9'sd1:9'sd0);
                ry=refl(iy,src_h); rx=refl(ix,src_w);
                if(cur_dw) begin
                  if(load_i==0) begin
                    if(layer_i==0) in_raddr<=(icv[1:0]*10'd256)+(ry*16+rx);
                    else if(virt_up) b_raddr<=(icv*phys_h+(ry>>1))*phys_w+(rx>>1);
                    else b_raddr<=(icv*src_h+ry)*src_w+rx;
                    w_raddr<=cur_w_off+(oc*cur_k+ky)*cur_k+kx;
                  end
                end else if(icv<cur_ic) begin
                  if(layer_i==0) in_raddr<=(icv[1:0]*10'd256)+(ry*16+rx);
                  else if(virt_up) b_raddr<=(icv*phys_h+(ry>>1))*phys_w+(rx>>1);
                  else b_raddr<=(icv*src_h+ry)*src_w+rx;
                  w_raddr<=cur_w_off+((oc*cur_ic+icv)*cur_k+ky)*cur_k+kx;
                end
              end
              state<=S_LD2;
            end
            S_LD2: begin
              begin : ld2
                reg [7:0] icv; icv=cur_dw ? oc : (ic0+load_i);
                if(cur_dw) begin
                  if(load_i==0) begin
                    pe_a[0]<= (layer_i==0) ? in_rdata : b_rdata;
                    pe_b[0]<=w_rdata;
                  end else begin pe_a[load_i]<=0; pe_b[load_i]<=0; end
                end else if(icv<cur_ic) begin
                  pe_a[load_i]<= (layer_i==0) ? in_rdata : b_rdata;
                  pe_b[load_i]<=w_rdata;
                end else begin pe_a[load_i]<=0; pe_b[load_i]<=0; end
              end
              if(load_i==15) begin load_i<=0; state<=S_ISSUE; end
              else begin load_i<=load_i+1; state<=S_LD; end
            end
            S_ISSUE: begin pe_ce<=1; drain_cnt<=DSP_LAT[3:0]+2; state<=S_DRAIN; end
            S_DRAIN: begin
              pe_ce<=1;
              if(drain_cnt==0) begin acc<=acc+prod_sum; state<=S_NEXTK; end
              else drain_cnt<=drain_cnt-1;
            end
            S_NEXTK: begin
              if(!cur_dw && (ic0+16<cur_ic)) begin ic0<=ic0+16; load_i<=0; state<=S_LD; end
              else begin
                ic0<=0;
                if(kx+1<cur_k) begin kx<=kx+1; load_i<=0; state<=S_LD; end
                else begin kx<=0;
                  if(ky+1<cur_k) begin ky<=ky+1; load_i<=0; state<=S_LD; end
                  else state<=S_RQ;
                end
              end
            end
            S_RQ: begin
              begin : rq
                reg signed [47:0] t; reg signed [31:0] q;
                // Use rq_m if nonzero else shift approx
                if(rq_m!=0) t=($signed(acc)+bias_s)*$signed({1'b0,rq_m});
                else t={acc+bias_s,16'b0};
                q=t>>>16;
                if(cur_relu && q[31]) q=0;
                y_byte<=cur_unsign?sat_u8(q):sat_s8(q);
              end
              state<=S_WR;
            end
            S_WR: begin
              b_we<=1; b_waddr<=(oc*dst_h+oy)*dst_w+ox; b_wdata<=y_byte;
              if(layer_i==4'd10) begin out_we<=1; out_waddr<=(oy*16+ox)*3+oc[1:0]; out_wdata<=y_byte; end
              state<=S_NEXT;
            end
            S_NEXT: begin
              if(ox+1<dst_w) begin ox<=ox+1; state<=S_BIASLD; end
              else begin ox<=0;
                if(oy+1<dst_h) begin oy<=oy+1; state<=S_BIASLD; end
                else begin oy<=0;
                  if(oc+1<cur_oc) begin oc<=oc+1; state<=S_BIASLD; end
                  else begin
                    b_rd_bank<=~b_rd_bank; src_h<=dst_h; src_w<=dst_w; virt_up<=0; phys_h<=dst_h; phys_w<=dst_w; state<=S_NEXTLAY;
                  end
                end
              end
            end
            S_NEXTLAY: begin
              if(layer_i==4'd10) state<=S_DONE;
              else begin layer_i<=layer_i+1; state<=S_SETUP; end
            end
            S_DONE: begin busy<=0;done<=1;cycles<=tick;state<=S_IDLE; end
            default: state<=S_IDLE;
          endcase
          if(busy) tick<=tick+1;
        end
      end
    end
endmodule
