
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
// fpga_src：
// 由 10_Ti60f225_sc431hai2hdmi_demo/Ti60f225_sc431hai2hdmi_v6 移植：
//   CSI-2 RX + DDR3 三帧缓冲 + debayer/白平衡 + gamma + 饱和度 + HDMI TMDS 输出。
//   引脚/外围参考参考工程（fpga_src.peri.xml 由 ti60f225_oob.peri.xml 直接沿用）。
// 与参考工程的差异：
//   - 顶层改名 fpga_src，去掉 JTAG debug core（VIO/LA）与 DSI 相关代码。
//   - gamma_sel 不再是 VIO 输入，改为 localparam（见 GAMMA_BYPASS）。
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
// `include "define.v"

localparam ENABLE_ST_ACCEL = 0;


module fpga_src #(

	parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
	parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
	parameter                       RANKS              = `RANKS,
	parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
	parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
	parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
	parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
	parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
	parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
	parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
	parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
	parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
	parameter                       ODT_WIDTH          = `ODT_WIDTH,
	parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
	parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
	parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
	parameter                       DATA_WIDTH         = `DATA_WIDTH,
	parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
	parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
	parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
	parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
)
(

  (* syn_peri_port = 0 *) input jtag_inst1_CAPTURE,
  (* syn_peri_port = 0 *) input jtag_inst1_DRCK,
  (* syn_peri_port = 0 *) input jtag_inst1_RESET,
  (* syn_peri_port = 0 *) input jtag_inst1_RUNTEST,
  (* syn_peri_port = 0 *) input jtag_inst1_SEL,
  (* syn_peri_port = 0 *) input jtag_inst1_SHIFT,
  (* syn_peri_port = 0 *) input jtag_inst1_TCK,
  (* syn_peri_port = 0 *) input jtag_inst1_TDI,
  (* syn_peri_port = 0 *) input jtag_inst1_TMS,
  (* syn_peri_port = 0 *) input jtag_inst1_UPDATE,
  (* syn_peri_port = 0 *) output jtag_inst1_TDO,

   //Clocks 
	input	wire	i_arstn,
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    input wire CLK_5M,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire    pll_inst4_RSTN,
	input   wire    pll_inst4_LOCKED,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
    //CSI Interface
    input	 wire		io_cam_sda_IN,
    output wire   io_cam_sda_OUT,
    output wire		io_cam_sda_OE,

    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,

    output	wire		o_cam_rst_p,
    
    input	wire		i_cam_ck_LP_P_IN,
    input	wire		i_cam_ck_LP_N_IN,
    output	wire		o_cam_ck_HS_TERM,
    output	wire		o_cam_ck_HS_ENA,
    input	wire		i_cam_ck_CLKOUT,
    
    input	wire	[7:0]			cam_d0_HS_IN,
    input	  wire		      cam_d0_LP_P_IN,
    input	  wire		      cam_d0_LP_N_IN,
    output	wire		      cam_d0_HS_TERM,
    output	wire		      cam_d0_HS_ENA,
    output	wire		      cam_d0_RST,
    output	wire		      cam_d0_FIFO_RD,
    input	  wire		      cam_d0_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d1_HS_IN,
    input	  wire		        cam_d1_LP_P_IN,
    input	  wire		        cam_d1_LP_N_IN,
    output	wire		        cam_d1_HS_TERM,
    output	wire		        cam_d1_HS_ENA,
    output	wire		        cam_d1_RST,
    output	wire		        cam_d1_FIFO_RD,
    input	  wire		        cam_d1_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d2_HS_IN,
    input	  wire		        cam_d2_LP_P_IN,
    input	  wire		        cam_d2_LP_N_IN,
    output	wire		        cam_d2_HS_TERM,
    output	wire		        cam_d2_HS_ENA,
    output	wire		        cam_d2_RST,
    output	wire		        cam_d2_FIFO_RD,
    input	  wire		        cam_d2_FIFO_EMPTY,  
   
    input 	wire	[7:0]			cam_d3_HS_IN,
    input	  wire		        cam_d3_LP_P_IN,
    input	  wire		        cam_d3_LP_N_IN,
    output	wire		        cam_d3_HS_TERM,
    output	wire		        cam_d3_HS_ENA,
    output	wire		        cam_d3_RST,
    output	wire		        cam_d3_FIFO_RD,
    input	  wire		        cam_d3_FIFO_EMPTY,

	
	input 					tx_cal_clk_90edge,
  	input 					rx_cal_clk,
  	input 					tx_cal_clk,
	input                              core_clk,     // CORE CLK @ 100MHz
	input                              sdram_clk,    // SDRAM CK @ 400MHz
	// PLL status flags  
	output [2:0]                       pll_shift,  
	output [4:0]                       pll_shift_sel,
	output                             pll_shift_ena,  
	// memory interface ports
	output                             ddr_ck_hi,
	output                             ddr_ck_lo,
	output                             ddr_reset_n,
	output [CKE_WIDTH-1:0]             ddr_cke,     
	output [ROW_WIDTH-1:0]             ddr_addr,
	output [BANK_WIDTH-1:0]            ddr_ba,
	output                             ddr_cas_n,
 
	output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
	output                             ddr_ras_n,
	output                             ddr_we_n,
	
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
	
	output [DQS_WIDTH-1:0]             ddr_dqs_oe,
	output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
	output [DQ_WIDTH-1:0]              ddr_dq_oe,  
	output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
	output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
	output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
	output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
	output [DM_WIDTH-1:0]              ddr_dm_hi,
	output [DM_WIDTH-1:0]              ddr_dm_lo,
	output [ODT_WIDTH-1:0]             ddr_odt,

       //LED
       output [3:0] led,

       // MIPI DSI
       input	wire	                     i_mipi_tx_pclk		,
       output	wire	                     mipi_dp_clk_LP_P_OUT		,
       output	wire	                     mipi_dp_clk_LP_N_OUT		,
       output	wire	[7:0] 	              mipi_dp_clk_HS_OUT		,
       output	wire	                     mipi_dp_clk_HS_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OUT	,
       output	wire	                     mipi_dp_data2_LP_P_OUT	,
       output	wire	                     mipi_dp_data1_LP_P_OUT	,
       output	wire	                     mipi_dp_data0_LP_P_OUT	,
       output	wire	                     mipi_dp_data3_LP_N_OUT	,
       output	wire	                     mipi_dp_data2_LP_N_OUT	,
       output	wire	                     mipi_dp_data1_LP_N_OUT	,
       output	wire	                     mipi_dp_data0_LP_N_OUT	,
       output	wire	[7:0] 	              mipi_dp_data0_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data1_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data2_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data3_HS_OUT	       ,
       output	wire	                     mipi_dp_data3_HS_OE		,
       output	wire	                     mipi_dp_data2_HS_OE		,
       output	wire	                     mipi_dp_data1_HS_OE		,
       output	wire	                     mipi_dp_data0_HS_OE		,

       output	wire	                     mipi_dp_clk_RST		,
       output	wire	                     mipi_dp_data0_RST		,
       output	wire	                     mipi_dp_data1_RST		,
       output	wire	                     mipi_dp_data2_RST		,
       output	wire	                     mipi_dp_data3_RST		,
       output	wire	                     mipi_dp_clk_LP_P_OE		,
       output	wire	                     mipi_dp_clk_LP_N_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OE	,
       output	wire	                     mipi_dp_data3_LP_N_OE	,
       output	wire	                     mipi_dp_data2_LP_P_OE	,
       output	wire	                     mipi_dp_data2_LP_N_OE	,
       output	wire	                     mipi_dp_data1_LP_P_OE	,
       output	wire	                     mipi_dp_data1_LP_N_OE	,
       output	wire	                     mipi_dp_data0_LP_P_OE	,
       output	wire	                     mipi_dp_data0_LP_N_OE	,

       input  wire	                     mipi_dp_data0_LP_P_IN	,
       input  wire	                     mipi_dp_data0_LP_N_IN	,
       output	wire	                     LCD_RST_P			,
       output wire                        LCD_POWER			,

       // hdmi interface

    output tmds_tx_clk_TX_OE,
    output [9:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [9:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [9:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [9:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST


);

function integer log2;
	input	integer	val;
	integer	i;
	begin
		log2 = 0;
		for (i=0; 2**i<val; i=i+1)
			log2 = i+1;
	end
endfunction


//===============================================================================
//localparam
//===============================================================================
localparam WR_FIFO_DEPTH  = 1024;
localparam RD_FIFO_DEPTH  = 1024;

// localparam	MAX_HRES		= 12'd1920;
// localparam	MAX_VRES		= 12'd1080;
// localparam	HSP			= 8'd2;
// localparam	HBP			= 8'd88;
// localparam	HFP			= 8'd120;
// localparam	VSP			= 8'd2;
// localparam	VBP			= 8'd20;
// localparam	VFP			= 8'd20;

localparam MAX_HRES = 1920;
localparam HFP      = 88;
localparam HSP      = 44;
localparam HBP      = 148;

// Display raster, unchanged from the working 1080p60 output.
localparam MAX_VRES = 1080;

// Camera geometry.  The sensor now runs 2x2 binning at 1280x720; the raster
// stays 1080p and the captured rectangle is centred inside it.  Both
// dimensions must be even so the Bayer phase survives: (960-640)>>1 = 160
// words and (1080-720)>>1 = 180 lines are both even.
localparam CAM_VID_WIDTH  = 1280;
localparam CAM_VID_HEIGHT = 720;
localparam VFP      = 4;
localparam VSP      = 5;
localparam VBP      = 36;
//===============================================================================
//signal
//===============================================================================
   
wire                              app_sr_active;
wire                              app_ref_ack;
wire                              app_zq_ack;
wire                              cal_done;

// Slave Interface Write Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr;
wire [7:0]                        s_axi_awlen;
wire [2:0]                        s_axi_awsize;
wire [1:0]                        s_axi_awburst;
wire [0:0]                        s_axi_awlock;
wire [3:0]                        s_axi_awcache;
wire [2:0]                        s_axi_awprot;
wire                              s_axi_awvalid;
wire                              s_axi_awready;
// Slave Interface Write Data Ports
wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb;
wire                              s_axi_wlast;
wire                              s_axi_wvalid;
wire                              s_axi_wready;
// Slave Interface Write Response Ports
wire                              s_axi_bready;
wire [AXI_ID_WIDTH-1:0]           s_axi_bid;
wire [1:0]                        s_axi_bresp;
wire                              s_axi_bvalid;
// Slave Interface Read Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_araddr;
wire [7:0]                        s_axi_arlen;
wire [2:0]                        s_axi_arsize;
wire [1:0]                        s_axi_arburst;
wire [0:0]                        s_axi_arlock;
wire [3:0]                        s_axi_arcache;
wire [2:0]                        s_axi_arprot;
wire                              s_axi_arvalid;
wire                              s_axi_arready;
// Slave Interface Read Data Ports
wire                              s_axi_rready;
wire [AXI_ID_WIDTH-1:0]           s_axi_rid;
wire [AXI_DATA_WIDTH-1:0]         s_axi_rdata;
wire [1:0]                        s_axi_rresp;
wire                              s_axi_rlast;
wire                              s_axi_rvalid;




////////////////////////////////////////////////////////////////
// System & Debugger
wire    w_arstn;
// wire	w_sysclk_mcu_arstn;
// wire	w_sysclk_mcu_arst;
wire	w_mipi_rx_pclk_arstn;
wire	w_mipi_rx_pclk_arst;

wire		       w_mipi_rx_vs;
wire		       w_mipi_rx_hs;
wire	       w_mipi_rx_de;
wire	[63:0]			w_mipi_rx_data	;

wire					io_systemReset;



//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
assign mipi_dsi_tx_pll_RSTN 	= i_arstn;
assign DDR3_PLL_RSTN 		= i_arstn;
reset_ctrl
#(
	.NUM_RST		(2),
	.CYCLE			(1),
	.IN_RST_ACTIVE	(4'b00),
	.OUT_RST_ACTIVE	(4'b10)
)
inst_reset_ctrl
(
	.i_arst		({2{w_arstn}}),//({{4{i_pll_locked}},                  {2{i_arstn}}}),
	.i_clk			({2{i_mipi_rx_pclk}}),
	.o_srst		({w_mipi_rx_pclk_arst, w_mipi_rx_pclk_arstn})
);



reg [25:0] cnt = 'd0;
always @( posedge core_clk)
begin 
       cnt <= cnt + 1'b1;
end
assign led[0]  = cal_done ? cnt[24] : 1'b0;

//========================================================================================================
//MIPI RX
//========================================================================================================
wire i_mipi_clk ;
assign i_mipi_clk = core_clk;

		assign	cam_d0_RST		= 1'b0;
		assign	cam_d1_RST		= 1'b0;
		assign  cam_d2_RST = 1'b0;
    assign  cam_d3_RST = 1'b0;
	
wire [15:0] mipi_debug_out;
		

		csi_rx_controller inst_efx_csi2_rx
		(
              .reset_n			(i_arstn),
              .clk				(i_mipi_clk),
              .reset_byte_HS_n	(i_arstn),
              .clk_byte_HS		  (i_cam_ck_CLKOUT),
              .reset_pixel_n		(w_mipi_rx_pclk_arstn),
              .clk_pixel			  (i_mipi_rx_pclk),
              
              .Rx_LP_CLK_P		  (i_cam_ck_LP_P_IN),
              .Rx_LP_CLK_N		  (i_cam_ck_LP_N_IN),
              .Rx_HS_enable_C		(o_cam_ck_HS_ENA),
              .LVDS_termen_C		(o_cam_ck_HS_TERM),
              
              .Rx_LP_D_P			({cam_d3_LP_P_IN, cam_d2_LP_P_IN, cam_d1_LP_P_IN, cam_d0_LP_P_IN}),//(r_mipi_rx_data_LP_P_IN_2P),
              .Rx_LP_D_N			({cam_d3_LP_N_IN, cam_d2_LP_N_IN, cam_d1_LP_N_IN, cam_d0_LP_N_IN}),//(r_mipi_rx_data_LP_N_IN_2P),
              .Rx_HS_D_0			(cam_d0_HS_IN),//(r_mipi_rx_data_HS_IN_2P[0*8+:8]),
              .Rx_HS_D_1			(cam_d1_HS_IN),//(r_mipi_rx_data_HS_IN_2P[1*8+:8]),
              .Rx_HS_D_2			(cam_d2_HS_IN),
              .Rx_HS_D_3			(cam_d3_HS_IN),
              .Rx_HS_D_4			(),
              .Rx_HS_D_5			(),
              .Rx_HS_D_6			(),
              .Rx_HS_D_7			(),
              .Rx_HS_enable_D		({cam_d3_HS_ENA    ,cam_d2_HS_ENA    ,cam_d1_HS_ENA    ,cam_d0_HS_ENA    }),//( w_cam_d_HS_ENA),
              .LVDS_termen_D		({cam_d3_HS_TERM   ,cam_d2_HS_TERM   ,cam_d1_HS_TERM   ,cam_d0_HS_TERM   }),
              .fifo_rd_enable		({cam_d3_FIFO_RD   ,cam_d2_FIFO_RD   ,cam_d1_FIFO_RD   ,cam_d0_FIFO_RD   }),
              .fifo_rd_empty		({cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY}),
              .DLY_enable_D		       (),
              .DLY_inc_D			(),
              .u_dly_enable_D		(),
              .u_dly_inc_D		       (),
              
              .axi_clk			(1'b0),
              .axi_reset_n		       (1'b0),
              .axi_awaddr			(6'b0),
              .axi_awvalid		       (1'b0),
              .axi_awready		       (),
              .axi_wdata			(32'b0),
              .axi_wvalid			(1'b0),
              .axi_wready			(),
              
              .axi_bvalid			(),
              .axi_bready			(1'b0),
              .axi_araddr			(6'b0),
              .axi_arvalid		       (1'b0),
              .axi_arready		       (),
              .axi_rdata			(),
              .axi_rvalid			(),
              .axi_rready			(1'b1),
              
              .hsync_vc0			(w_mipi_rx_hs),
              .hsync_vc1			(),
              .hsync_vc2			(),
              .hsync_vc3			(),
              .vsync_vc0			(w_mipi_rx_vs),
              .vsync_vc1			(),
              .vsync_vc2			(),
              .vsync_vc3			(),
              .vc				(),
              .word_count			(),
              .shortpkt_data_field        (),
              .datatype			(),
              .pixel_per_clk		(),
              .pixel_data			(w_mipi_rx_data),
              .pixel_data_valid	       (w_mipi_rx_de),
              .irq				(),
              .mipi_debug_out(mipi_debug_out)
		);

//     wire		       w1_mipi_rx_vs;
// wire		       w1_mipi_rx_hs;
// wire	       w1_mipi_rx_de;
// wire	[39:0]			w1_mipi_rx_data	;
// sensor_clipper  sensor_clipper_inst (
//     .clk(i_mipi_rx_pclk),
//     .i_vs(w_mipi_rx_vs),
//     .i_hs(w_mipi_rx_hs),
//     .i_de(w_mipi_rx_de),
//     .i_dat(w_mipi_rx_data[39:0]),

//     .o_hs(w1_mipi_rx_hs),
//     .o_vs(w1_mipi_rx_vs),
//     .o_de(w1_mipi_rx_de),
//     .o_dat(w1_mipi_rx_data)
   
//   );


wire mdebug_pixel_fifo_full     = mipi_debug_out[0] ;
wire mdebug_pixel_fifo_empty    = mipi_debug_out[1] ;
wire mdebug_crc_error           = mipi_debug_out[2] ;
wire mdebug_ecc_1bit_error      = mipi_debug_out[3] ;
wire mdebug_ecc_2bit_error      = mipi_debug_out[4] ;
wire mdebug_undersize_pkt_error = mipi_debug_out[5] ;
wire mdebug_line_vc0_error      = mipi_debug_out[6] ;
wire mdebug_frame_vc0_error    = mipi_debug_out[10];   
wire mdebug_receive_error      = mipi_debug_out[14];


//========================================================================================================
//
//========================================================================================================
		

//*************** imx219 config********************/
// mipi_config_imx219_top u_config_imx219(
// 										.i_sys_clk(CLK_5M)    	,    /////48M 
// 										.sys_rstn(vid_rst_n )    ,
// 										.o_sen_rst_n(o_cam_rstn)  	,
										
										// .o_iic_sda_OE(io_cam_sda_OE) ,
										// .i_iic_sda(io_cam_sda_IN)   	,
										// .o_iic_sda(io_cam_sda_OUT)   	,
										// .o_iic_scl(io_cam_scl)    	
										// ); 	

//==============================================================================
// RISC-V (Efinix Sapphire RV32 SoC, ip/riscv_soc0)
//
// 摄像头 SC431HAI 的 I2C 寄存器初始化由这颗 CPU 上的固件完成，FPGA 侧不再有
// ROM 表驱动的 I2C 主机。
//   - 复位: 与其它逻辑共用 w_arstn（所有 PLL 锁定后才释放）
//   - 时钟: core_clk @100MHz（SoC 配置 Frequency=100）
//   - I2C0 : 接摄像头排线的 io_cam_scl / io_cam_sda（开漏，靠外部上拉）
//   - GPIO0: 4 位，留给后面的按键/拨码
//   - APB0 : st_accel @ IO_APB_SLAVE_0_INPUT (0xF810_0000)
//   - userInterruptA : st_accel DONE&IRQ_EN
//==============================================================================
wire w_soc_async_reset;      // 高有效异步复位（接 SoC io_asyncReset）
wire w_soc_system_reset;     // SoC 输出的系统复位（高有效），给用户逻辑用
wire w_soc_rst_n_release;    // PLL 锁定且 DDR 校准后再释放 SoC

assign w_soc_rst_n_release = w_arstn & cal_done;

// 与 Ti60F225_devkit/top_soc.v 一致：asyncReset 相对 systemClk 做同步释放
reg [4:0] soc_rst_sync;
always @(posedge core_clk or negedge w_soc_rst_n_release) begin
	if (!w_soc_rst_n_release)
		soc_rst_sync <= 5'b0;
	else
		soc_rst_sync <= {soc_rst_sync[3:0], 1'b1};
end
assign w_soc_async_reset = ~soc_rst_sync[4];

wire w_soc_i2c_scl_write;
wire w_soc_i2c_sda_write;
wire w_soc_uart_tx;
wire [3:0] w_soc_gpio_write;
wire [3:0] w_soc_gpio_write_en;
wire [31:0] w_soc_apb_paddr, w_soc_apb_pwdata, w_soc_apb_prdata;
wire        w_soc_apb_psel, w_soc_apb_penable, w_soc_apb_pwrite;
wire        w_soc_apb_pready;
wire        w_soc_apb_pslverror;
wire        w_st_irq;

// Phase-2 ST conv PE: EFX_DSP24 x16 + HW layer sequencer + on-chip X/W/Y (no DDR AXI yet).
wire        w_hw_x_we;
wire [9:0]  w_hw_x_addr; wire [7:0] w_hw_x_data;
wire        w_hw_load_w, w_hw_start, w_hw_busy, w_hw_done;
wire [11:0] w_hw_y_addr; wire [7:0] w_hw_y_data;
wire [31:0] w_st_frame_cnt;
wire        w_st_pipe_busy;
wire [31:0] st_dbg_cap_samples, st_dbg_cap_tiles, st_dbg_commit_count;
wire [15:0] st_dbg_last_x, st_dbg_last_y;
wire [7:0]  st_dbg_last_cap_addr, st_dbg_last_commit_addr;
wire [15:0] st_cpu_dbg_heartbeat;

generate
if (ENABLE_ST_ACCEL) begin : gen_st_accel
	st_accel #(
		.N_PE(16)
	) u_st_accel (
		.clk       (core_clk),
		.rst_n     (~w_soc_async_reset),
		.PADDR     (w_soc_apb_paddr),
		.PSEL      (w_soc_apb_psel),
		.PENABLE   (w_soc_apb_penable),
		.PWRITE    (w_soc_apb_pwrite),
		.PWDATA    (w_soc_apb_pwdata),
		.PRDATA    (w_soc_apb_prdata),
		.PREADY    (w_soc_apb_pready),
		.PSLVERROR (w_soc_apb_pslverror),
		.irq       (w_st_irq),
		.hw_x_we   (w_hw_x_we),
		.hw_x_addr (w_hw_x_addr),
		.hw_x_data (w_hw_x_data),
		.hw_load_w (w_hw_load_w),
		.hw_start  (w_hw_start),
		.hw_busy   (w_hw_busy),
		.hw_done   (w_hw_done),
		.hw_y_addr (w_hw_y_addr),
		.hw_y_data (w_hw_y_data),
		.dbg_cap_samples(st_dbg_cap_samples), .dbg_cap_tiles(st_dbg_cap_tiles),
		.dbg_commit_count(st_dbg_commit_count), .dbg_last_x(st_dbg_last_x),
		.dbg_last_y(st_dbg_last_y), .dbg_last_cap_addr(st_dbg_last_cap_addr),
		.dbg_last_commit_addr(st_dbg_last_commit_addr), .cpu_dbg_heartbeat(st_cpu_dbg_heartbeat),
		.m_awid(st_awid), .m_awaddr(st_awaddr), .m_awlen(st_awlen), .m_awsize(st_awsize),
		.m_awburst(st_awburst), .m_awlock(st_awlock), .m_awcache(st_awcache), .m_awprot(st_awprot),
		.m_awvalid(st_awvalid), .m_awready(st_awready),
		.m_wdata(st_wdata), .m_wstrb(st_wstrb), .m_wlast(st_wlast), .m_wvalid(st_wvalid), .m_wready(st_wready),
		.m_bid(st_bid), .m_bresp(st_bresp), .m_bvalid(st_bvalid), .m_bready(st_bready),
		.m_arid(st_arid), .m_araddr(st_araddr), .m_arlen(st_arlen), .m_arsize(st_arsize),
		.m_arburst(st_arburst), .m_arlock(st_arlock), .m_arcache(st_arcache), .m_arprot(st_arprot),
		.m_arvalid(st_arvalid), .m_arready(st_arready),
		.m_rid(st_rid), .m_rdata(st_rdata), .m_rresp(st_rresp), .m_rlast(st_rlast),
		.m_rvalid(st_rvalid), .m_rready(st_rready)
	);
end else begin : gen_st_accel_off
	assign w_soc_apb_prdata  = 32'd0;
	assign w_soc_apb_pready  = w_soc_apb_psel;
	assign w_soc_apb_pslverror = 1'b0;
	assign w_st_irq = 1'b0;
	assign w_hw_x_we = 1'b0;
	assign w_hw_load_w = 1'b0;
	assign w_hw_start = 1'b0;
	assign st_awvalid = 1'b0;
	assign st_wvalid  = 1'b0;
	assign st_bready  = 1'b0;
	assign st_arvalid = 1'b0;
	assign st_rready  = 1'b0;
end
endgenerate

riscv_soc0 u_riscv_soc0
(
	.io_systemClk                 (core_clk            ),
	.io_asyncReset                (w_soc_async_reset   ),
	.io_systemReset               (w_soc_system_reset  ),

	// JTAG 调试口本工程未接（DEBUG=0 生成，引脚也不需要）
	.jtagCtrl_enable              (1'b0                ),
	.jtagCtrl_tdi                 (1'b0                ),
	.jtagCtrl_capture             (1'b0                ),
	.jtagCtrl_shift               (1'b0                ),
	.jtagCtrl_update              (1'b0                ),
	.jtagCtrl_reset               (1'b0                ),
	.jtagCtrl_tck                 (1'b0                ),
	.jtagCtrl_tdo                 (                    ),

	.userInterruptA               (w_st_irq            ),

	// APB3 从机（预留）
	.io_apbSlave_0_PADDR          (w_soc_apb_paddr     ),
	.io_apbSlave_0_PSEL           (w_soc_apb_psel      ),
	.io_apbSlave_0_PENABLE        (w_soc_apb_penable   ),
	.io_apbSlave_0_PWRITE         (w_soc_apb_pwrite    ),
	.io_apbSlave_0_PWDATA         (w_soc_apb_pwdata    ),
	.io_apbSlave_0_PRDATA         (w_soc_apb_prdata    ),
	.io_apbSlave_0_PREADY         (w_soc_apb_pready    ),
	.io_apbSlave_0_PSLVERROR      (w_soc_apb_pslverror ),

	// UART0 is routed to the FT4232 channel-C RX pin in the diagnostic build.
	// The normal build multiplexes this pin with the hardware telemetry sender.
	.system_uart_0_io_txd         (w_soc_uart_tx       ),
	.system_uart_0_io_rxd         (1'b1                ),

	// I2C0 -> 摄像头排线，开漏：write=0 时驱动低，write=1 时释放线上拉为高
	.system_i2c_0_io_scl_read     (io_cam_scl_IN       ),
	.system_i2c_0_io_scl_write    (w_soc_i2c_scl_write ),
	.system_i2c_0_io_sda_read     (io_cam_sda_IN       ),
	.system_i2c_0_io_sda_write    (w_soc_i2c_sda_write ),

	// GPIO0（预留按键/拨码）
	.system_gpio_0_io_writeEnable (w_soc_gpio_write_en ),
	.system_gpio_0_io_write       (w_soc_gpio_write    ),
	.system_gpio_0_io_read        (4'h0                )
);

// SoC GPIO0[0] -> led[1]：固件写完摄像头寄存器后常亮。led[0] 为 DDR 校准心跳。
assign led[1] = w_soc_gpio_write[0];
// led[2]（GPIOR_28）在原理图上是 UART_RX_3V3 -> FT4232 通道 C RXD，不是 LED。
// 由文末的调试 UART 驱动，把 HDMI 内部状态发回 PC；led[3] 仍为 0。
assign led[3]   = 1'b0;

assign io_cam_scl_OUT = 1'b0;
assign io_cam_scl_OE  = ~w_soc_i2c_scl_write;
assign io_cam_sda_OUT = 1'b0;
assign io_cam_sda_OE  = ~w_soc_i2c_sda_write;

assign o_cam_rst_p = ~w_arstn;


//=====================================================================================
// AXI2 priority arbiter: M0=frame_buffer (hi), M1=st (lo) -> DDR
//=====================================================================================
wire [AXI_ID_WIDTH-1:0]  fb_awid; wire [AXI_ADDR_WIDTH-1:0] fb_awaddr; wire [7:0] fb_awlen;
wire [2:0]  fb_awsize; wire [1:0] fb_awburst; wire fb_awlock; wire [3:0] fb_awcache;
wire [2:0]  fb_awprot; wire fb_awvalid, fb_awready;
wire [AXI_DATA_WIDTH-1:0] fb_wdata; wire [AXI_DATA_WIDTH/8-1:0] fb_wstrb;
wire fb_wlast, fb_wvalid, fb_wready;
wire [AXI_ID_WIDTH-1:0] fb_bid; wire [1:0] fb_bresp; wire fb_bvalid, fb_bready;
wire [AXI_ID_WIDTH-1:0] fb_arid; wire [AXI_ADDR_WIDTH-1:0] fb_araddr; wire [7:0] fb_arlen;
wire [2:0] fb_arsize; wire [1:0] fb_arburst; wire fb_arlock; wire [3:0] fb_arcache;
wire [2:0] fb_arprot; wire fb_arvalid, fb_arready;
wire [AXI_ID_WIDTH-1:0] fb_rid; wire [AXI_DATA_WIDTH-1:0] fb_rdata; wire [1:0] fb_rresp;
wire fb_rlast, fb_rvalid, fb_rready;

// ST AXI master (driven by u_st_accel when USE_DDR=1; idle tie-offs until connected below)
wire [AXI_ID_WIDTH-1:0] st_awid;
wire [AXI_ADDR_WIDTH-1:0] st_awaddr;
wire [7:0] st_awlen;
wire [2:0] st_awsize;
wire [1:0] st_awburst;
wire st_awlock;
wire [3:0] st_awcache;
wire [2:0] st_awprot;
wire st_awvalid, st_awready;
wire [AXI_DATA_WIDTH-1:0] st_wdata;
wire [AXI_DATA_WIDTH/8-1:0] st_wstrb;
wire st_wlast, st_wvalid, st_wready;
wire [AXI_ID_WIDTH-1:0] st_bid; wire [1:0] st_bresp; wire st_bvalid, st_bready;
wire [AXI_ID_WIDTH-1:0] st_arid;
wire [AXI_ADDR_WIDTH-1:0] st_araddr;
wire [7:0] st_arlen;
wire [2:0] st_arsize;
wire [1:0] st_arburst;
wire st_arlock;
wire [3:0] st_arcache;
wire [2:0] st_arprot;
wire st_arvalid, st_arready;
wire [AXI_ID_WIDTH-1:0] st_rid; wire [AXI_DATA_WIDTH-1:0] st_rdata; wire [1:0] st_rresp;
wire st_rlast, st_rvalid, st_rready;

//=====================================================================================
//frame buffer
//=====================================================================================
wire [7:0] 	ch0_r;
wire [7:0]    ch0_g;
wire [7:0]    ch0_b;
wire ch0_vs;
wire ch0_hs;
wire ch0_de;
wire [31:0] ch0_rgb32;
wire [23:0] w_frame_pix_num;
wire [15:0] w_rd_dbg_stall;
wire [11:0] w_rd_dbg_left;
wire [23:0] w_rd_dbg_push;
wire [111:0] w_rd_dbg_seq;
wire [63:0]  w_rd_dbg_sum4;
wire [31:0]  w_rd_dbg_mm;

// Debug: replace the sensor's pixels while keeping the sensor's own vs/hs/de
// timing.  0 = camera.  1 = word counter (word n of a frame carries n[15:0]),
// checked by the read-side sequence checker.  2 = visual geometry chart: gray
// ramp left to right, white 16 px bars at both line ends, a white line pair
// every 90 lines; any shift or wrap shows up as a displaced bar.
localparam [1:0] DBG_PATTERN = 2'd0;
localparam DBG_PATTERN_EN = (DBG_PATTERN == 2'd1);
reg        pat_vs_d = 1'b0, pat_hs_d = 1'b0;
reg [15:0] pat_word = 16'd0;
// Each frame starts the counter at a different base, so a displayed frame
// assembled partly from an older stored frame shows up as a sequence break.
reg [15:0] pat_base = 16'd0;
reg [9:0]  pat_x = 10'd0;     // word index within the line, two per beat
reg [9:0]  pat_y = 10'd0;
always @(posedge i_mipi_rx_pclk) begin
	pat_vs_d <= w_mipi_rx_vs;
	pat_hs_d <= w_mipi_rx_hs;
	if (w_mipi_rx_vs & ~pat_vs_d) begin
		pat_word <= pat_base;
		pat_base <= pat_base + 16'd4098;
	end
	else if (w_mipi_rx_de & w_mipi_rx_hs)
		pat_word <= pat_word + 16'd2;
	if (w_mipi_rx_vs & ~pat_vs_d)
		pat_y <= 10'd0;
	else if (~w_mipi_rx_hs & pat_hs_d)
		pat_y <= pat_y + 10'd1;
	if (w_mipi_rx_hs & ~pat_hs_d)
		pat_x <= 10'd0;
	else if (w_mipi_rx_de & w_mipi_rx_hs)
		pat_x <= pat_x + 10'd2;
end
wire       pat_white = (pat_x < 10'd8) || (pat_x >= 10'd632) || (pat_y % 10'd90 < 10'd2);
wire [7:0] pat_gray  = pat_white ? 8'hFF : {pat_x[9:2]};
// CSI-2 RX puts the first pixel of a beat in the lowest slice (p0 = [9:0]).
// Downstream, the frame store emits the high 16 bits of each 32-bit word
// first, and the debayer input {ch0_b, ch0_g} takes the high byte of each
// word as its LEFT pixel.  So the first pixel goes in the top byte, in order:
// {p0, p1, p2, p3}.  The old {p3,p2,p1,p0} packing showed p2 p3 p0 p1 and
// later p1 p0 p3 p2: swapped pairs gave a 2-pixel sawtooth on vertical
// edges, swapped pixels inside a pair gave red/blue fringes, and the CFA phase
// had been chosen to match, so colour still looked right.
wire [31:0] cam_vin = {w_mipi_rx_data[9:2],w_mipi_rx_data[19:12],w_mipi_rx_data[29:22],w_mipi_rx_data[39:32]};
wire [31:0] fb_vin  = (DBG_PATTERN == 2'd1) ? {pat_word, pat_word + 16'd1} :
                      (DBG_PATTERN == 2'd2) ? {4{pat_gray}} : cam_vin;

// IMX219
  frame_buffer #(
.I_VID_WIDTH         (32),
.O_VID_WIDTH         (16),
.START_ADDR          (32'h00000),
.AXI_DATA_WIDTH      ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH      ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	      ( 1024		),    
.RD_FIFO_DEPTH 	      ( 1024 	),
.BURST_LEN  	       (127),
.FB_NUM	            (3),
.RD_FREE_RUN        (1),
.MAX_VID_WIDTH	    (960) ,
.MAX_VID_HIGHT	    (1080),
.CAM_VID_WIDTH     (CAM_VID_WIDTH ),
.CAM_VID_HEIGHT    (CAM_VID_HEIGHT)


)checker0(
       .axi_clk		(core_clk 	        ),
       .rst_n			(vid_rst_n   ),

/*i*/.i_clk			(i_mipi_rx_pclk      ),
/*i*/.i_vs			(w_mipi_rx_vs	),
/*i*/.i_de			(w_mipi_rx_de & w_mipi_rx_hs	),
/*i*/.vin 			(fb_vin	),
                     
/*i*/.o_clk			(vid_clk_dvi2),//(i_mipi_rx_pclk	),
/*i*/.o_hs    		(ch0_hs		),			
/*i*/.o_vs    		(ch0_vs		),			
/*i*/.o_de    		(ch0_de		),			
/*i*/.vout    		({ch0_g,ch0_b}	),
/*o*/.frame_pix_num (w_frame_pix_num),
/*o*/.rd_dbg_stall  (w_rd_dbg_stall),
/*o*/.rd_dbg_left   (w_rd_dbg_left),
/*o*/.rd_dbg_push   (w_rd_dbg_push),
/*o*/.rd_dbg_seq    (w_rd_dbg_seq),
/*o*/.rd_dbg_sum4   (w_rd_dbg_sum4),
/*o*/.rd_dbg_mm     (w_rd_dbg_mm),

/*i*/.H_FRONT_PORCH (HFP/2  		),//
/*i*/.H_SYNC 	 	    (HSP/2	 	),///2
/*i*/.H_VALID 	 	  (MAX_HRES/2     ),//
/*i*/.H_BACK_PORCH	(HBP/2		),//
/*i*/.V_FRONT_PORCH (VFP  		),//
/*i*/.V_SYNC 	 	    (VSP 	 	),//
/*i*/.V_VALID 	 	  (MAX_VRES     ),//
/*i*/.V_BACK_PORCH	(VBP		),//

       .awid			(fb_awid	),      
       .awaddr		(fb_awaddr	),
       .awlen			(fb_awlen	),
       .awsize		(fb_awsize	),
       .awburst		(fb_awburst),
       .awprot    (fb_awprot ),
       .awcache   (fb_awcache),
       .awlock		(fb_awlock	),
       .awvalid		(fb_awvalid),
       .awready		(fb_awready),

       .arid			(fb_arid	  ),
       .araddr		(fb_araddr	),
       .arlen			(fb_arlen	),
       .arsize		(fb_arsize	),
       .arburst 	(fb_arburst),

       .arprot    (fb_arprot ),
       .arcache   (fb_arcache),
       .arlock 		(fb_arlock	),
       .arvalid		(fb_arvalid),
       .arready		(fb_arready),

       .wdata			(fb_wdata	),
       .wstrb			(fb_wstrb	),
       .wlast			(fb_wlast	),
       .wvalid		(fb_wvalid	),
       .wready		(fb_wready	),


       .rid			  (fb_rid	),
       .rdata			(fb_rdata	),
       .rlast			(fb_rlast	),
       .rvalid 		(fb_rvalid	),
       .rready		(fb_rready	),
       .rresp			(fb_rresp	),

       .bid			  (fb_bid	),
       .bvalid		(fb_bvalid	),
       .bready	  (fb_bready	)
);




//=====================================================================================
// Video subsystem (rtl/vid): frame-ring DMA, AXI arbitration onto the DDR port.
// Master 0 is the legacy frame store above (highest priority); the subsystem's
// own masters follow.  Phase 1 runs only its DMA self-test next to the legacy
// picture path.
//=====================================================================================
vid_pkg::vid_status_t w_vid_status;
wire [7:0] vid_pix_r, vid_pix_g, vid_pix_b;
wire       vid_pix_de, vid_pix_hs, vid_pix_vs;

vid_subsystem #(
    .ENABLE_SELFTEST (1),
    // The screen shows the new path (VIDEO_PIPE_NEW); the legacy frame store
    // is not needed and only competes for DDR reads.
    .LEGACY_EN       (0)
) u_vid (
    .clk         (core_clk),
    .rst_n       (vid_rst_n),

    .lg_awid     (fb_awid),    .lg_awaddr (fb_awaddr), .lg_awlen  (fb_awlen),
    .lg_awvalid  (fb_awvalid), .lg_awready(fb_awready),
    .lg_wdata    (fb_wdata),   .lg_wlast  (fb_wlast),  .lg_wvalid (fb_wvalid), .lg_wready (fb_wready),
    .lg_bid      (fb_bid),     .lg_bresp  (fb_bresp),  .lg_bvalid (fb_bvalid), .lg_bready (fb_bready),
    .lg_arid     (fb_arid),    .lg_araddr (fb_araddr), .lg_arlen  (fb_arlen),
    .lg_arvalid  (fb_arvalid), .lg_arready(fb_arready),
    .lg_rid      (fb_rid),     .lg_rdata  (fb_rdata),  .lg_rresp  (fb_rresp),
    .lg_rlast    (fb_rlast),   .lg_rvalid (fb_rvalid), .lg_rready (fb_rready),

    .ddr_awid    (s_axi_awid),    .ddr_awaddr (s_axi_awaddr), .ddr_awlen  (s_axi_awlen),
    .ddr_awsize  (s_axi_awsize),  .ddr_awburst(s_axi_awburst), .ddr_awlock (s_axi_awlock),
    .ddr_awcache (s_axi_awcache), .ddr_awprot (s_axi_awprot),
    .ddr_awvalid (s_axi_awvalid), .ddr_awready(s_axi_awready),
    .ddr_wdata   (s_axi_wdata),   .ddr_wstrb  (s_axi_wstrb),  .ddr_wlast  (s_axi_wlast),
    .ddr_wvalid  (s_axi_wvalid),  .ddr_wready (s_axi_wready),
    .ddr_bid     (s_axi_bid),     .ddr_bresp  (s_axi_bresp),  .ddr_bvalid (s_axi_bvalid),
    .ddr_bready  (s_axi_bready),
    .ddr_arid    (s_axi_arid),    .ddr_araddr (s_axi_araddr), .ddr_arlen  (s_axi_arlen),
    .ddr_arsize  (s_axi_arsize),  .ddr_arburst(s_axi_arburst), .ddr_arlock (s_axi_arlock),
    .ddr_arcache (s_axi_arcache), .ddr_arprot (s_axi_arprot),
    .ddr_arvalid (s_axi_arvalid), .ddr_arready(s_axi_arready),
    .ddr_rid     (s_axi_rid),     .ddr_rdata  (s_axi_rdata),  .ddr_rresp  (s_axi_rresp),
    .ddr_rlast   (s_axi_rlast),   .ddr_rvalid (s_axi_rvalid), .ddr_rready (s_axi_rready),

    .pix_clk     (hdmi_tx_slow_clk),
    .pix_r       (vid_pix_r),  .pix_g (vid_pix_g),  .pix_b (vid_pix_b),
    .pix_de      (vid_pix_de), .pix_hs(vid_pix_hs), .pix_vs(vid_pix_vs),

    .status      (w_vid_status)
);

// ST's AXI master is a stub (see st_accel.v); until it is connected as a
// subsystem master, nothing answers it.
assign st_awready = 1'b0;
assign st_wready  = 1'b0;
assign st_bvalid  = 1'b0;
assign st_bid     = '0;
assign st_bresp   = 2'b00;
assign st_arready = 1'b0;
assign st_rvalid  = 1'b0;
assign st_rid     = '0;
assign st_rdata   = '0;
assign st_rresp   = 2'b00;
assign st_rlast   = 1'b0;

ddr3_top                 u_ddr3_top
(

.axi_clk                (core_clk            ),
.core_clk               (core_clk            ),
.sdram_clk              (sdram_clk           ),  
.rx_cal_clk             (rx_cal_clk          ),
.tx_cal_clk             (tx_cal_clk          ),
.tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
.rstn                   (w_arstn             ),      
.pll_shift              (pll_shift           ),
.pll_shift_sel          (pll_shift_sel       ),
.pll_shift_ena          (pll_shift_ena       ),       
///////////////DDR BUS
.ddr_ck_hi              (ddr_ck_hi           ),
.ddr_ck_lo              (ddr_ck_lo           ),
.ddr_cke                (ddr_cke             ),    
.ddr_reset_n            (ddr_reset_n         ),
.ddr_cs_n               (ddr_cs_n            ),
.ddr_ras_n              (ddr_ras_n           ),
.ddr_cas_n              (ddr_cas_n           ),
.ddr_we_n               (ddr_we_n            ),     
.ddr_addr               (ddr_addr            ),
.ddr_ba                 (ddr_ba              ),

.ddr_dqs_oe             (ddr_dqs_oe          ),
.ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
.ddr_dq_oe              (ddr_dq_oe           ),
.ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
.ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
.ddr_dq_in_hi           (ddr_dq_in_hi        ),
.ddr_dq_in_lo           (ddr_dq_in_lo        ),

.ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
.ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
.ddr_dq_out_hi          (ddr_dq_out_hi       ),
.ddr_dq_out_lo          (ddr_dq_out_lo       ),

.ddr_dm_hi              (ddr_dm_hi           ),
.ddr_dm_lo              (ddr_dm_lo           ),
.ddr_odt                (ddr_odt             ),

// Application interface ports
.app_sr_req                     (1'b0),
.app_ref_req                    (1'b0),
.app_zq_req                     (1'b0),
.app_sr_active                  (app_sr_active),
.app_ref_ack                    (app_ref_ack),
.app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
.s_axi_awid                     (s_axi_awid        ),
.s_axi_awaddr                   (s_axi_awaddr      ),
.s_axi_awlen                    (s_axi_awlen       ),
.s_axi_awsize                   (s_axi_awsize      ),
.s_axi_awburst                  (s_axi_awburst     ),
.s_axi_awlock                   (s_axi_awlock      ),
.s_axi_awcache                  (s_axi_awcache     ),
.s_axi_awprot                   (s_axi_awprot      ),
.s_axi_awqos                    (4'h0              ),
.s_axi_awvalid                  (s_axi_awvalid     ),
.s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
.s_axi_wdata                    (s_axi_wdata       ),
.s_axi_wstrb                    (s_axi_wstrb       ),
.s_axi_wlast                    (s_axi_wlast       ),
.s_axi_wvalid                   (s_axi_wvalid      ),
.s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
.s_axi_bid                      (s_axi_bid         ),
.s_axi_bresp                    (s_axi_bresp       ),
.s_axi_bvalid                   (s_axi_bvalid      ),
.s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
.s_axi_arid                     (s_axi_arid        ),
.s_axi_araddr                   (s_axi_araddr      ),
.s_axi_arlen                    (s_axi_arlen       ),
.s_axi_arsize                   (s_axi_arsize      ),
.s_axi_arburst                  (s_axi_arburst     ),
.s_axi_arlock                   (s_axi_arlock      ),
.s_axi_arcache                  (s_axi_arcache     ),
.s_axi_arprot                   (s_axi_arprot      ),
.s_axi_arqos                    (4'h0              ),
.s_axi_arvalid                  (s_axi_arvalid     ),
.s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
.s_axi_rid                      (s_axi_rid         ),
.s_axi_rdata                    (s_axi_rdata       ),
.s_axi_rresp                    (s_axi_rresp       ),
.s_axi_rlast                    (s_axi_rlast       ),
.s_axi_rvalid                   (s_axi_rvalid      ),
.s_axi_rready                   (s_axi_rready      ),
//DEBUG       
.wrlvl_dq_check                 (wrlvl_dq_check    ) ,
.rd_level_dqs_check             (rd_level_dqs_check) ,
.init_cur_state                 (init_cur_state    ) ,
.idelay_ld                      (idelay_ld         ) ,
.mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
.cal_done                       (cal_done          ) 
);

//***************************************************************************
// debayer
//***************************************************************************


wire        rgb_vs;
wire        rgb_hs;
wire        rgb_de;
wire        rgb_valid;
wire [47:0] rgb_datax2;
wire [15:0] r_gain;
wire [15:0] g_gain;
wire [15:0] b_gain;

//----------------------------------------------------------------------------
// 白平衡（硬编码，不再依赖 VIO —— VIO 实测没生效，三个增益都是 0）
//
// 原理：Bayer 阵列绿色像素占 50% 且灵敏度最高，原始数据天生偏绿。
//       gain_g 作用于 G 像素位置，是唯一无歧义地控制绿色通道的增益。
//       要压绿就减小 WB_G；要补红/蓝只能减小 WB_G（因为增益 >1.0 会削顶，
//       rgb_gain_v1 的输出 [15:8] 没有整数位余量）。
//
// 调法：对着白纸调 WB_G，直到白色不再发绿。WB_G 越小越偏品红。
//       256 = 1.000x   213 = 0.832x(当前)   160 = 0.625x   128 = 0.500x
//----------------------------------------------------------------------------
localparam WB_R = 16'd256;	// 红光通道 (1.000x)
localparam WB_G = 16'd133;	// 绿光通道 (0.520x) —— binning 模式按灰度世界: G 均值约为 R/B 的 1.9 倍
localparam WB_B = 16'd256;	// 蓝光通道 (1.000x)

//============================================================================
// 白平衡扫描模式  (WB_SCAN_EN = 1'b1)
//
// 把画面横向切成 8 条竖带, 每条竖带用不同的 g_gain, 一次综合就能看出哪一档
// 白平衡最中性。找到之后把那个值填进 WB_G, 再把 WB_SCAN_EN 改回 1'b0。
//
// vid_clk_dvi2 域内每行有效像素 960 个计数 (debayer 每拍出 2 像素 = 1920 宽),
// 所以每 120 个计数画一条竖带, 正好 8 条。
//
// 注意: debayer 有流水线延迟, 竖带边界会比实际像素位置右移几十像素,
//       不影响"从左往右第几条"的判断。
//============================================================================
localparam WB_SCAN_EN = 1'b0;      // 1'b1 = 扫描模式(重新调白平衡时打开) , 1'b0 = 正常

reg [9:0] wb_xcnt = 10'd0;
always @(posedge vid_clk_dvi2 or negedge vid_rst_n)
begin
  if (!vid_rst_n)
    wb_xcnt <= 10'd0;
  else if (!ch0_de)
    wb_xcnt <= 10'd0;
  else if (wb_xcnt != 10'd959)
    wb_xcnt <= wb_xcnt + 1'b1;
end

wire [2:0] wb_band =
    (wb_xcnt < 10'd120) ? 3'd0 :
    (wb_xcnt < 10'd240) ? 3'd1 :
    (wb_xcnt < 10'd360) ? 3'd2 :
    (wb_xcnt < 10'd480) ? 3'd3 :
    (wb_xcnt < 10'd600) ? 3'd4 :
    (wb_xcnt < 10'd720) ? 3'd5 :
    (wb_xcnt < 10'd840) ? 3'd6 : 3'd7;

reg [15:0] wb_g_sel;
always @(*)
begin
  case (wb_band)
    3'd0   : wb_g_sel = 16'h00A6;   // 第 1 条 (最左)  0.648x
    3'd1   : wb_g_sel = 16'h00B1;   // 第 2 条         0.691x
    3'd2   : wb_g_sel = 16'h00BC;   // 第 3 条         0.734x
    3'd3   : wb_g_sel = 16'h00C8;   // 第 4 条         0.781x  <-- 当前兜底值
    3'd4   : wb_g_sel = 16'h00D5;   // 第 5 条         0.832x  <-- 2026-09-23 实测选定
    3'd5   : wb_g_sel = 16'h00E2;   // 第 6 条         0.883x
    3'd6   : wb_g_sel = 16'h00F1;   // 第 7 条         0.941x
    default: wb_g_sel = 16'h0100;   // 第 8 条 (最右)  1.000x
  endcase
end

wire [15:0] g_gain_eff = WB_SCAN_EN ? wb_g_sel : (|g_gain ? g_gain : WB_G);

//----------------------------------------------------------------------------
// Black level.  The sensor holds its dark level at 64/1023 (16 in the 8-bit
// slice the frame store keeps).  Left in, it lifts every shadow, and gamma
// turns that into a grey haze over the whole picture.  Subtract it and stretch
// the remainder back to full scale: 255/(255-16) ~= 273/256.
// Combinational on purpose: a register here would put the data one clock
// behind ch0_de/hs/vs, which the debayer consumes unchanged.
//----------------------------------------------------------------------------
localparam [7:0] BLC_LEVEL = 8'd16;
function [7:0] blc8;
	input [7:0] v;
	reg   [7:0] d;
	reg   [16:0] m;
	begin
		d = (v > BLC_LEVEL) ? (v - BLC_LEVEL) : 8'd0;
		m = d * 9'd273;
		blc8 = (m[16:8] > 9'd255) ? 8'd255 : m[15:8];
	end
endfunction
wire [7:0] ch0_g_blc = blc8(ch0_g);
wire [7:0] ch0_b_blc = blc8(ch0_b);

debayer_top_2to1 debayer_top
(
	.in_pclk		  (vid_clk_dvi2),//(i_mipi_rx_pclk ),
	.in_rstn		  (vid_rst_n	),
	
	.raw_vs_i		  (ch0_vs		      ),
	.raw_hs_i		  (ch0_hs		      ),
	.raw_de_i		  (ch0_de		      ),
	.raw_valid_i	(ch0_de	        ),
	.raw_datax4_i	({ch0_b_blc,ch0_g_blc}	),
	.r_gain (|r_gain ? r_gain : WB_R ),
  .g_gain (g_gain_eff ),
  .b_gain (|b_gain ? b_gain : WB_B ),
	.rgb_vs_o		  (rgb_vs         ),
	.rgb_hs_o		  (rgb_hs         ),
	.rgb_de_o		  (rgb_de         ),
	.rgb_valid_o	(rgb_valid      ),
	.rgb_datax2_o (rgb_datax2     )//b,g,r,b,g,r
);
reg rgb_vs_r = 'd0;
always @( posedge hdmi_tx_slow_clk )
begin
  rgb_vs_r <= rgb_vs;
end
assign pos_vs = {rgb_vs_r,rgb_vs} == 2'b01;
reg vid_cnt = 'd0;
reg [7:0] hdmi_tx_rdata ;
reg [7:0] hdmi_tx_gdata ;
reg [7:0] hdmi_tx_bdata ;
reg hdmi_tx_vs;
reg hdmi_tx_hs;
reg hdmi_tx_de;
always @( posedge hdmi_tx_slow_clk )
begin
    if( pos_vs )
      vid_cnt <= 1'b1;
    else if( rgb_de )
      vid_cnt <= ~vid_cnt ;

    if( vid_cnt )
      {hdmi_tx_bdata,hdmi_tx_gdata,hdmi_tx_rdata} <= rgb_datax2[23:0];
    else 
      {hdmi_tx_bdata,hdmi_tx_gdata,hdmi_tx_rdata} <= rgb_datax2[47:24];

  hdmi_tx_vs <= rgb_vs;
  hdmi_tx_hs <= rgb_hs;
  hdmi_tx_de <= rgb_de;
end
//==============================================================================
// MIPI DSI
//==============================================================================
// signal 

reg		[25:0]	r_rst_cnt;

wire	[31:0]	w_axi_rdata;
wire			w_axi_awready;
wire			w_axi_wready;
wire			w_axi_arready;
wire			w_axi_rvalid;
wire			w_axi_bvalid;

wire	[6:0]	w_axi_awaddr;
wire			w_axi_awvalid;
wire	[31:0]	w_axi_wdata;
wire			w_axi_wvalid;
wire			w_axi_bready;
wire	[6:0]	w_axi_araddr;
wire			w_axi_arvalid;
wire			w_axi_rready;

wire			w_confdone;
assign w_confdone = 1'b1;

assign  LCD_POWER 			= i_arstn;
assign	LCD_RST_P	      = ~w_arstn;//~r_rst_cnt[23]; LCD复位先释放，然后再释放MIPI 的复位
assign	mipi_dp_clk_RST		= ~i_arstn;
assign	mipi_dp_data0_RST	= ~i_arstn;
assign	mipi_dp_data1_RST	= ~i_arstn;
assign	mipi_dp_data2_RST	= ~i_arstn;
assign	mipi_dp_data3_RST	= ~i_arstn;
////////////////////////////////////////////////////////////////
always@(posedge i_mipi_clk or  negedge w_arstn )
begin
  if ( !w_arstn ) begin
    r_rst_cnt	<= 'd0;
  end else 		
    r_rst_cnt	<= r_rst_cnt[25] ? r_rst_cnt :r_rst_cnt + 1'b1;
end

wire axi_rst_n = r_rst_cnt[25];

reg [26:0] dly_cnt = 'd0;

always @( posedge vid_clk_dvi2 or negedge w_arstn )
begin
  if( !w_arstn )
    dly_cnt <= 'd0;
  else if( w_confdone )
    dly_cnt <= dly_cnt[26] ? dly_cnt :(dly_cnt + 1'b1);
  else 
    dly_cnt <= 'd0;
end 

assign vid_rst_n = dly_cnt[26];




wire hs;
wire vs;
wire de;
wire [7:0] rgb_r;
wire [7:0] rgb_g;
wire [7:0] rgb_b;
  
  // color_bar_rgb #(
  // .HS_POLORY 		(1'b1		),
  // .VS_POLORY 		(1'b1		),
  // .H_FRONT_PORCH 	(HFP		),///2
  // .H_SYNC 		(HSP		),//
  // .H_VALID 		(MAX_HRES	),//
  // .H_BACK_PORCH 	(HBP		),//
  // .V_FRONT_PORCH 	(VFP		),
  // .V_SYNC 		(VSP		),
  // .V_VALID 		(MAX_VRES	),
  // .V_BACK_PORCH 	(VBP		),
  // .TEST_MODE 		(2'd2)
  // )u_color_bar_rgb1(
  // /*i*/.clk	(vid_clk_dvi2),//(vid_clk),
  // /*i*/.rst_n	(vid_rst_n),
  // /*o*/.hs	(hs),
  // /*o*/.vs	(vs),
  // /*o*/.de	(de),
  // // /*O*/.h_cnt (h_cnt),
  // // /*O*/.v_cnt (v_cnt),
  // /*o*/.rgb_r	(rgb_r),    //像素数据、红色分量
  // /*o*/.rgb_g	(rgb_g),    //像素数据、绿色分量
  // /*o*/.rgb_b (rgb_b)    //像素数据、蓝色分量
  
  // );

//=================================================================================
//hdmi tx ctrl 
//=================================================================================
wire                            video_hs;
wire                            video_vs;
wire                            video_de;
wire[7:0]                       video_r;
wire[7:0]                       video_g;
wire[7:0]                       video_b;

assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

// 	  color_bar color_bar_m0(
// 	.clk(hdmi_tx_slow_clk),
// 	.rst(~vid_rst_n),
// 	.hs(video_hs),
// 	.vs(video_vs),
// 	.de(video_de),
// 	.rgb_r(video_r),
// 	.rgb_g(video_g),
// 	.rgb_b(video_b)
// );

wire [9:0] tmds_data0;
wire [9:0] tmds_data1;
wire [9:0] tmds_data2;
wire [9:0] tmds_clk ;
wire [7:0] gamma_rdata ;
wire [7:0] gamma_gdata ;
wire [7:0] gamma_bdata ;
wire gamma_valid;
wire gamma_hs;
wire gamma_vs;
// 参考工程里这一位来自 JTAG VIO（上电初值由 DbgWizard 生成的 debug_top.v 决定，
// 那个文件常年是陈旧副本，改了也不生效）。本工程不带 debug core，直接参数化：
//   GAMMA_BYPASS = 0 -> 走 gamma 校正（默认）
//   GAMMA_BYPASS = 1 -> 旁路直通（A/B 对比用）
localparam GAMMA_BYPASS = 1'b0;	// 1'b0 = 走 gamma 校正(默认) , 1'b1 = 旁路直通(对比用)

wire [7:0] con_rdata ;
wire [7:0] con_gdata ;
wire [7:0] con_bdata ;
wire con_de;
wire con_hs;
wire con_vs;
wire con_sel;

wire [7:0] BRIGHT_SIG    ;
wire CONTRAST_SIG_G;
wire CONTRAST_SIG_R;
wire [7:0] CONTRAST_G    ;
wire CONTRAST_SIG_B;
wire [7:0] BRIGHT        ;
wire [7:0] CONTRAST_R    ;


wire CONTRAST_B    ;


gamma_correction
#(
	.DATA_WIDTH		(8),
	.GAMMA_CURVE	("./rtl/gamma_conrrection/SRGB_ENC.mem")
)
inst_gamma_correction
(
	.i_pclk		(hdmi_tx_slow_clk),
	.i_rstn		(vid_rst_n),
	
	.i_red		(hdmi_tx_rdata),//(con_rdata  ),//
	.i_green	(hdmi_tx_gdata),//(con_gdata  ),//
	.i_blue		(hdmi_tx_bdata),//(con_bdata  ),//
  .i_valid	(hdmi_tx_de   ),//(con_de     ),//
  .i_hs     (hdmi_tx_hs   ),//(con_hs     ),//
  .i_vs     (hdmi_tx_vs   ),//(con_vs     ),//
	.o_blue		(gamma_bdata		),
  .o_green	(gamma_gdata	  ),
	.o_red		(gamma_rdata		),
	.o_valid	(gamma_valid	  ),
  .o_hs     (gamma_hs       ),
  .o_vs     (gamma_vs       )
);

//==============================================================================
// 通道命名警告 —— 原厂约定，不要"顺手修正"！
//
//   v6 的 debayer 输出顺序是 {b,g,r}，L772 拼接后：
//       hdmi_tx_rdata 里装的是 debayer_r
//       hdmi_tx_bdata 里装的是 debayer_b
//   而原厂把 debayer_r 接到编码器的 .i_bdata、debayer_b 接到 .i_rdata。
//   （v1 的 debayer 输出是 {r,g,b}，顶层写法和 v6 相反，但效果等价 ——
//     两版都是 debayer_r 进 .i_bdata。这是原厂 demo 实机验证过的接法。）
//
//   只要保证 gamma 分支和旁路分支两者一致即可。曾经因为只改了旁路分支，
//   造成 gamma 开/关时红蓝对调。
//==============================================================================
//==============================================================================
// 饱和度还原 (Saturation Boost)
//
// 为什么需要: Bayer 传感器三通道串扰很强, 必须做 3x3 颜色校正矩阵(CCM)才能
//             真正还原色彩浓度。这个 demo 没有 CCM, 所以画面天生低饱和、发灰。
//             这里用最轻量的办法补一部分: 以亮度 Y 为中心, 把色差 (C-Y) 拉大。
//
//   Y  = (77R + 150G + 29B) / 256      Rec.601 亮度
//   u  = C - Y + 256                   偏移成无符号, 范围 1..511
//   C' = Y + (SAT * u) >> 8 - SAT      钳位到 [0,255]
//
//        通道归属 (沿用原厂约定, 不要改):
//          post_rdata -> 编码器 .i_rdata -> 屏幕红
//          post_gdata -> 编码器 .i_gdata -> 屏幕绿
//          post_bdata -> 编码器 .i_bdata -> 屏幕蓝
//
//   SAT = 256 -> 1.00x 恒等还原 (C' = C, 可用于验证本模块不引入偏差)
//   SAT = 384 -> 1.50x 当前值
//   SAT = 512 -> 2.00x 很强
//
// 位置: gamma 之后、dvi_encoder 之前, 作用在最终显示值上。
//       放这里比放在 gamma 之前更直观, 也不会被 gamma 的压缩吃掉。
//
// 想一次综合就定下 SAT: 把 SAT_SCAN_EN 改成 1'b1, 画面会切成 8 条竖带,
//       从左到右 1.00x/1.125x/1.25x/1.375x/1.50x/1.625x/1.75x/2.00x。
//       挑最接近实物那条, 把值填进 SAT_Q 再把 SAT_SCAN_EN 关掉。
//==============================================================================
localparam SAT_SCAN_EN = 1'b0;      // 1'b1 = 8 条竖带扫描饱和度
localparam SAT_Q       = 16'd384;   // Q8.8 : 256 = 1.00x

reg [15:0] sat_band_sel;
always @(*)
begin
  case (wb_band)
    3'd0   : sat_band_sel = 16'd256;   // 第 1 条 (最左)  1.000x
    3'd1   : sat_band_sel = 16'd288;   // 第 2 条         1.125x
    3'd2   : sat_band_sel = 16'd320;   // 第 3 条         1.250x
    3'd3   : sat_band_sel = 16'd352;   // 第 4 条         1.375x
    3'd4   : sat_band_sel = 16'd384;   // 第 5 条         1.500x  <-- 当前值
    3'd5   : sat_band_sel = 16'd416;   // 第 6 条         1.625x
    3'd6   : sat_band_sel = 16'd448;   // 第 7 条         1.750x
    default: sat_band_sel = 16'd512;   // 第 8 条 (最右)  2.000x
  endcase
end

wire [15:0] sat_eff = SAT_SCAN_EN ? sat_band_sel : SAT_Q;

// gamma / 旁路 二选一, 取出最终显示值 (通道命名沿用原厂约定, 不要改)
wire [7:0] post_bdata = GAMMA_BYPASS ? hdmi_tx_rdata : gamma_rdata;
wire [7:0] post_gdata = GAMMA_BYPASS ? hdmi_tx_gdata : gamma_gdata;
wire [7:0] post_rdata = GAMMA_BYPASS ? hdmi_tx_bdata : gamma_bdata;
wire       post_de    = GAMMA_BYPASS ? hdmi_tx_de    : gamma_valid;
wire       post_hs    = GAMMA_BYPASS ? hdmi_tx_hs    : gamma_hs;
wire       post_vs    = GAMMA_BYPASS ? hdmi_tx_vs    : gamma_vs;

//------------------------------------------------------------------ 第 1 级
// Rec.601 亮度: Y = (77*R + 150*G + 29*B) / 256   权重和正好 256
// 注意通道归属: post_rdata -> 编码器 .i_rdata (屏幕红)
//               post_bdata -> 编码器 .i_bdata (屏幕蓝)
wire [15:0] sat_ymul = 16'd77 * post_rdata + 16'd150 * post_gdata + 16'd29 * post_bdata;
wire [7:0]  sat_y    = sat_ymul[15:8];

reg [7:0] s1_rdata, s1_gdata, s1_bdata, s1_y;
reg       s1_de, s1_hs, s1_vs;

always @(posedge hdmi_tx_slow_clk)
begin
  s1_rdata <= post_rdata;
  s1_gdata <= post_gdata;
  s1_bdata <= post_bdata;
  s1_y     <= sat_y;
  s1_de    <= post_de;
  s1_hs    <= post_hs;
  s1_vs    <= post_vs;
end

//------------------------------------------------------------------ 第 2 级
wire [9:0] sat_q  = sat_eff[9:0];

wire [8:0] su_r = {1'b0, s1_rdata} + 9'd256 - {1'b0, s1_y};   // 1..511
wire [8:0] su_g = {1'b0, s1_gdata} + 9'd256 - {1'b0, s1_y};
wire [8:0] su_b = {1'b0, s1_bdata} + 9'd256 - {1'b0, s1_y};

wire [17:0] sp_r = sat_q * su_r;
wire [17:0] sp_g = sat_q * su_g;
wire [17:0] sp_b = sat_q * su_b;

wire [10:0] pre_r = {1'b0, s1_y} + sp_r[17:8];
wire [10:0] pre_g = {1'b0, s1_y} + sp_g[17:8];
wire [10:0] pre_b = {1'b0, s1_y} + sp_b[17:8];

wire [10:0] cut_r = (pre_r > {1'b0, sat_q}) ? (pre_r - {1'b0, sat_q}) : 11'd0;
wire [10:0] cut_g = (pre_g > {1'b0, sat_q}) ? (pre_g - {1'b0, sat_q}) : 11'd0;
wire [10:0] cut_b = (pre_b > {1'b0, sat_q}) ? (pre_b - {1'b0, sat_q}) : 11'd0;

wire [7:0] clip_r = (cut_r > 11'd255) ? 8'd255 : cut_r[7:0];
wire [7:0] clip_g = (cut_g > 11'd255) ? 8'd255 : cut_g[7:0];
wire [7:0] clip_b = (cut_b > 11'd255) ? 8'd255 : cut_b[7:0];

reg [7:0] sat_bdata, sat_gdata, sat_rdata;
reg       sat_de, sat_hs, sat_vs;

always @(posedge hdmi_tx_slow_clk)
begin
  sat_rdata <= clip_r;      // post_rdata 通路 -> .i_rdata (屏幕红)
  sat_gdata <= clip_g;
  sat_bdata <= clip_b;      // post_bdata 通路 -> .i_bdata (屏幕蓝)
  sat_de    <= s1_de;
  sat_hs    <= s1_hs;
  sat_vs    <= s1_vs;
end


//==============================================================================
// HDMI 自测图样 (TP_EN)
//
// 目的: 把"摄像头/DDR/debayer/后处理这条视频通路"和"TMDS 物理发送"分开。
//   TP_EN=1 时, dvi_encoder 的输入完全由本地计数器产生标准 1080p60 时序 +
//   8 条竖彩条, 与摄像头、DDR、frame_buffer 全部无关。
//   接采集卡:
//     - 采集卡锁定并出图   -> TMDS 发送没问题, 问题在视频通路(时序/数据)
//     - 采集卡仍显示自身彩条 -> 问题在 TMDS 发送侧(电气/编码/时钟)
//==============================================================================
localparam TP_EN = 1'b0;

reg [11:0] tp_hcnt = 12'd0;
reg [11:0] tp_vcnt = 12'd0;

// CEA-861 1080p60 (format 16): H 1920/88/44/148 (总 2200), V 1080/4/5/36 (总 1125)
wire tp_hs = TP_EN & (tp_hcnt >= 12'd2008) & (tp_hcnt < 12'd2052);
wire tp_vs = TP_EN & (tp_vcnt >= 12'd1084) & (tp_vcnt < 12'd1089);
wire tp_de = TP_EN & (tp_hcnt < 12'd1920) & (tp_vcnt < 12'd1080);

always @(posedge hdmi_tx_slow_clk or negedge vid_rst_n) begin
  if (!vid_rst_n) begin
    tp_hcnt <= 12'd0;
    tp_vcnt <= 12'd0;
  end else if (tp_hcnt == 12'd2199) begin
    tp_hcnt <= 12'd0;
    tp_vcnt <= (tp_vcnt == 12'd1124) ? 12'd0 : tp_vcnt + 12'd1;
  end else begin
    tp_hcnt <= tp_hcnt + 12'd1;
  end
end

// 8 条竖彩条: 白 黄 青 绿 品红 红 蓝 黑, 每条 240 像素
reg [7:0] tp_r, tp_g, tp_b;
always @(*) begin
  case (tp_hcnt[10:8])
    3'd0: begin tp_r = 8'hFF; tp_g = 8'hFF; tp_b = 8'hFF; end
    3'd1: begin tp_r = 8'hFF; tp_g = 8'hFF; tp_b = 8'h00; end
    3'd2: begin tp_r = 8'h00; tp_g = 8'hFF; tp_b = 8'hFF; end
    3'd3: begin tp_r = 8'h00; tp_g = 8'hFF; tp_b = 8'h00; end
    3'd4: begin tp_r = 8'hFF; tp_g = 8'h00; tp_b = 8'hFF; end
    3'd5: begin tp_r = 8'hFF; tp_g = 8'h00; tp_b = 8'h00; end
    3'd6: begin tp_r = 8'h00; tp_g = 8'h00; tp_b = 8'hFF; end
    default: begin tp_r = 8'h00; tp_g = 8'h00; tp_b = 8'h00; end
  endcase
end

// VIDEO_PIPE_NEW = 1: the encoder shows the vid_subsystem compositor (frames
// from the DDR ring, rtl/vid); 0: the legacy camera path above.  The legacy
// path keeps running either way.
localparam VIDEO_PIPE_NEW = 1'b1;
wire [7:0] sel_r  = VIDEO_PIPE_NEW ? vid_pix_r  : sat_rdata;
wire [7:0] sel_g  = VIDEO_PIPE_NEW ? vid_pix_g  : sat_gdata;
wire [7:0] sel_b  = VIDEO_PIPE_NEW ? vid_pix_b  : sat_bdata;
wire       sel_de = VIDEO_PIPE_NEW ? vid_pix_de : sat_de;
wire       sel_hs = VIDEO_PIPE_NEW ? vid_pix_hs : sat_hs;
wire       sel_vs = VIDEO_PIPE_NEW ? vid_pix_vs : sat_vs;

wire [7:0] enc_r = TP_EN ? tp_r   : sel_r;
wire [7:0] enc_g = TP_EN ? tp_g   : sel_g;
wire [7:0] enc_b = TP_EN ? tp_b   : sel_b;
wire       enc_de = TP_EN ? tp_de  : sel_de;
wire       enc_hs = TP_EN ? tp_hs  : sel_hs;
wire       enc_vs = TP_EN ? tp_vs  : sel_vs;

dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~vid_rst_n      ),// reset
	.i_bdata      		(enc_b 	),
	.i_gdata     		  (enc_g   ),
	.i_rdata       		(enc_r 	),
  .i_de            	(enc_de      ),
	.i_hs         		(enc_hs    ),
	.i_vs         		(enc_vs    ),
	
  .video_format     (2'b00), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
  .video_VIC        (16),
	.audio_L			    (16'd0),
  .audio_R			    (16'd0),
  .audio_valid		  (1'b0),
  .audio_N                (6144),     //(20'h01880),//     
  .audio_CTS              (148500),      //(20'h28488),//      
  .audio_sample_frequency (3'b000),    //(3'b000),//
  .audio_word_length      (4'b0000),//(4'b1011),//

	.tmds_data0    		(tmds_data0),
  .tmds_data1    		(tmds_data1),
  .tmds_data2    		(tmds_data2),
  .tmds_clk      	  (tmds_clk  )
);
assign tmds_tx_clk_TX_DATA   = ~tmds_clk;
assign tmds_tx_data0_TX_DATA = ~tmds_data0;
assign tmds_tx_data1_TX_DATA = ~tmds_data1;
assign tmds_tx_data2_TX_DATA = ~tmds_data2;


//=============================================================================
// 未使用的外围输入引脚保持 (pin keep)
//
// fpga_src.peri.xml 直接沿用参考工程，其中声明的引脚必须全部存在，否则 PnR 报
//   ERROR: Required pin <name> is not found
// 本工程去掉了 JTAG debug core 与 DSI，这些输入就没有负载了；综合会把无负载的
// 输入端口裁掉，PnR 随即找不到引脚。这里把它们异或起来驱动 JTAG TDO：
// 引脚全部保留，且不引入任何功能。
//
// 将来重新加回 debug core 时，删掉本段并把 TDO 交回 debug core 即可。
//=============================================================================
// 注意: 时钟类引脚不能进这个异或（PnR 会报
//   "PLL output clock ... drives non-clock logic"）——未使用的时钟引脚
// 由 Interface Designer 自动保留，不需要在这里兜。
wire [12:0] w_unused_peri_in = {
	jtag_inst1_CAPTURE,     jtag_inst1_DRCK,        jtag_inst1_RESET,
	jtag_inst1_RUNTEST,     jtag_inst1_SEL,         jtag_inst1_SHIFT,
	jtag_inst1_TCK,         jtag_inst1_TDI,         jtag_inst1_TMS,
	jtag_inst1_UPDATE,      mipi_dp_data0_LP_P_IN,  mipi_dp_data0_LP_N_IN,
	pll_inst4_LOCKED
};
assign jtag_inst1_TDO = ^w_unused_peri_in;

//=============================================================================
// 板载 FT4232HL UART 状态回传（HDMI 调试）
//
// 原理图 Ti60F225A_V4_SCH.pdf sheet7 与本工程 outflow/fpga_src.pinout.csv
// 7/7 球号对齐：
//   N14=GPIOR_21=LED0   P14=GPIOR_22=LED1   P15=GPIOR_25=LED3
//   P13=GPIOR_27=KEY1   R14=GPIOR_28=UART_RX_3V3   R13=GPIOR_29=CLK_50M
// 即 peri 里叫 "led[2]" 的 GPIOR_28 实际经 R243 接到 FT4232 通道 C 的 RXD，
// 不是 LED。原代码 `assign led[3:2] = 2'b00;` 等于把 FTDI RXD 拉死在低电平。
//
// 现用它把 HDMI 关键内部状态发回 PC：115200 8N1，每 0.5s 一帧 48 字节
//   AA 55 | D[4] H[4] V[4] | SH[2] XH[2] | R | SEQ | ST_TILES[4] | ST_BUSY | DE_WIDTH[2] | RSV
//   D/H/V  enc_de/enc_hs/enc_vs 上升沿计数（core_clk 域，已 2-FF 同步）
//          1080p60 标称值：D=64800/s  H=67500/s  V=60/s
//   SH     hdmi_tx_slow_clk(148.5MHz) 心跳计数，标称约 566 次/0.5s
//   XH     vid_clk_dvi2(74.25MHz)    心跳计数，标称约 283 次/0.5s
//          心跳不再增长 => 该时钟停了
//   R      {w_arstn(PLL全锁), cal_done(DDR校准), vid_rst_n(视频复位释放),
//           SoC_GPIO0[0](摄像头I2C配置完成)}   标称 0x0F
//   SEQ    帧序号，用于发现丢帧
//=============================================================================
localparam integer UART_DIV = 868;              // 100MHz / 115200 = 868.06
localparam integer MSG_LEN  = 48;
localparam [25:0]  RELOAD   = 26'd50_000_000;   // 0.5s @ core_clk=100MHz
// 0 = 关闭诊断（综合会整块裁掉，时序回到基线）；1 = 打开，led[2] 输出状态帧。
// 注意实测：打开时 DDR 命令 FIFO 的 raddr->CE 会掉出 ~0.05ns 负 slack，
// 所以交付基线保持 0，需要现场排查 HDMI 时再置 1。
localparam DBG_UART_EN      = 1'b1;
// Temporary board bring-up switch: expose Sapphire RV32 UART0 on the same
// FT4232 RX pin so firmware can report camera-I2C progress.  Set to 0 for the
// normal binary telemetry protocol below.
localparam SOC_UART_DEBUG   = 1'b0;

// CDC 约定：所有要被 core_clk 采样的计数一律在 core_clk 域产生，跨域信号走
// 2-FF 同步；否则会在时序报告里留下 -1.193ns 的假违例（已实测踩过）。
// enc_* 是视频域电平信号，高/低电平分别维持 296ns~12.9µs，远大于 10ns 采样周期，
// 2-FF 同步不会丢沿。
reg [2:0] sync_de = 3'd0, sync_hs = 3'd0, sync_vs = 3'd0;
always @(posedge core_clk) begin
	sync_de <= {sync_de[1:0], enc_de};
	sync_hs <= {sync_hs[1:0], enc_hs};
	sync_vs <= {sync_vs[1:0], enc_vs};
end
wire de_q = sync_de[2], hs_q = sync_hs[2], vs_q = sync_vs[2];

// DE/HS/VS 上升沿计数（core_clk 域）
reg [31:0] dbg_d_cnt = 32'd0, dbg_h_cnt = 32'd0, dbg_v_cnt = 32'd0;
reg        dbg_d_r = 1'b0,    dbg_h_r = 1'b0,    dbg_v_r = 1'b0;
reg [15:0] dbg_de_width = 16'd0, dbg_de_last_width = 16'd0;
always @(posedge core_clk) begin
	dbg_d_r <= de_q;
	dbg_h_r <= hs_q;
	dbg_v_r <= vs_q;
	if ( de_q & ~dbg_d_r) dbg_d_cnt <= dbg_d_cnt + 32'd1;
	if ( hs_q & ~dbg_h_r) dbg_h_cnt <= dbg_h_cnt + 32'd1;
	if ( vs_q & ~dbg_v_r) dbg_v_cnt <= dbg_v_cnt + 32'd1;
	if (de_q) dbg_de_width <= dbg_de_width + 16'd1;
	else if (dbg_d_r) begin dbg_de_last_width <= dbg_de_width; dbg_de_width <= 16'd0; end
end

// 时钟心跳：各自域内每 2^16 周期翻转一次，core_clk 侧同步后数上升沿。
// 预期每 0.5s：hdmi_tx_slow_clk(148.5MHz) 约 566 次，vid_clk_dvi2(74.25MHz) 约 283 次。
// 时钟一停该计数就不再增长 —— 这是判断 TMDS 像素钟/视频钟是否在跑的直接依据。
reg [15:0] dbg_s_div = 16'd0, dbg_x_div = 16'd0;
reg        dbg_s_hb = 1'b0,   dbg_x_hb = 1'b0;
always @(posedge hdmi_tx_slow_clk) begin
	if (dbg_s_div == 16'hFFFF) begin dbg_s_div <= 16'd0; dbg_s_hb <= ~dbg_s_hb; end
	else dbg_s_div <= dbg_s_div + 16'd1;
end
always @(posedge vid_clk_dvi2) begin
	if (dbg_x_div == 16'hFFFF) begin dbg_x_div <= 16'd0; dbg_x_hb <= ~dbg_x_hb; end
	else dbg_x_div <= dbg_x_div + 16'd1;
end

reg [2:0] sync_shb = 3'd0, sync_xhb = 3'd0;
reg       dbg_shb_r = 1'b0, dbg_xhb_r = 1'b0;
reg [15:0] dbg_s_hb_cnt = 16'd0, dbg_x_hb_cnt = 16'd0;
always @(posedge core_clk) begin
	sync_shb <= {sync_shb[1:0], dbg_s_hb};
	sync_xhb <= {sync_xhb[1:0], dbg_x_hb};
	dbg_shb_r <= sync_shb[2];
	dbg_xhb_r <= sync_xhb[2];
	if ( sync_shb[2] & ~dbg_shb_r) dbg_s_hb_cnt <= dbg_s_hb_cnt + 16'd1;
	if ( sync_xhb[2] & ~dbg_xhb_r) dbg_x_hb_cnt <= dbg_x_hb_cnt + 16'd1;
end

// ST accelerator telemetry crosses from core_clk (accelerator control) into
// the UART/core domain.  The frame counter increments once per completed
// 16x16 inference tile; it is the direct proof that the network is making
// forward progress even when no display is attached.
reg [31:0] st_frame_sync1 = 32'd0, st_frame_sync2 = 32'd0;
reg st_busy_sync1 = 1'b0, st_busy_sync2 = 1'b0;
reg [31:0] cap_samples_sync1 = 32'd0, cap_samples_sync2 = 32'd0;
reg [31:0] cap_tiles_sync1 = 32'd0, cap_tiles_sync2 = 32'd0;
reg [31:0] commit_sync1 = 32'd0, commit_sync2 = 32'd0;
reg [15:0] last_x_sync1 = 16'd0, last_x_sync2 = 16'd0;
reg [15:0] last_y_sync1 = 16'd0, last_y_sync2 = 16'd0;
reg [7:0] last_cap_addr_sync1 = 8'd0, last_cap_addr_sync2 = 8'd0;
reg [7:0] last_commit_addr_sync1 = 8'd0, last_commit_addr_sync2 = 8'd0;
reg [15:0] cpu_hb_sync1 = 16'd0, cpu_hb_sync2 = 16'd0;
// Capture-side words per frame.  It only changes at frame boundaries, so a
// plain 2-FF synchroniser is enough; the value is a stable count, not an edge.
reg [23:0] fpn_sync1 = 24'd0, fpn_sync2 = 24'd0;
always @(posedge core_clk) begin
	fpn_sync1 <= w_frame_pix_num;
	fpn_sync2 <= fpn_sync1;
end

// Capture-side probe, straight off the CSI-2 RX outputs and ahead of
// frame_info_det.  It answers "is the receiver producing frames at all" without
// trusting any of the frame-store logic downstream.  ST is disabled, so its
// telemetry slots carry these instead.
//   cp_*_bin   cumulative: vs rising edges, hs rising edges, de cycles
//   cp_lines   hs rising edges between the last two vs rising edges
//   cp_beats   de cycles inside the last completed hs-high period
// The cumulative counters cross into core_clk as Gray code so a sample taken
// mid-increment is off by at most one instead of torn.
reg        cp_vs_d = 1'b0, cp_hs_d = 1'b0;
reg [31:0] cp_vs_bin = 32'd0, cp_hs_bin = 32'd0, cp_de_bin = 32'd0;
reg [31:0] cp_vs_gray = 32'd0, cp_hs_gray = 32'd0, cp_de_gray = 32'd0;
reg [15:0] cp_line_cnt = 16'd0, cp_lines = 16'd0;
reg [15:0] cp_beat_cnt = 16'd0, cp_beats = 16'd0;
always @(posedge i_mipi_rx_pclk) begin
	cp_vs_d <= w_mipi_rx_vs;
	cp_hs_d <= w_mipi_rx_hs;
	if (w_mipi_rx_vs & ~cp_vs_d) cp_vs_bin <= cp_vs_bin + 32'd1;
	if (w_mipi_rx_hs & ~cp_hs_d) cp_hs_bin <= cp_hs_bin + 32'd1;
	if (w_mipi_rx_de)            cp_de_bin <= cp_de_bin + 32'd1;
	cp_vs_gray <= cp_vs_bin ^ (cp_vs_bin >> 1);
	cp_hs_gray <= cp_hs_bin ^ (cp_hs_bin >> 1);
	cp_de_gray <= cp_de_bin ^ (cp_de_bin >> 1);

	if (w_mipi_rx_vs & ~cp_vs_d) begin
		cp_lines    <= cp_line_cnt;
		cp_line_cnt <= 16'd0;
	end else if (w_mipi_rx_hs & ~cp_hs_d) begin
		cp_line_cnt <= cp_line_cnt + 16'd1;
	end

	if (~w_mipi_rx_hs & cp_hs_d) begin
		cp_beats    <= cp_beat_cnt;
		cp_beat_cnt <= 16'd0;
	end else if (w_mipi_rx_hs & w_mipi_rx_de) begin
		cp_beat_cnt <= cp_beat_cnt + 16'd1;
	end
end

function [31:0] gray2bin32;
	input [31:0] g;
	integer k;
	begin
		gray2bin32[31] = g[31];
		for (k = 30; k >= 0; k = k - 1)
			gray2bin32[k] = gray2bin32[k+1] ^ g[k];
	end
endfunction

reg [31:0] cp_vs_s1 = 32'd0, cp_vs_s2 = 32'd0;
reg [31:0] cp_hs_s1 = 32'd0, cp_hs_s2 = 32'd0;
reg [31:0] cp_de_s1 = 32'd0, cp_de_s2 = 32'd0;
reg [15:0] cp_lines_s1 = 16'd0, cp_lines_s2 = 16'd0;
reg [15:0] cp_beats_s1 = 16'd0, cp_beats_s2 = 16'd0;
reg [2:0]  cp_lvl_s1 = 3'd0, cp_lvl_s2 = 3'd0;
// CSI-2 RX error flags, sticky since reset: {receive, frame_vc0, line_vc0,
// undersize, ecc2, ecc1, crc, pixel_fifo_full}.
reg [7:0]  cp_err_s1 = 8'd0, cp_err_s2 = 8'd0, cp_err_sticky = 8'd0;
always @(posedge core_clk) begin
	cp_vs_s1 <= cp_vs_gray;  cp_vs_s2 <= cp_vs_s1;
	cp_hs_s1 <= cp_hs_gray;  cp_hs_s2 <= cp_hs_s1;
	cp_de_s1 <= cp_de_gray;  cp_de_s2 <= cp_de_s1;
	cp_lines_s1 <= cp_lines; cp_lines_s2 <= cp_lines_s1;
	cp_beats_s1 <= cp_beats; cp_beats_s2 <= cp_beats_s1;
	cp_lvl_s1 <= {w_mipi_rx_vs, w_mipi_rx_hs, w_mipi_rx_de};
	cp_lvl_s2 <= cp_lvl_s1;
	cp_err_s1 <= {mdebug_receive_error, mdebug_frame_vc0_error,
	              mdebug_line_vc0_error, mdebug_undersize_pkt_error,
	              mdebug_ecc_2bit_error, mdebug_ecc_1bit_error,
	              mdebug_crc_error, mdebug_pixel_fifo_full};
	cp_err_s2 <= cp_err_s1;
	cp_err_sticky <= cp_err_sticky | cp_err_s2;
end

// Read-side per-frame values from vid_clk_dvi2; each is held for a whole
// displayed frame, so a 2-FF synchroniser sees a stable word.
reg [15:0] rd_stall_s1 = 16'd0, rd_stall_s2 = 16'd0;
reg [11:0] rd_left_s1 = 12'd0, rd_left_s2 = 12'd0;
reg [23:0] rd_push_s1 = 24'd0, rd_push_s2 = 24'd0;
reg [111:0] rd_seq_s1 = 112'd0, rd_seq_s2 = 112'd0;
reg [63:0]  rd_sum4_s1 = 64'd0, rd_sum4_s2 = 64'd0;
reg [31:0]  rd_mm_s1 = 32'd0, rd_mm_s2 = 32'd0;
always @(posedge core_clk) begin
	rd_stall_s1 <= w_rd_dbg_stall; rd_stall_s2 <= rd_stall_s1;
	rd_left_s1  <= w_rd_dbg_left;  rd_left_s2  <= rd_left_s1;
	rd_push_s1  <= w_rd_dbg_push;  rd_push_s2  <= rd_push_s1;
	rd_seq_s1   <= w_rd_dbg_seq;   rd_seq_s2   <= rd_seq_s1;
	rd_sum4_s1  <= w_rd_dbg_sum4;  rd_sum4_s2  <= rd_sum4_s1;
	rd_mm_s1    <= w_rd_dbg_mm;    rd_mm_s2    <= rd_mm_s1;
end
always @(posedge core_clk) begin
	st_frame_sync1 <= w_st_frame_cnt;
	st_frame_sync2 <= st_frame_sync1;
	st_busy_sync1 <= w_st_pipe_busy;
	st_busy_sync2 <= st_busy_sync1;
	cap_samples_sync1 <= st_dbg_cap_samples;
	cap_samples_sync2 <= cap_samples_sync1;
	cap_tiles_sync1 <= st_dbg_cap_tiles;
	cap_tiles_sync2 <= cap_tiles_sync1;
	commit_sync1 <= st_dbg_commit_count;
	commit_sync2 <= commit_sync1;
	last_x_sync1 <= st_dbg_last_x;
	last_x_sync2 <= last_x_sync1;
	last_y_sync1 <= st_dbg_last_y;
	last_y_sync2 <= last_y_sync1;
	last_cap_addr_sync1 <= st_dbg_last_cap_addr;
	last_cap_addr_sync2 <= last_cap_addr_sync1;
	last_commit_addr_sync1 <= st_dbg_last_commit_addr;
	last_commit_addr_sync2 <= last_commit_addr_sync1;
	cpu_hb_sync1 <= st_cpu_dbg_heartbeat;
	cpu_hb_sync2 <= cpu_hb_sync1;
end

// --- 报文（组合逻辑，取自最近一次锁存值） -----------------------------------
//   AA 55 | D[4] H[4] V[4] | SH[2] XH[2] | R | SEQ
reg [31:0] c_d, c_h, c_v;
reg [15:0] c_s, c_x;
reg [3:0]  c_r;
reg [7:0]  c_q;
reg [31:0] c_st_frame;
reg        c_st_busy;
reg [15:0] c_de_width;
reg [31:0] c_cap_samples, c_cap_tiles, c_commit_count;
reg [15:0] c_last_x, c_last_y;
reg [7:0] c_last_cap_addr, c_last_commit_addr;
reg [15:0] c_cpu_hb;
reg [23:0] c_frame_pix_num;
reg [7:0]  dbg_seq = 8'd0;

// vid_subsystem status is in core_clk already; one register stage keeps the
// wide mux off the telemetry path.
localparam TELEM_VID = 1'b1;    // 1 = report vid_subsystem status instead of raw stats
vid_pkg::vid_status_t vid_st_s2;
always @(posedge core_clk) vid_st_s2 <= w_vid_status;
reg [7:0]  dbg_msg [0:MSG_LEN-1];
integer dbg_i;
reg [7:0] dbg_crc;

always @(*) begin
	dbg_msg[0]  = 8'hAA;
	dbg_msg[1]  = 8'h55;
	dbg_msg[2]  = c_d[31:24]; dbg_msg[3] = c_d[23:16];
	dbg_msg[4]  = c_d[15:8];  dbg_msg[5] = c_d[7:0];
	dbg_msg[6]  = c_h[31:24]; dbg_msg[7] = c_h[23:16];
	dbg_msg[8]  = c_h[15:8];  dbg_msg[9] = c_h[7:0];
	dbg_msg[10] = c_v[31:24]; dbg_msg[11] = c_v[23:16];
	dbg_msg[12] = c_v[15:8];  dbg_msg[13] = c_v[7:0];
	dbg_msg[14] = c_s[15:8];  dbg_msg[15] = c_s[7:0];
	dbg_msg[16] = c_x[15:8];  dbg_msg[17] = c_x[7:0];
	dbg_msg[18] = {c_frame_pix_num[7:4], c_r};
	dbg_msg[19] = c_q;
	dbg_msg[20] = c_st_frame[31:24]; dbg_msg[21] = c_st_frame[23:16];
	dbg_msg[22] = c_st_frame[15:8];  dbg_msg[23] = c_st_frame[7:0];
	dbg_msg[24] = {c_frame_pix_num[3:0], 3'd0, c_st_busy};
	dbg_msg[25] = c_de_width[15:8]; dbg_msg[26] = c_de_width[7:0];
	// Capture geometry probe: 1280x720 must read 230400 (320 beats/line).
	// Half that means only two of the four MIPI lanes are delivering data.
	dbg_msg[27] = c_frame_pix_num[15:8];
	dbg_msg[28] = c_cap_samples[31:24]; dbg_msg[29] = c_cap_samples[23:16];
	dbg_msg[30] = c_cap_samples[15:8];  dbg_msg[31] = c_cap_samples[7:0];
	dbg_msg[32] = c_cap_tiles[31:24]; dbg_msg[33] = c_cap_tiles[23:16];
	dbg_msg[34] = c_cap_tiles[15:8];  dbg_msg[35] = c_cap_tiles[7:0];
	dbg_msg[36] = c_commit_count[31:24]; dbg_msg[37] = c_commit_count[23:16];
	dbg_msg[38] = c_commit_count[15:8];  dbg_msg[39] = c_commit_count[7:0];
	dbg_msg[40] = c_last_x[15:8]; dbg_msg[41] = c_last_x[7:0];
	dbg_msg[42] = c_last_y[15:8]; dbg_msg[43] = c_last_y[7:0];
	dbg_msg[44] = c_last_cap_addr;
	dbg_msg[45] = c_last_commit_addr;
	dbg_crc = 8'd0;
	for (dbg_i=0; dbg_i<46; dbg_i=dbg_i+1) dbg_crc = dbg_crc ^ dbg_msg[dbg_i];
	dbg_msg[46] = dbg_crc;
	dbg_msg[47] = c_cpu_hb[15:8];
end

// --- 115200 8N1 发送器（core_clk 域） ---------------------------------------
reg [25:0] dbg_tick    = 26'd0;
reg        dbg_pend    = 1'b0;
reg        dbg_sending = 1'b0;
// 48-byte diagnostic frame needs a 6-bit byte index; 5 bits silently wrapped
// at byte 32 and made the host parser wait forever for the checksum.
reg [5:0]  dbg_cidx    = 6'd0;
reg [9:0]  dbg_shift   = 10'h3FF;
reg [3:0]  dbg_bit     = 4'd0;
reg [15:0] dbg_baud    = 16'd0;
reg        dbg_uart_tx = 1'b1;

always @(posedge core_clk) begin
	// 每 0.5s：锁存计数并请求发送一帧
	if (dbg_tick == 26'd0) begin
		dbg_tick <= RELOAD;
		c_d <= dbg_d_cnt;  c_h <= dbg_h_cnt;  c_v <= dbg_v_cnt;
		c_s <= dbg_s_hb_cnt; c_x <= dbg_x_hb_cnt;
		c_st_frame <= ENABLE_ST_ACCEL ? st_frame_sync2
		                              : {rd_stall_s2, 4'd0, rd_left_s2};
		c_st_busy <= st_busy_sync2;
		c_de_width <= dbg_de_last_width;
		if (ENABLE_ST_ACCEL) begin
			c_cap_samples <= cap_samples_sync2;
			c_cap_tiles <= cap_tiles_sync2;
			c_commit_count <= commit_sync2;
			c_last_x <= last_x_sync2; c_last_y <= last_y_sync2;
			c_last_cap_addr <= last_cap_addr_sync2;
			c_last_commit_addr <= last_commit_addr_sync2;
		end else if (TELEM_VID) begin
			// vid_subsystem status (rtl/vid).  Decoded by board_smoke_test.py
			// --vid:  cap_samples  = compositor brightness sum of the last frame
			//         cap_tiles    = DDR read latency {max, last} in core clocks
			//         commit_count = {display frames read, pattern frames written}
			//         st_tiles     = compositor {bad lines, resyncs}
			//         last_x/last_y          = display misses / brightness jumps
			//         last_cap_addr          = {proto_err, writer skips[6:0]}
			//         last_commit_addr       = display late starts[7:0]
			c_cap_samples  <= vid_st_s2.cp_frame_sum;
			c_cap_tiles    <= {vid_st_s2.rd_lat_max, vid_st_s2.rd_lat_last};
			c_commit_count <= {vid_st_s2.dr_frames, vid_st_s2.pw_frames};
			c_st_frame     <= {vid_st_s2.cp_bad_lines, vid_st_s2.cp_resyncs};
			c_last_x       <= vid_st_s2.dr_miss;
			c_last_y       <= vid_st_s2.cp_jumps;
			c_last_cap_addr    <= {vid_st_s2.test_ring.proto_err, vid_st_s2.tw_skipped[6:0]};
			c_last_commit_addr <= vid_st_s2.dr_late[7:0];
		end else if (DBG_PATTERN_EN) begin
			// Pattern checker; see frame_buffer_read dbg_seq.
			c_cap_samples  <= rd_seq_s2[111:80];
			c_cap_tiles    <= {8'd0, rd_seq_s2[79:56]};
			c_commit_count <= {8'd0, rd_seq_s2[55:32]};
			c_last_x <= rd_seq_s2[31:16]; c_last_y <= rd_seq_s2[15:0];
			c_last_cap_addr <= rd_push_s2[23:16];
			c_last_commit_addr <= cp_err_sticky;
		end else begin
			// Camera mode: raw statistics (frame_buffer_read dbg_sum4/dbg_mm)
			// plus the capture probe's frame counter and line geometry.
			c_cap_samples <= rd_sum4_s2[63:32];
			c_cap_tiles <= rd_sum4_s2[31:0];
			c_commit_count <= rd_mm_s2;
			c_st_frame <= gray2bin32(cp_vs_s2);
			c_last_x <= cp_lines_s2; c_last_y <= cp_beats_s2;
			c_last_cap_addr <= rd_push_s2[23:16];
			c_last_commit_addr <= cp_err_sticky;
		end
		c_cpu_hb <= ENABLE_ST_ACCEL ? cpu_hb_sync2 : {rd_push_s2[15:8], 8'd0};
		c_frame_pix_num <= fpn_sync2;
		// R = {w_arstn(PLL全锁), cal_done(DDR校准), vid_rst_n(视频复位释放),
		//      SoC_GPIO0[0](摄像头 I2C 配置完成)}
		c_r <= {w_arstn, cal_done, vid_rst_n, w_soc_gpio_write[0]};
		c_q <= dbg_seq;
		dbg_seq <= dbg_seq + 8'd1;
		dbg_pend <= 1'b1;
	end else begin
		dbg_tick <= dbg_tick - 26'd1;
	end

	if (dbg_pend & ~dbg_sending) begin
		dbg_pend    <= 1'b0;
		dbg_sending <= 1'b1;
		dbg_cidx    <= 6'd0;
	end

	if (!dbg_sending) begin
		dbg_uart_tx <= 1'b1;
		dbg_bit     <= 4'd0;
	end else if (dbg_bit == 4'd0) begin
		// 装载下一字节：{stop, data[7:0], start}
		dbg_uart_tx <= 1'b1;
		if (dbg_cidx == MSG_LEN) begin
			dbg_sending <= 1'b0;
		end else begin
			dbg_shift <= {1'b1, dbg_msg[dbg_cidx], 1'b0};
			dbg_cidx  <= dbg_cidx + 6'd1;
			dbg_bit   <= 4'd10;
			dbg_baud  <= 16'd0;
		end
	end else begin
		dbg_uart_tx <= dbg_shift[0];
		if (dbg_baud == UART_DIV-1) begin
			dbg_baud <= 16'd0;
			dbg_shift<= {1'b1, dbg_shift[9:1]};
			dbg_bit  <= dbg_bit - 4'd1;
		end else begin
			dbg_baud <= dbg_baud + 16'd1;
		end
	end
end

assign led[2] = SOC_UART_DEBUG ? w_soc_uart_tx :
               (DBG_UART_EN ? dbg_uart_tx : 1'b0);

endmodule
