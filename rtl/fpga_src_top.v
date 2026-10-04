
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

localparam MAX_VRES = 1080;
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
//   - APB0 : 预留给后面挂自定义寄存器（按键消抖等）
//==============================================================================
wire w_soc_async_reset;      // 高有效异步复位
wire w_soc_system_reset;     // SoC 输出的系统复位（高有效），给用户逻辑用

assign w_soc_async_reset = ~w_arstn;

wire w_soc_i2c_scl_write;
wire w_soc_i2c_sda_write;
wire [3:0] w_soc_gpio_write;
wire [3:0] w_soc_gpio_write_en;
wire [31:0] w_soc_apb_paddr, w_soc_apb_pwdata, w_soc_apb_prdata;
wire        w_soc_apb_psel, w_soc_apb_penable, w_soc_apb_pwrite;
wire        w_soc_apb_pready = 1'b1;
wire        w_soc_apb_pslverror = 1'b0;

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

	.userInterruptA               (1'b0                ),

	// APB3 从机（预留）
	.io_apbSlave_0_PADDR          (w_soc_apb_paddr     ),
	.io_apbSlave_0_PSEL           (w_soc_apb_psel      ),
	.io_apbSlave_0_PENABLE        (w_soc_apb_penable   ),
	.io_apbSlave_0_PWRITE         (w_soc_apb_pwrite    ),
	.io_apbSlave_0_PWDATA         (w_soc_apb_pwdata    ),
	.io_apbSlave_0_PRDATA         (w_soc_apb_prdata    ),
	.io_apbSlave_0_PREADY         (w_soc_apb_pready    ),
	.io_apbSlave_0_PSLVERROR      (w_soc_apb_pslverror ),

	// UART 本工程未引出（板上没有空闲串口脚），rxd 固定为高（空闲）
	.system_uart_0_io_txd         (                    ),
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

// SoC GPIO0[0] -> led[1]：固件把摄像头寄存器表写完后点亮，用来区分
// "I2C 没跑起来" 和 "视频通路有问题"。led[0] 仍是参考工程的 DDR 校准心跳。
assign led[1]   = w_soc_gpio_write_en[0] ? w_soc_gpio_write[0] : 1'b0;
assign led[3:2] = 2'b00;

assign io_cam_scl_OUT = 1'b0;
assign io_cam_scl_OE  = ~w_soc_i2c_scl_write;
assign io_cam_sda_OUT = 1'b0;
assign io_cam_sda_OE  = ~w_soc_i2c_sda_write;

assign o_cam_rst_p = ~w_arstn;

//=====================================================================================
//frame buffer
//=====================================================================================
wire [7:0] 	ch0_r;
wire [7:0]    ch0_g;
wire [7:0]    ch0_b;
wire ch0_vs;
wire ch0_hs;
wire ch0_de;
// IMX219
  frame_buffer #(
.I_VID_WIDTH         (32),
.O_VID_WIDTH         (16),
.START_ADDR          (32'h00000        ),
.AXI_DATA_WIDTH      ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH      ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	      ( 1024		),    
.RD_FIFO_DEPTH 	      ( 1024 	),
.BURST_LEN  	       (127),
.FB_NUM	            (3),
.MAX_VID_WIDTH	    (960) ,
.MAX_VID_HIGHT	    (1080) 


)checker0(
       .axi_clk		(core_clk 	        ),
       .rst_n			(vid_rst_n   ),

/*i*/.i_clk			(i_mipi_rx_pclk      ),
/*i*/.i_vs			(w_mipi_rx_vs	),
/*i*/.i_de			(w_mipi_rx_de & w_mipi_rx_hs	),
/*i*/.vin 			({w_mipi_rx_data[39:32],w_mipi_rx_data[29:22],w_mipi_rx_data[19:12],w_mipi_rx_data[9:2]}	),
                     
/*i*/.o_clk			(vid_clk_dvi2),//(i_mipi_rx_pclk	),
/*i*/.o_hs    		(ch0_hs		),			
/*i*/.o_vs    		(ch0_vs		),			
/*i*/.o_de    		(ch0_de		),			
/*i*/.vout    		({ch0_g,ch0_b}	),//ch0_r,

/*i*/.H_FRONT_PORCH (HFP/2  		),//
/*i*/.H_SYNC 	 	    (HSP/2	 	),///2
/*i*/.H_VALID 	 	  (MAX_HRES/2     ),//		
/*i*/.H_BACK_PORCH	(HBP/2		),//		
/*i*/.V_FRONT_PORCH (VFP  		),//		
/*i*/.V_SYNC 	 	    (VSP 	 	),//		
/*i*/.V_VALID 	 	  (MAX_VRES     ),//		
/*i*/.V_BACK_PORCH	(VBP		),//		

       .awid			(s_axi_awid	),      
       .awaddr		(s_axi_awaddr	),
       .awlen			(s_axi_awlen	),
       .awsize		(s_axi_awsize	),
       .awburst		(s_axi_awburst),
       .awprot    (s_axi_awprot ),
       .awcache   (s_axi_awcache),
       .awlock		(s_axi_awlock	),
       .awvalid		(s_axi_awvalid),
       .awready		(s_axi_awready),

       .arid			(s_axi_arid	  ),
       .araddr		(s_axi_araddr	),
       .arlen			(s_axi_arlen	),
       .arsize		(s_axi_arsize	),
       .arburst 	(s_axi_arburst),

       .arprot    (s_axi_arprot ),
       .arcache   (s_axi_arcache),
       .arlock 		(s_axi_arlock	),
       .arvalid		(s_axi_arvalid),
       .arready		(s_axi_arready),

       .wdata			(s_axi_wdata	),
       .wstrb			(s_axi_wstrb	),
       .wlast			(s_axi_wlast	),
       .wvalid		(s_axi_wvalid	),
       .wready		(s_axi_wready	),


       .rid			  (s_axi_rid	),
       .rdata			(s_axi_rdata	),
       .rlast			(s_axi_rlast	),
       .rvalid 		(s_axi_rvalid	),
       .rready		(s_axi_rready	),
       .rresp			(s_axi_rresp	),

       .bid			  (s_axi_bid	),
       .bvalid		(s_axi_bvalid	),
       .bready	  (s_axi_bready	)
);


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
localparam WB_G = 16'd213;	// 绿光通道 (0.832x) —— 扫描模式测出来的最优值
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

debayer_top_2to1 debayer_top
(
	.in_pclk		  (vid_clk_dvi2),//(i_mipi_rx_pclk ),
	.in_rstn		  (vid_rst_n	),
	
	.raw_vs_i		  (ch0_vs		      ),
	.raw_hs_i		  (ch0_hs		      ),
	.raw_de_i		  (ch0_de		      ),
	.raw_valid_i	(ch0_de	        ),
	.raw_datax4_i	({ch0_b,ch0_g}	),
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

dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~vid_rst_n      ),// reset
	.i_bdata      		(sat_bdata 	),//(hdmi_tx_rdata ),//(video_b            ),//(bdata_in	),   //
	.i_gdata     		  (sat_gdata   ),//(hdmi_tx_gdata ),//(video_g            ),//(gdata_in	),   //   
	.i_rdata       		(sat_rdata 	),//(hdmi_tx_bdata ),//(video_r            ),//(rdata_in	),   //   
  .i_de            	(sat_de      ),//(hdmi_tx_de    ),//(video_de           ),//(rx_de		  ),   //
	.i_hs         		(sat_hs    ),//(video_hs           ),//(rx_hsync	),   //   
	.i_vs         		(sat_vs    ),//(video_vs           ),//(rx_vsync	),   //  
	
  .video_format     (video_format), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
  .video_VIC        (0),
	.audio_L			    (audio_L),
  .audio_R			    (audio_R),
  .audio_valid		  (audio_valid),
  .audio_N                (6144),     //(20'h01880),//     
  .audio_CTS              (148500),      //(20'h28488),//      
  .audio_sample_frequency (audio_samp_freq),    //(3'b000),// 
  .audio_word_length      ({audio_samp_word_len,audio_max_word_length}),//(4'b1011),//

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

endmodule
