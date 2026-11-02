
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
//   CSI-2 RX -> vid_subsystem (rtl/vid: ISP -> DDR3 帧环 -> 处理 -> 合成) -> HDMI TMDS 输出。
//   引脚/外围参考参考工程（fpga_src.peri.xml 由 ti60f225_oob.peri.xml 直接沿用）。
// 与参考工程的差异：
//   - 顶层改名 fpga_src，去掉 JTAG debug core（VIO/LA）与 DSI 相关代码。
//   - 视频通路整体换成 rtl/vid（见 docs/video_architecture.md）。
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
// `include "define.v"

localparam ENABLE_ST_ACCEL = 1;


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
	input	wire	key0,
	input	wire	key2,
	input	wire	key3,
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
// Display raster: CEA-861 720p60, generated by the compositor
// (rtl/vid/disp/compositor.sv); the 1280x720 camera frame fills it.
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
wire        ui_hit = (w_soc_apb_paddr[15:0] == 16'h8000) || (w_soc_apb_paddr[15:0] == 16'h8004);
wire [31:0] ui_prdata, accel_prdata;
wire        ui_pready, accel_pready, ui_pslverr, accel_pslverr;
wire        ui_osd_en, ui_view_full, ui_single_sel, ui_cursor;
wire [1:0]  ui_style;
wire        key0_pressed, key2_pressed, key3_pressed;
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

// ─────────────────────────────────────────────────────────────────────────────
// ST accelerator: st_accel_wrapper (DDR-based tile DMA + CNN engine)
// Replaces the old on-chip-RAM-only st_accel.  Frame-rate skip logic (every
// SKIP_N ISP frames → one inference) is here rather than in the wrapper so
// the wrapper remains a pure execute-on-demand block.
//
// Tie-offs for legacy signals the old st_accel drove (APB, hw_*, dbg_*):
//   accel_prdata/pready/pslverr — stub OK, SoC firmware not yet updated.
//   w_st_irq, w_hw_*, st_dbg_* — tied off until firmware/tb catches up.
// ─────────────────────────────────────────────────────────────────────────────
// Video reset (driven by the delay counter further down).  Declared here: a
// reference inside the generate block below before any declaration makes a
// local, undriven implicit net and holds the accelerator in reset.
wire vid_rst_n;

// ST AXI master -> vid_subsystem ext_*.  Declared before the generate block
// that drives them: a use before the declaration would make implicit nets.
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

// Accelerator <-> vid_subsystem ring handshakes (PROC_EXT = 1): the
// accelerator consumes the ISP ring and produces the PROC ring.
wire                            st_src_req, st_src_ack, st_src_ok;
vid_pkg::ring_c_op_e            st_src_op;
vid_pkg::frame_token_t          st_src_token;
wire                            st_dst_req, st_dst_ack, st_dst_ok;
vid_pkg::ring_p_op_e            st_dst_op;
wire [vid_pkg::SEQ_W-1:0]       st_dst_src_seq;
wire [vid_pkg::RING_SLOT_W-1:0] st_dst_slot;
wire [vid_pkg::SEQ_W-1:0]       st_pr_frames, st_pr_miss, st_pr_errors, st_pr_skipped;

generate
if (ENABLE_ST_ACCEL) begin : gen_st_accel

    // ── Legacy signal tie-offs (old APB / hw_pe / dbg not wired to new wrapper) ─
    assign accel_prdata          = 32'd0;
    assign accel_pready          = w_soc_apb_psel & ~ui_hit;
    assign accel_pslverr         = 1'b0;
    assign w_st_irq              = 1'b0;
    // Old PE control inputs (driven to no-op)
    assign w_hw_x_we             = 1'b0;
    assign w_hw_load_w           = 1'b0;
    assign w_hw_start            = 1'b0;
    // Old PE status outputs (tie off to keep lint clean)
    assign w_hw_busy             = 1'b0;
    assign w_hw_done             = 1'b0;
    assign w_hw_y_addr           = '0;
    assign w_hw_y_data           = '0;
    // Old debug outputs
    assign st_dbg_cap_samples    = '0;
    assign st_dbg_cap_tiles      = '0;
    assign st_dbg_commit_count   = '0;
    assign st_dbg_last_x         = '0;
    assign st_dbg_last_y         = '0;
    assign st_dbg_last_cap_addr  = '0;
    assign st_dbg_last_commit_addr = '0;
    assign st_cpu_dbg_heartbeat  = '0;

    // ── st_accel_wrapper: takes each new ISP frame, writes the PROC ring ────
    wire accel_busy;
    st_accel_wrapper u_st_accel_wrapper (
        .clk            (core_clk),
        .rst_n          (vid_rst_n),
        // AXI4 master → vid_subsystem ext_* (write channel)
        .m_axi_awid     (st_awid),    .m_axi_awaddr (st_awaddr),
        .m_axi_awlen    (st_awlen),   .m_axi_awvalid(st_awvalid),
        .m_axi_awready  (st_awready),
        .m_axi_wdata    (st_wdata),   .m_axi_wlast  (st_wlast),
        .m_axi_wvalid   (st_wvalid),  .m_axi_wready (st_wready),
        .m_axi_bid      (st_bid),     .m_axi_bresp  (st_bresp),
        .m_axi_bvalid   (st_bvalid),  .m_axi_bready (st_bready),
        // AXI4 master → vid_subsystem ext_* (read channel)
        .m_axi_arid     (st_arid),    .m_axi_araddr (st_araddr),
        .m_axi_arlen    (st_arlen),   .m_axi_arvalid(st_arvalid),
        .m_axi_arready  (st_arready),
        .m_axi_rid      (st_rid),     .m_axi_rdata  (st_rdata),
        .m_axi_rresp    (st_rresp),   .m_axi_rlast  (st_rlast),
        .m_axi_rvalid   (st_rvalid),  .m_axi_rready (st_rready),
        // Rings
        .src_req (st_src_req), .src_op (st_src_op), .src_ack (st_src_ack),
        .src_ok  (st_src_ok),  .src_token (st_src_token),
        .dst_req (st_dst_req), .dst_op (st_dst_op), .dst_src_seq (st_dst_src_seq),
        .dst_ack (st_dst_ack), .dst_ok (st_dst_ok), .dst_slot (st_dst_slot),
        // Status
        .busy       (accel_busy),
        .st_frames  (st_pr_frames),
        .st_miss    (st_pr_miss),
        .st_errors  (st_pr_errors),
        .st_skipped (st_pr_skipped)
    );

    assign w_st_frame_cnt = 32'(st_pr_frames);
    assign w_st_pipe_busy = accel_busy;

end else begin : gen_st_accel_off
    assign st_src_req     = 1'b0;
    assign st_src_op      = vid_pkg::RING_C_ACQ;
    assign st_dst_req     = 1'b0;
    assign st_dst_op      = vid_pkg::RING_P_ACQ;
    assign st_dst_src_seq = '0;
    assign st_pr_frames   = '0;
    assign st_pr_miss     = '0;
    assign st_pr_errors   = '0;
    assign st_pr_skipped  = '0;
    assign accel_prdata  = 32'd0;
    assign accel_pready  = w_soc_apb_psel & ~ui_hit;
    assign accel_pslverr = 1'b0;
    assign w_st_irq      = 1'b0;
    assign w_hw_x_we     = 1'b0;
    assign w_hw_load_w   = 1'b0;
    assign w_hw_start    = 1'b0;
    assign w_hw_busy     = 1'b0;
    assign w_hw_done     = 1'b0;
    assign w_hw_y_addr   = '0;
    assign w_hw_y_data   = '0;
    assign st_dbg_cap_samples      = '0;
    assign st_dbg_cap_tiles        = '0;
    assign st_dbg_commit_count     = '0;
    assign st_dbg_last_x           = '0;
    assign st_dbg_last_y           = '0;
    assign st_dbg_last_cap_addr    = '0;
    assign st_dbg_last_commit_addr = '0;
    assign st_cpu_dbg_heartbeat    = '0;
    assign w_st_frame_cnt = '0;
    assign w_st_pipe_busy = 1'b0;
    assign st_awvalid     = 1'b0;
    assign st_wvalid      = 1'b0;
    assign st_bready      = 1'b0;
    assign st_arvalid     = 1'b0;
    assign st_rready      = 1'b0;
end
endgenerate

ui_regs u_ui_regs (
	.clk        (core_clk),
	.rst_n      (~w_soc_async_reset),
	.paddr      (w_soc_apb_paddr),
	.psel       (w_soc_apb_psel & ui_hit),
	.penable    (w_soc_apb_penable),
	.pwrite     (w_soc_apb_pwrite),
	.pwdata     (w_soc_apb_pwdata),
	.prdata     (ui_prdata),
	.pready     (ui_pready),
	.pslverr    (ui_pslverr),
	.osd_en     (ui_osd_en),
	.view_full  (ui_view_full),
	.single_sel (ui_single_sel),
	.cursor     (ui_cursor),
	.style      (ui_style)
);
assign w_soc_apb_prdata    = ui_hit ? ui_prdata  : accel_prdata;
assign w_soc_apb_pready    = ui_hit ? ui_pready  : accel_pready;
assign w_soc_apb_pslverror = ui_hit ? ui_pslverr : accel_pslverr;

key_debounce u_key0 (.clk(core_clk), .rst_n(~w_soc_async_reset), .pin(key0), .pressed(key0_pressed));
key_debounce u_key2 (.clk(core_clk), .rst_n(~w_soc_async_reset), .pin(key2), .pressed(key2_pressed));
key_debounce u_key3 (.clk(core_clk), .rst_n(~w_soc_async_reset), .pin(key3), .pressed(key3_pressed));
// Hold KEY2 and the style row highlights immediately; hold KEY0 and the
// view row does.  Firmware still latches the choice into ui_cursor.
wire ui_cursor_live = key2_pressed | (ui_cursor & ~key0_pressed);

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
	.system_gpio_0_io_read        ({key3_pressed, key2_pressed, key0_pressed, 1'b0})
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
// ST accelerator AXI master -> vid_subsystem external port
//=====================================================================================

//=====================================================================================
// Video subsystem (rtl/vid): camera -> ISP -> DDR frame ring -> processing ->
// compositor -> HDMI, and the only master on the DDR port.  The ST
// accelerator's AXI master is its external port (master 0, highest priority),
// enabled with the accelerator.  See docs/video_architecture.md.
//=====================================================================================
vid_pkg::vid_status_t w_vid_status;
wire [7:0] vid_pix_r, vid_pix_g, vid_pix_b;
wire       vid_pix_de, vid_pix_hs, vid_pix_vs;

// CSI_PATTERN = 1: csi_capture replaces the camera's pixels with a fixed
// picture (sensor timing kept).  The ISP ring's frame signature (telemetry
// page 1) must then read 0xa4f003e6 (sim/ref/isp_ref.py pattern-sig).
localparam CSI_PATTERN = 1'b0;
// The processing placeholder (VID_PROC_MODE) writes the PROC ring; the
// compositor shows the camera left of the split column and the processed
// frame from it on.  VID_SPLIT = 0 shows the camera alone.
localparam VID_SPLIT = 1'b1;
localparam [11:0] VID_SPLIT_COL = 12'd640;
// What the right half shows: PROC_SOBEL (edges), PROC_INVERT, PROC_PASS.
localparam vid_pkg::proc_mode_e VID_PROC_MODE = vid_pkg::PROC_SOBEL;
localparam vid_pkg::comp_cfg_t VID_COMP = '{
    mode:       VID_SPLIT ? vid_pkg::COMP_SPLIT : vid_pkg::COMP_SINGLE,
    single_sel: 1'b0,
    split_col:  VID_SPLIT_COL};

vid_subsystem #(
    .ENABLE_SELFTEST (1),
    .DISP_SRC        (1),            // camera through the ISP
    .CSI_PATTERN     (CSI_PATTERN),
    .PROC_EN         (VID_SPLIT),
    .PROC_MODE       (VID_PROC_MODE),
    .COMP_CFG        (VID_COMP),
    .PROC_EXT        (ENABLE_ST_ACCEL),   // the accelerator is the PROC engine
    .EXT_EN          (ENABLE_ST_ACCEL)
) u_vid (
    .clk         (core_clk),
    .rst_n       (vid_rst_n),

    .ext_awid     (st_awid),    .ext_awaddr (st_awaddr), .ext_awlen  (st_awlen),
    .ext_awvalid  (st_awvalid), .ext_awready(st_awready),
    .ext_wdata    (st_wdata),   .ext_wlast  (st_wlast),  .ext_wvalid (st_wvalid), .ext_wready (st_wready),
    .ext_bid      (st_bid),     .ext_bresp  (st_bresp),  .ext_bvalid (st_bvalid), .ext_bready (st_bready),
    .ext_arid     (st_arid),    .ext_araddr (st_araddr), .ext_arlen  (st_arlen),
    .ext_arvalid  (st_arvalid), .ext_arready(st_arready),
    .ext_rid      (st_rid),     .ext_rdata  (st_rdata),  .ext_rresp  (st_rresp),
    .ext_rlast    (st_rlast),   .ext_rvalid (st_rvalid), .ext_rready (st_rready),
    .ext_src_req  (st_src_req), .ext_src_op (st_src_op), .ext_src_ack (st_src_ack),
    .ext_src_ok   (st_src_ok),  .ext_src_token (st_src_token),
    .ext_dst_req  (st_dst_req), .ext_dst_op (st_dst_op), .ext_dst_src_seq (st_dst_src_seq),
    .ext_dst_ack  (st_dst_ack), .ext_dst_ok (st_dst_ok), .ext_dst_slot (st_dst_slot),
    .ext_pr_frames (st_pr_frames), .ext_pr_miss (st_pr_miss),
    .ext_pr_errors (st_pr_errors), .ext_pr_skipped (st_pr_skipped),

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

    .csi_clk     (i_mipi_rx_pclk),
    .csi_vs      (w_mipi_rx_vs),
    .csi_hs      (w_mipi_rx_hs),
    .csi_de      (w_mipi_rx_de),
    .csi_data    (w_mipi_rx_data[39:0]),

    .pix_clk     (hdmi_tx_slow_clk),
    .pix_r       (vid_pix_r),  .pix_g (vid_pix_g),  .pix_b (vid_pix_b),
    .pix_de      (vid_pix_de), .pix_hs(vid_pix_hs), .pix_vs(vid_pix_vs),

    .status        (w_vid_status),
    .ui_osd_en     (ui_osd_en),
    .ui_view_full  (ui_view_full),
    .ui_single_sel (ui_single_sel),
    .ui_cursor     (ui_cursor_live),
    .ui_style      (ui_style),
    .ui_live       (1'b1)
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




//=================================================================================
//hdmi tx ctrl 
//=================================================================================
assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

wire [9:0] tmds_data0;
wire [9:0] tmds_data1;
wire [9:0] tmds_data2;
wire [9:0] tmds_clk ;
//==============================================================================
// HDMI 自测图样 (TP_EN)
//
// 目的: 把"摄像头/DDR/debayer/后处理这条视频通路"和"TMDS 物理发送"分开。
//   TP_EN=1 时, dvi_encoder 的输入完全由本地计数器产生标准 720p60 时序 +
//   8 条竖彩条, 与摄像头、DDR、frame_buffer 全部无关。
//   接采集卡:
//     - 采集卡锁定并出图   -> TMDS 发送没问题, 问题在视频通路(时序/数据)
//     - 采集卡仍显示自身彩条 -> 问题在 TMDS 发送侧(电气/编码/时钟)
//==============================================================================
localparam TP_EN = 1'b0;

reg [11:0] tp_hcnt = 12'd0;
reg [11:0] tp_vcnt = 12'd0;

// CEA-861 720p60 (format 4), active-first unlike raster_gen:
// H 1280/110/40/220 (总 1650), V 720/5/5/20 (总 750)
wire tp_hs = TP_EN & (tp_hcnt >= 12'd1390) & (tp_hcnt < 12'd1430);
wire tp_vs = TP_EN & (tp_vcnt >= 12'd725) & (tp_vcnt < 12'd730);
wire tp_de = TP_EN & (tp_hcnt < 12'd1280) & (tp_vcnt < 12'd720);

always @(posedge hdmi_tx_slow_clk or negedge vid_rst_n) begin
  if (!vid_rst_n) begin
    tp_hcnt <= 12'd0;
    tp_vcnt <= 12'd0;
  end else if (tp_hcnt == 12'd1649) begin
    tp_hcnt <= 12'd0;
    tp_vcnt <= (tp_vcnt == 12'd749) ? 12'd0 : tp_vcnt + 12'd1;
  end else begin
    tp_hcnt <= tp_hcnt + 12'd1;
  end
end

// 8 条竖彩条: 白 黄 青 绿 品红 红 蓝 黑, 每条 160 像素
reg [7:0] tp_r, tp_g, tp_b;
always @(*) begin
  case (tp_hcnt / 12'd160)
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

// The encoder shows the vid_subsystem compositor, or the local test pattern.
wire [7:0] enc_r = TP_EN ? tp_r   : vid_pix_r;
wire [7:0] enc_g = TP_EN ? tp_g   : vid_pix_g;
wire [7:0] enc_b = TP_EN ? tp_b   : vid_pix_b;
wire       enc_de = TP_EN ? tp_de  : vid_pix_de;
wire       enc_hs = TP_EN ? tp_hs  : vid_pix_hs;
wire       enc_vs = TP_EN ? tp_vs  : vid_pix_vs;

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
  .video_VIC        (4),
	.audio_L			    (16'd0),
  .audio_R			    (16'd0),
  .audio_valid		  (1'b0),
  .audio_N                (6144),     //(20'h01880),//     
  .audio_CTS              (74250),       //(20'h1221A),//      
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
//   N14=GPIOR_21=KEY2   P14=GPIOR_22=KEY1/i_arstn   P15=GPIOR_25=LED3
//   P13=GPIOR_27=LED0   N13=GPIOR_24=LED1
//   R14=GPIOR_28=UART_RX_3V3   R13=GPIOR_29=CLK_50M
//   C4=GPIOL_07=KEY0   A3=GPIOL_03=KEY3
// 即 peri 里叫 "led[2]" 的 GPIOR_28 实际经 R243 接到 FT4232 通道 C 的 RXD，
// 不是 LED。原代码 `assign led[3:2] = 2'b00;` 等于把 FTDI RXD 拉死在低电平。
//
// 现用它把 HDMI 关键内部状态发回 PC：115200 8N1，每 0.5s 一帧 48 字节
//   AA 55 | D[4] H[4] V[4] | SH[2] XH[2] | R | SEQ | ST_TILES[4] | ST_BUSY | DE_WIDTH[2] | RSV
//   D/H/V  enc_de/enc_hs/enc_vs 上升沿计数（core_clk 域，已 2-FF 同步）
//          720p60 标称值：D=43200/s  H=45000/s  V=60/s
//   SH     hdmi_tx_slow_clk(74.25MHz) 心跳计数，标称约 283 次/0.5s
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
// enc_* 是视频域电平信号，高/低电平分别维持 538ns~17.2µs，远大于 10ns 采样周期，
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
// 预期每 0.5s：hdmi_tx_slow_clk(74.25MHz) 约 283 次，vid_clk_dvi2(74.25MHz) 约 283 次。
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
// CSI-2 RX error flags, sticky since reset: {receive, frame_vc0, line_vc0,
// undersize, ecc2, ecc1, crc, pixel_fifo_full}.
reg [7:0]  cp_err_s1 = 8'd0, cp_err_s2 = 8'd0, cp_err_sticky = 8'd0;
always @(posedge core_clk) begin
	cp_err_s1 <= {mdebug_receive_error, mdebug_frame_vc0_error,
	              mdebug_line_vc0_error, mdebug_undersize_pkt_error,
	              mdebug_ecc_2bit_error, mdebug_ecc_1bit_error,
	              mdebug_crc_error, mdebug_pixel_fifo_full};
	cp_err_s2 <= cp_err_s1;
	cp_err_sticky <= cp_err_sticky | cp_err_s2;
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
	dbg_msg[47] = {5'd0, key3_pressed, key2_pressed, key0_pressed};
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
		c_st_frame <= st_frame_sync2;
		c_st_busy <= st_busy_sync2;
		c_de_width <= dbg_de_last_width;
		begin
			// vid_subsystem status (rtl/vid), one page per frame, page =
			// seq[1:0] (byte 19).  Decoded by board_smoke_test.py --vid.
			// With ENABLE_ST_ACCEL the accelerator is the processing engine:
			// page 3 pr_* are its frames/errors/skips.
			case (dbg_seq[1:0])
			2'd0: begin   // display
				c_cap_samples  <= vid_st_s2.cp_frame_sum;
				c_cap_tiles    <= {vid_st_s2.rd_lat_max, vid_st_s2.rd_lat_last};
				c_commit_count <= {vid_st_s2.dr_frames, vid_st_s2.pw_frames};
				c_st_frame     <= {vid_st_s2.cp_bad_lines, vid_st_s2.cp_resyncs};
				c_last_x       <= vid_st_s2.dr_miss;
				c_last_y       <= vid_st_s2.cp_jumps;
				c_last_cap_addr    <= {vid_st_s2.isp_ring_err, vid_st_s2.pw_skipped[6:0]};
				c_last_commit_addr <= vid_st_s2.dr_late[7:0];
			end
			2'd1: begin   // camera path
				c_cap_samples  <= {vid_st_s2.cap_frames, vid_st_s2.cap_lines};
				c_cap_tiles    <= {vid_st_s2.cap_beats, vid_st_s2.cap_dropped};
				c_commit_count <= {vid_st_s2.pw_errors, vid_st_s2.isp_dropped};
				c_st_frame     <= vid_st_s2.pw_sig;
				c_last_x       <= vid_st_s2.wr_lat_max;
				c_last_y       <= vid_st_s2.pw_frames;
				c_last_cap_addr    <= vid_st_s2.rel_holes[7:0];
				c_last_commit_addr <= {vid_st_s2.isp_ring_err, 7'd0};
			end
			2'd2: begin   // raw statistics of the last frame
				c_cap_samples  <= vid_st_s2.raw_sum[0];
				c_cap_tiles    <= vid_st_s2.raw_sum[1];
				c_commit_count <= vid_st_s2.raw_sum[2];
				c_st_frame     <= vid_st_s2.raw_sum[3];
				c_last_x       <= vid_st_s2.raw_clip[19:4];
				c_last_y       <= vid_st_s2.raw_dark[19:4];
				c_last_cap_addr    <= 8'd0;
				c_last_commit_addr <= cp_err_sticky;
			end
			default: begin   // DMA self-test, processing, layer 1
				c_cap_samples  <= {vid_st_s2.tc_frames, vid_st_s2.tc_bad_frames};
				c_cap_tiles    <= vid_st_s2.tc_bad_words;
				c_commit_count <= {vid_st_s2.tw_frames, vid_st_s2.tw_errors};
				c_st_frame     <= {vid_st_s2.dr1_frames, vid_st_s2.cp1_bad_lines};
				c_last_x       <= vid_st_s2.pr_frames;
				c_last_y       <= vid_st_s2.seq_gap;
				c_last_cap_addr    <= vid_st_s2.pr_errors[7:0];
				c_last_commit_addr <= {vid_st_s2.test_ring.proto_err, vid_st_s2.proc_ring_err,
				                       vid_st_s2.pr_skipped[5:0]};
			end
			endcase
		end
		c_cpu_hb <= ENABLE_ST_ACCEL ? cpu_hb_sync2 : 16'd0;
		c_frame_pix_num <= 24'd0;     // retired with the old frame store
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
