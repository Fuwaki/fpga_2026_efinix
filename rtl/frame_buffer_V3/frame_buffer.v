//2026.8.17：V3: 
//（1）使用了通用串并转换模块，理论上可以支持任意位宽的串并，并串转换。

`timescale 1ps/1ps
module frame_buffer #(
parameter I_VID_WIDTH = 16,
parameter O_VID_WIDTH = 16,
parameter AXI_DATA_WIDTH	= 512,
parameter AXI_ADDR_WIDTH 	= 33,
parameter	WR_FIFO_DEPTH		= 1024,    
parameter	RD_FIFO_DEPTH 	= 1024,
parameter START_ADDR			=	33'h000201900,
parameter BURST_LEN       = 8'd15,
parameter FB_NUM			    = 	3,//2 buffer ,3 buffer 
// Kept for the write-side burst sizing; the read side no longer derives its
// geometry from these (see CAM_VID_*).
parameter MAX_VID_WIDTH		=	1920 ,//video width (in I_VID_WIDTH words)
parameter MAX_VID_HIGHT		=	1080 ,//wideo height

// Geometry the sensor actually delivers, in pixels and lines.  The display
// raster is independent (1080p); this rectangle is centred inside it.
parameter CAM_VID_WIDTH   = 1280,
parameter CAM_VID_HEIGHT  = 720,
// 1 = display timing free-runs from reset and never waits for a captured
// frame.  The panel keeps its lock even when DDR holds nothing yet, which is
// what makes display independent of the capture rate.  0 = legacy behaviour
// (no sync at all until frame_stable asserts).
parameter RD_FREE_RUN        = 0,
parameter AXI_STRB_WIDTH 	= AXI_DATA_WIDTH/8
) (

input 												axi_clk,
input 												rst_n,

input	wire								i_clk	,
input	wire								i_vs, //active hgih
input	wire								i_de, //active high
input	wire	[I_VID_WIDTH-1:0] 			vin ,

input	wire								  o_clk	,
output	wire								o_hs , //active high
output	wire								o_vs , //active hgih
output	wire								o_de , //active high
output	wire	[O_VID_WIDTH-1:0] 			vout ,

// Words captured per frame, measured on the write side.  Exposed so the board
// can tell a complete frame from a truncated one: a 1280x720 sensor must
// report 320 four-pixel beats per line.  Half that means two of the four MIPI
// lanes are missing.
output	wire	[23:0]						frame_pix_num,
// Read-side per-frame diagnostics, o_clk domain (see frame_buffer_read).
output	wire	[15:0]						rd_dbg_stall,
output	wire	[11:0]						rd_dbg_left,
output	wire	[23:0]						rd_dbg_push,
output	wire	[111:0]						rd_dbg_seq,

input	wire 	[12:0]									H_FRONT_PORCH 	,
input	wire 	[12:0]									H_SYNC 			,
input	wire 	[12:0]									H_VALID 		,
input	wire 	[12:0]									H_BACK_PORCH 	,
input	wire 	[12:0]									V_FRONT_PORCH 	,
input	wire 	[12:0]									V_SYNC 			,
input	wire 	[12:0]									V_VALID 		,
input	wire 	[12:0]									V_BACK_PORCH 	,


output 	[5:0] 								awid,
output  [AXI_ADDR_WIDTH-1:0] 	awaddr,
output  [7:0] 								awlen,
output  [2:0] 								awsize,
output  [1:0] 								awburst,
output  [3:0] 								awcache,
output [2:0]                    awprot,
output  									    awlock,
output  									    awvalid,
output  									    awcobuf,
output  									    awapcmd,
output  									    awallstrb,
output  									    awqos,
input 										    awready,

output [5:0] 									arid,
output  [AXI_ADDR_WIDTH-1:0] 	                araddr,
output  [7:0] 								    arlen,
output  [2:0] 								    arsize,
output  [1:0] 								    arburst,
output  									    arlock,
output  									    arvalid,
output  									    arapcmd,
output 										    arqos,
input 										    arready,
output  [3:0] 									arcache,
output [2:0]                    arprot,

output  [AXI_DATA_WIDTH-1:0] 	wdata,  
output  [AXI_STRB_WIDTH-1:0] 	wstrb,
output  											wlast,
output  											wvalid,
input 												wready,

input [5:0] 									    rid,
input [AXI_DATA_WIDTH-1:0] 		rdata,
input 												rlast,
input 												rvalid,
output  											rready,
input [1:0] 									    rresp,

input [5:0] 									    bid,
input 												bvalid,
output  											bready,
output			[31:0]								test_rd_fifo_rddata,   
output	[31:0]								        test_wdata,
output	[31:0]								        test_rdata,
output [7:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;
//=============================================================
//parameter define                                                  
//============================================================= 
wire [31:0]               ddr_frame_len ;
wire [AXI_DATA_WIDTH-1:0] wr_fifo_wrdata;

wire                      rd_fifo_rdvalid	;
wire [AXI_DATA_WIDTH-1:0] rd_fifo_rddata	 ; 
wire                      rd_fifo_rdempty	;
wire                      rd_fifo_rden     ;

wire                      fifo_rd_period;

reg [12:0] h_front_porch  = 13'd100; 
reg [12:0] h_sync 	 		= 13'd100; 
reg [12:0] h_valid 	 	 	= 13'd100; 
reg [12:0] h_back_porch = 13'd100; 
reg [12:0] v_front_porch  = 13'd100; 
reg [12:0] v_sync 	 		= 13'd100; 
reg [12:0] v_valid 	 	  = 13'd100; 
reg [12:0] v_back_porch = 13'd100; 

wire		wr_sw_ack ;
wire		wr_sw 		;
wire		rd_sw			;
wire		rd_sw_ack ;

//=============================================================  
//RTL                                                     
//=============================================================  
wire wr_clk_rst_n;
wire axi_clk_rst_n;
wire rd_clk_rst_n;
rst_n_piple #(                       
	.DLY ( 3 )                        
)	u_i_clk_rst_pip(                                          
/*i*/.clk			(i_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (wr_clk_rst_n)            
);

  rst_n_piple #(                       
	.DLY ( 3 )                        
)	u_axi_rst_pip(                                          
/*i*/.clk			(axi_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (axi_clk_rst_n)            
);

  rst_n_piple #(                       
	.DLY ( 3 )                        
)	u_o_clk_rst_pip(                                          
/*i*/.clk			(o_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (rd_clk_rst_n)            
);


wire                      wr_fifo_wren;
wire                      frame_start;
wire                      frame_stable;



vid_rx_align_v1 #(
	.I_VID_WIDTH   (I_VID_WIDTH		),
	.AXI_DDR_WIDTH (AXI_DATA_WIDTH )
)u_vid_rx_align(
/*i*/.clk			    (i_clk			),  
/*i*/.rst_n			  (wr_clk_rst_n	),
/*i*/.i_vs			  (i_vs			), //active hgih
/*i*/.i_de			  (i_de			), //active high
/*i*/.vin			    (vin			),
/*o*/.fifo_wr_en	  (wr_fifo_wren		),
/*o*/.fifo_wr_data	(wr_fifo_wrdata	),
/*o*/.frame_start	  (frame_start	),
/*O*/.fifo_rst_p		  (fifo_rst		  ),
/*O*/.frame_stable  (frame_stable ),
/*O*/.frame_pix_num (frame_pix_num),
/*O*/.ddr_frame_len (ddr_frame_len)
);


reg fifo_rd_period_r0 = 'd0;
reg fifo_rd_period_r1 = 'd0;
reg fifo_rd_period_r2 = 'd0;
always @( posedge axi_clk)
begin
  fifo_rd_period_r0 <= fifo_rd_period;
  fifo_rd_period_r1 <= fifo_rd_period_r0;
  fifo_rd_period_r2 <= fifo_rd_period_r1; 
end
wire neg_rd_period = {fifo_rd_period_r2,fifo_rd_period_r1} == 2'b10;
ddr_buffer #(
.AXI_DATA_WIDTH ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	( WR_FIFO_DEPTH		),    
.RD_FIFO_DEPTH 	( RD_FIFO_DEPTH 	),
.START_ADDR			( START_ADDR      ),
.I_VID_WIDTH    ( I_VID_WIDTH     ),
.BURST_LEN      (BURST_LEN        )
)u_ddr_buffer(
    .axi_clk		    (axi_clk	),
    .wr_clk_rst_n (wr_clk_rst_n),
    .axi_clk_rst_n(axi_clk_rst_n),
    .rd_clk_rst_n (rd_clk_rst_n),
    
/*i*/.rd_start	      (fifo_rd_period),
/*i*/.wr_start	      (frame_start & frame_stable),
    .wr_busrt_len     (ddr_frame_len ),//ddr address scope for one frame
    .rd_burst_len     (ddr_frame_len ),//ddr address scope for one frame

	   .test_cnt				(test_cnt),
/*i*/.wr_fifo_wrclk		(i_clk					),
/*i*/.wr_fifo_rst_p   ( fifo_rst        ),
/*i*/.wr_fifo_wren		(wr_fifo_wren		  ),
/*o*/.wr_fifo_wrfull	(wr_fifo_wrfull	  ),
/*i*/.wr_fifo_wrdata	(wr_fifo_wrdata	  ), 

/*i*/.rd_fifo_rdclk		(o_clk					  ),
/*i*/.rd_fifo_rst_p   (neg_rd_period    ),
/*o*/.rd_fifo_rdvalid	(rd_fifo_rdvalid	),
/*o*/.rd_fifo_rddata	(rd_fifo_rddata	  ),
/*o*/.rd_fifo_rdempty	(rd_fifo_rdempty	),
/*i*/.rd_fifo_rden		(rd_fifo_rden     ),

/*o*/.test_wdata(test_wdata ),
/*o*/.test_rdata(test_rdata ),    
    .awid			  ( awid			),
    .awaddr			( awaddr		),
    .awlen			( awlen			),
    .awsize			( awsize		),
    .awburst		( awburst		),
    .awvalid		( awvalid		),
    .awready		( awready		),
    .awqos			( awqos			),
    .awcache    ( awcache   ),
    .awprot     ( awprot    ),

    .arid			  ( arid			),
    .araddr			( araddr		),
    .arlen			( arlen			),
    .arsize			( arsize		),
    .arburst		( arburst		),
    .arlock			( arlock		),
    .arvalid		( arvalid		),
    .arapcmd		( arapcmd		),
    .arready		( arready		),
    .arqos			( arqos			),
    .arprot     (arprot     ),
    .arcache    (arcache    ),
    //
    .wdata			( wdata			),
    .wstrb			( wstrb			),
    .wlast			( wlast			),
    .wvalid			( wvalid		),
    .wready			( wready		),
    //
    .rid			  ( rid			  ),
    .rdata			( rdata			),
    .rlast			( rlast			),
    .rvalid			( rvalid		),
    .rready			( rready		),
    .rresp			( rresp			),
    .bid			  ( bid			  ),
    .bvalid			( bvalid		),
    .bready			( bready		));

//===================================================================================
//
//===================================================================================


wire tx_valid;
wire [23:0] tx_vin;
// Back-pressure towards par2ser: high means "do not push a word this cycle".
wire tx_almost_full;
    par2ser_parse#(
      .VID_WIDTH 				( O_VID_WIDTH  ),
      .AXI_DATA_WIDTH   (AXI_DATA_WIDTH)
      
    )u_par2ser_parse(
    /*i*/.clk               (o_clk),
    /*i*/.rst_n             (rd_clk_rst_n),
    /*i*/.frame_period      (	fifo_rd_period),
    /*i*/.ddr_frame_len     (ddr_frame_len),
    /*i*/.rd_fifo_rdvalid   (rd_fifo_rdvalid  ),
    /*i*/.rd_fifo_rddata    (rd_fifo_rddata		),
    /*i*/.rd_fifo_rdempty   (rd_fifo_rdempty ),
    /*o*/.rd_fifo_rden      (rd_fifo_rden     ),

    /*o*/.tx_fifo_wrdata     (tx_vin),
    /*o*/.tx_fifo_valid    (tx_valid),
    /*I*/.tx_fifo_full    (tx_almost_full)
);

    



always @( posedge o_clk )
begin
    h_front_porch   <=  H_FRONT_PORCH ;
    h_sync 	 		    <=  H_SYNC 			  ;
    h_valid 	 	    <=  H_VALID 		  ;
    h_back_porch    <=  H_BACK_PORCH 	;
    v_front_porch   <=  V_FRONT_PORCH ;
    v_sync 	 		    <=  V_SYNC 			  ;
    v_valid 	 	    <=  V_VALID 		  ;
    v_back_porch    <=  V_BACK_PORCH 	;
end

reg rd_frame_en_r0 = 'd0;
reg rd_frame_en_r1 = 'd0;

// RD_FREE_RUN: hold the read side disabled for a few cycles after reset, then
// raise enable once and leave it high.  The single 0->1 edge is required:
// data_tx derives its own FIFO reset and its internal enable from it
// (pos_frame_start = frame_en & ~frame_start_d0), so a permanently-high
// enable would never reset the read FIFO and the state machines would never
// leave their post-reset state.
localparam integer FREE_RUN_DELAY = 16;
reg [7:0] free_run_cnt = 'd0;

always @( posedge o_clk or negedge rd_clk_rst_n )
begin
    if( !rd_clk_rst_n ) begin
      rd_frame_en_r0 <= 1'b0;
      rd_frame_en_r1 <= 1'b0;
      free_run_cnt   <= 'd0;
    end else begin
      rd_frame_en_r0 <= frame_stable;

      if (RD_FREE_RUN) begin
        if (free_run_cnt != FREE_RUN_DELAY[7:0]) begin
          free_run_cnt   <= free_run_cnt + 1'b1;
          rd_frame_en_r1 <= 1'b0;
        end else begin
          rd_frame_en_r1 <= 1'b1;
        end
      end else begin
        rd_frame_en_r1 <= rd_frame_en_r0;
      end
    end
end

generate
wire [11:0] lf_level;

if (RD_FREE_RUN) begin : gen_read_sv
	// New read path: raster_gen owns the timing, frame_sync paces the DDR
	// read engine, layer_fetch absorbs the rate difference.
	frame_buffer_read #(
		.DATA_W         (O_VID_WIDTH),
		// Captured geometry, not display geometry.  The raster stays 1080p;
		// this is the rectangle the sensor fills inside it.
		.LAYER_W_WORDS  (CAM_VID_WIDTH / 2),
		.LAYER_H_LINES  (CAM_VID_HEIGHT)
	) u_read (
		.clk         (o_clk),
		.rst_n       (rd_clk_rst_n),
		.h_active    (H_VALID),
		.h_fp        (H_FRONT_PORCH),
		.h_sync      (H_SYNC),
		.h_bp        (H_BACK_PORCH),
		.v_active    (V_VALID),
		.v_fp        (V_FRONT_PORCH),
		.v_sync      (V_SYNC),
		.v_bp        (V_BACK_PORCH),
		.in_valid    (tx_valid),
		.in_data     (tx_vin),
		.frame_period(fifo_rd_period),
		.vout        (vout),
		.o_hs        (o_hs),
		.o_vs        (o_vs),
		.o_de        (o_de),
		.level       (lf_level),
		.dbg_stall   (rd_dbg_stall),
		.dbg_left    (rd_dbg_left),
		.dbg_push    (rd_dbg_push),
		.dbg_seq     (rd_dbg_seq)
	);

	// par2ser checks this before pushing.  layer_fetch only consumes inside the
	// active window, so without back-pressure the packer would run ahead during
	// blanking and lose words, shifting every following line.  One line of
	// headroom covers jitter and still stalls before overflow.  The threshold
	// is one captured line, so it has to follow the capture geometry rather
	// than the display width.
	assign tx_almost_full = (lf_level >= CAM_VID_WIDTH/2);

end else begin : gen_read_legacy
assign rd_dbg_stall = 16'd0;
assign rd_dbg_left  = 12'd0;
assign rd_dbg_push  = 24'd0;
assign rd_dbg_seq   = 112'd0;
data_tx #(
		.VID_WIDTH 				( O_VID_WIDTH  ),
		.FIFO_DIPTH  			( 1024 				 ),
		.FIFO_ALMOST_FULL	( 960          )
		
		
		)u_data_tx(
		/*i*/.clk					  (o_clk				),
		/*i*/.rst_n				  (rd_clk_rst_n	),
		/*i*/.H_FRONT_PORCH (h_front_porch),//( 50 			),
		/*i*/.H_SYNC 	 		  (h_sync 	 		),//( 50 			),
		/*i*/.H_VALID 	 	  (h_valid 	 	  ),//( 48 			),
		/*i*/.H_BACK_PORCH  (h_back_porch ),//( 50 			),
		/*i*/.V_FRONT_PORCH (v_front_porch),//( 5 			),
		/*i*/.V_SYNC 	 		  (v_sync 	 		),//( 5 			),
		/*i*/.V_VALID 	 	  (v_valid 	 	  ),//( 20 			),
		/*i*/.V_BACK_PORCH  (v_back_porch ),//( 5 			),
		/*i*/.frame_en		  (rd_frame_en_r1),//(  	frame_stable		),//(tx_frame_en	),
		/*i*/.fifo_wr_data  (tx_vin				),
		/*i*/.fifo_wr_en	  (tx_valid			),
		/*o*/.fifo_wr_almost_full	(tx_almost_full	),
		/*o*/.fifo_rd_period(fifo_rd_period),
		/*o*/.vout		(vout		),
		/*o*/.o_hs		(o_hs		),
		/*o*/.o_vs		(o_vs		),
		/*o*/.o_de		(o_de		)
		
		);
	
	
	
end
endgenerate

/*----------------------------------------------------------------------------------*\
                                 The function code
\*----------------------------------------------------------------------------------*/
function integer clogb2;
input [31:0] value;
begin
value = value - 1;
for (clogb2 = 0; value > 0; clogb2 = clogb2 + 1)
value = value >> 1;
end
endfunction


endmodule