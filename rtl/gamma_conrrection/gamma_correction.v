module gamma_correction
#(
	parameter	DATA_WIDTH	= 10,
	parameter 	GAMMA_CURVE	= "2P2.mem"
)
(
	input						i_pclk,
	input						i_rstn,
	input 						i_valid,
	input 						i_hs,
	input 						i_vs,
	input 	[DATA_WIDTH-1:0]	i_red,
	input 	[DATA_WIDTH-1:0]	i_green,
	input 	[DATA_WIDTH-1:0]	i_blue,
	output	reg[DATA_WIDTH-1:0]	o_red,
	output	reg[DATA_WIDTH-1:0]	o_green,
	output	reg[DATA_WIDTH-1:0]	o_blue,
	output	reg					o_valid,
	output  reg  				o_hs,
	output 	reg 				o_vs
);
	wire [9:0] addr_r = (DATA_WIDTH == 10) ? i_red[9:0] : {i_red[7:0], i_red[7:6]};
	wire [9:0] addr_g = (DATA_WIDTH == 10) ? i_green[9:0] : {i_green[7:0], i_green[7:6]};
	wire [9:0] addr_b = (DATA_WIDTH == 10) ? i_blue[9:0]  : {i_blue[7:0],  i_blue[7:6]};
	wire [9:0] gam_r, gam_g, gam_b;

	simple_dual_port_ram #(.DATA_WIDTH(10), .ADDR_WIDTH(10), .OUTPUT_REG("TRUE"),
		.RAM_INIT_FILE(GAMMA_CURVE), .RAM_INIT_RADIX("HEX")) u_rom_r (
		.wdata(10'd0), .waddr(10'd0), .raddr(addr_r), .we(1'b0),
		.wclk(i_pclk), .re(1'b1), .rclk(i_pclk), .rdata(gam_r));
	simple_dual_port_ram #(.DATA_WIDTH(10), .ADDR_WIDTH(10), .OUTPUT_REG("TRUE"),
		.RAM_INIT_FILE(GAMMA_CURVE), .RAM_INIT_RADIX("HEX")) u_rom_g (
		.wdata(10'd0), .waddr(10'd0), .raddr(addr_g), .we(1'b0),
		.wclk(i_pclk), .re(1'b1), .rclk(i_pclk), .rdata(gam_g));
	simple_dual_port_ram #(.DATA_WIDTH(10), .ADDR_WIDTH(10), .OUTPUT_REG("TRUE"),
		.RAM_INIT_FILE(GAMMA_CURVE), .RAM_INIT_RADIX("HEX")) u_rom_b (
		.wdata(10'd0), .waddr(10'd0), .raddr(addr_b), .we(1'b0),
		.wclk(i_pclk), .re(1'b1), .rclk(i_pclk), .rdata(gam_b));

	reg v0,v1,v2, h0,h1,h2, s0,s1,s2;
	always @(posedge i_pclk or negedge i_rstn) begin
		if (!i_rstn) begin
			{v0,v1,v2,h0,h1,h2,s0,s1,s2} <= 0;
			o_red <= 0; o_green <= 0; o_blue <= 0;
			o_valid <= 0; o_hs <= 0; o_vs <= 0;
		end else begin
			v0 <= i_valid; v1 <= v0; v2 <= v1;
			h0 <= i_hs;    h1 <= h0; h2 <= h1;
			s0 <= i_vs;    s1 <= s0; s2 <= s1;
			o_valid <= v2; o_hs <= h2; o_vs <= s2;
			if (v2) begin
				if (DATA_WIDTH == 10) begin
					o_red <= gam_r; o_green <= gam_g; o_blue <= gam_b;
				end else begin
					o_red <= gam_r[9:2]; o_green <= gam_g[9:2]; o_blue <= gam_b[9:2];
				end
			end else begin
				o_red <= 0; o_green <= 0; o_blue <= 0;
			end
		end
	end
endmodule
