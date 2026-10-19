`timescale 1ns/1ps
// Deterministic protocol test for st_vid_pipe.  Small parameters keep this
// test fast while exercising every tile, channel and output-copy transaction.
module tb_st_vid_pipe;
  localparam TILE=2, GRID=4, SCALE=1, H=8, V=8, NP=TILE*TILE;
  reg vid_clk=0, sys_clk=0, vid_rst_n=0, sys_rst_n=0;
  always #5 vid_clk=~vid_clk;
  always #7 sys_clk=~sys_clk;
  reg in_de=0,in_hs=0,in_vs=0; reg [7:0] in_r=0,in_g=0,in_b=0;
  wire out_de,out_hs,out_vs; wire [7:0] out_r,out_g,out_b;
  wire hw_x_we; wire [9:0] hw_x_addr; wire [7:0] hw_x_data;
  wire hw_load_w,hw_start; reg hw_busy=0,hw_done=0;
  wire [11:0] hw_y_addr; reg [7:0] hw_y_data=0;
  wire [31:0] frame_cnt; wire pipe_busy;

  st_vid_pipe #(.TILE(TILE),.SCALE(SCALE),.GRID(GRID),.H_FULL(H),.V_FULL(V)) dut(
    .vid_clk,.vid_rst_n,.sys_clk,.sys_rst_n,.in_de,.in_hs,.in_vs,
    .in_r,.in_g,.in_b,.out_de,.out_hs,.out_vs,.out_r,.out_g,.out_b,
    .hw_x_we,.hw_x_addr,.hw_x_data,.hw_load_w,.hw_start,.hw_busy,.hw_done,
    .hw_y_addr,.hw_y_data,.frame_cnt,.pipe_busy);

  // Two-cycle output-memory model, with a recognizable value per address.
  reg [11:0] ya0=0, ya1=0;
  always @(posedge sys_clk) begin
    ya0 <= hw_y_addr; ya1 <= ya0;
    hw_y_data <= ya1[7:0] ^ 8'h5a;
  end
  integer starts=0, done_count=0, x_count=0, y_count=0, output_index=0;
  integer last_x=-1, last_y=-1, last_tile=-1;
  always @(posedge sys_clk) begin
    if (hw_load_w) begin
      if (hw_x_we) $fatal(1,"load_w and x_we overlap");
    end
    if (hw_x_we) begin
      if (hw_x_addr >= NP) $fatal(1,"x address out of range");
      if (hw_x_addr != last_x+1 && hw_x_addr != 0)
        $fatal(1,"x addresses not sequential: %0d after %0d",hw_x_addr,last_x);
      last_x=hw_x_addr; x_count=x_count+1;
    end
    if (hw_start) begin
      starts=starts+1; hw_busy<=1; hw_done<=0; last_x=-1; output_index=0;
      ya0<=0; ya1<=0; hw_y_data<=0;
    end else if (hw_busy && !hw_done && starts>done_count) begin
      // fixed latency model; done is a one-cycle pulse
      if ((x_count % (NP*3)) == 0) begin hw_done<=1; done_count=done_count+1; end
    end else if (hw_done) begin
      hw_done<=0; hw_busy<=0;
    end
  end
  // Check after nonblocking assignments settle.  This corresponds to the
  // actual BRAM write edge and avoids sampling the previous y_we/y_wdata.
  always @(negedge sys_clk) begin
    if (dut.tile_we && dut.ss == 4'd8) begin
      if (dut.y_waddr >= TILE*GRID*TILE*GRID) $fatal(1,"mosaic address out of range");
      if (dut.tile_wdata !== ((output_index[7:0]) ^ 8'h5a))
        $fatal(1,"accelerator output alignment: index=%0d data=%02x expected=%02x", output_index,dut.tile_wdata,(output_index[7:0]^8'h5a));
      output_index=output_index+1;
    end
    if (dut.y_we) begin
      if (dut.y_waddr >= TILE*GRID*TILE*GRID) $fatal(1,"mosaic address out of range");
      y_count=y_count+1;
    end
  end

  task automatic line(input integer y);
    integer x;
    begin
      in_vs <= (y==0); @(posedge vid_clk); in_vs<=0;
      for (x=0;x<H;x=x+1) begin
        in_de<=1; in_hs<=(x==0); in_r<=x; in_g<=y; in_b<=dut.tile_sel_frame;
        @(posedge vid_clk);
      end
      in_de<=0; in_hs<=0; @(posedge vid_clk);
    end
  endtask
  integer f;
  initial begin
    repeat(4) @(posedge vid_clk); vid_rst_n<=1; sys_rst_n<=1;
    // Four frames cover the first row of the four-column tile selector.
    for (f=0;f<4;f=f+1) begin
      repeat(1) @(posedge vid_clk);
      for (integer y=0;y<V;y=y+1) line(y);
      // Let the independent system-clock FSM finish this tile before the
      // next frame toggles capture; this also exercises the busy gate.
      repeat(250) @(posedge sys_clk);
    end
    repeat(5000) @(posedge sys_clk);
    if (starts != 4) $fatal(1,"expected 4 accelerator starts, got %0d",starts);
    if (x_count != 4*NP*3) $fatal(1,"expected %0d input writes, got %0d",4*NP*3,x_count);
    // Initial PiP prefill plus one tear-free mosaic commit per tile.
    if (y_count != 8*NP*3) $fatal(1,"expected %0d mosaic writes, got %0d",8*NP*3,y_count);
    $display("PASS st_vid_pipe protocol: starts=%0d x_writes=%0d y_writes=%0d",starts,x_count,y_count);
    $finish;
  end
endmodule
