// st_vid_pipe.v -- tiled video pipe: one 16x16 inference tile per frame,
// stitched into a 64x64 processed mosaic over a 4x4 tile round-robin.
module st_vid_pipe #(
    parameter integer TILE=16, SCALE=8, GRID=4, H_FULL=1920, V_FULL=1080,
    parameter integer PIP_H_NUM=9, PIP_H_DEN=16,
    parameter integer DEBUG_PATTERN=0
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
    output reg pipe_busy,
    output reg [31:0] dbg_cap_samples,
    output reg [31:0] dbg_cap_tiles,
    output reg [15:0] dbg_last_x,
    output reg [15:0] dbg_last_y,
    output reg [7:0]  dbg_last_cap_addr,
    output reg [31:0] dbg_commit_count,
    output reg [7:0]  dbg_last_commit_addr
);
    localparam X_STEP=H_FULL/(TILE*GRID), Y_STEP=V_FULL/(TILE*GRID);
    localparam REGION_W=H_FULL/GRID, REGION_H=V_FULL/GRID;
    localparam OUT_W=TILE*GRID, OUT_H=TILE*GRID;
    localparam PIP_W=TILE*GRID*SCALE;
    localparam PIP_H=(PIP_W*PIP_H_NUM)/PIP_H_DEN;
    // PIP_W/PIP_H are display dimensions.  The memory remains OUT_WxOUT_H.
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

    reg y_we; reg [11:0] y_waddr; reg [7:0] y_wdata; reg [1:0] y_plane;
    reg [11:0] vid_y_raddr; wire [7:0] yr,yg,yb;
    wire we_r=y_we&(y_plane==2'd0), we_g=y_we&(y_plane==2'd1), we_b=y_we&(y_plane==2'd2);
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(12),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_yr (
        .we1(we_r),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(y_wdata),.din2(8'd0),.addr1(y_waddr),.addr2(vid_y_raddr),
        .dout1(),.dout2(yr));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(12),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_yg (
        .we1(we_g),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(y_wdata),.din2(8'd0),.addr1(y_waddr),.addr2(vid_y_raddr),
        .dout1(),.dout2(yg));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(12),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_yb (
        .we1(we_b),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(y_wdata),.din2(8'd0),.addr1(y_waddr),.addr2(vid_y_raddr),
        .dout1(),.dout2(yb));

    // A completed accelerator tile is staged separately from the displayed
    // 64x64 mosaic.  Writing the mosaic RAM while the HDMI reader is scanning
    // that same tile creates a horizontal tear/stripe.  The staging RAM is
    // selected for one tile while it is committed to the mosaic, so the
    // reader sees a stable tile for the whole frame.
    reg tile_we; reg [7:0] tile_waddr, tile_raddr; reg [7:0] tile_wdata;
    reg [1:0] tile_plane;
    reg [7:0] sys_tile_raddr;
    wire [7:0] tile_r, tile_g, tile_b;
    wire [7:0] tile_sys_r, tile_sys_g, tile_sys_b;
    wire tile_we_r=tile_we&(tile_plane==2'd0), tile_we_g=tile_we&(tile_plane==2'd1), tile_we_b=tile_we&(tile_plane==2'd2);
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_tile_r (
        .we1(tile_we_r),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(tile_wdata),.din2(8'd0),.addr1(tile_we ? tile_waddr : sys_tile_raddr),.addr2(tile_raddr),
        .dout1(tile_sys_r),.dout2(tile_r));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_tile_g (
        .we1(tile_we_g),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(tile_wdata),.din2(8'd0),.addr1(tile_we ? tile_waddr : sys_tile_raddr),.addr2(tile_raddr),
        .dout1(tile_sys_g),.dout2(tile_g));
    true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(8),
        .WRITE_MODE_1("WRITE_FIRST"),.WRITE_MODE_2("READ_FIRST"),
        .OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE("")) u_tile_b (
        .we1(tile_we_b),.we2(1'b0),.clka(sys_clk),.clkb(vid_clk),
        .din1(tile_wdata),.din2(8'd0),.addr1(tile_we ? tile_waddr : sys_tile_raddr),.addr2(tile_raddr),
        .dout1(tile_sys_b),.dout2(tile_b));

    reg vs_d,cap_active; reg [11:0] xcnt,ycnt; reg [7:0] cap_wx,cap_wy;
    reg line_active;
    reg cap_tog_vid; reg [1:0] cap_tog_sync;
    // Tile selector is owned by sys_clk and synchronized into the video clock.
    // The selector is latched at VS, so it cannot change halfway through a tile.
    reg [3:0] tile_sel_sys, tile_sel_frame;
    reg [3:0] tile_sel_sync1, tile_sel_sync2;
    reg [3:0] tile_active_sys, tile_active_frame;
    reg [3:0] tile_active_sync1, tile_active_sync2;
    reg [1:0] busy_vid_sync;
    wire [1:0] tile_col = tile_sel_frame[1:0];
    wire [1:0] tile_row = tile_sel_frame[3:2];
    wire [11:0] tile_x0 = tile_col * (H_FULL/GRID);
    wire [11:0] tile_y0 = tile_row * (V_FULL/GRID);

    // Pipeline PiP readout 1 cycle to match TDP BRAM read latency.
    // Without this, each SCALE tile boundary shows a 1px ghost of the left
    // tile (most noticeable as a vertical line near image center).
    reg        pip_pend, border_pend, tile_pend;
    reg [3:0]  tile_id_pend;
    reg [7:0]  tile_addr_pend;
    reg [7:0]  in_r_d, in_g_d, in_b_d;
    reg        in_de_d, in_hs_d, in_vs_d;

    always @(posedge vid_clk or negedge vid_rst_n) begin
        if(!vid_rst_n) begin
            vs_d<=0;xcnt<=0;ycnt<=0;line_active<=0;cap_active<=0;cap_we<=0;cap_waddr<=0;
            dbg_cap_samples<=0; dbg_cap_tiles<=0; dbg_last_x<=0; dbg_last_y<=0; dbg_last_cap_addr<=0;
            cap_wx<=0;cap_wy<=0;cap_tog_vid<=0;
            tile_sel_sync1<=0; tile_sel_sync2<=0; tile_sel_frame<=0;
            tile_active_sync1<=4'hf; tile_active_sync2<=4'hf; tile_active_frame<=4'hf;
            busy_vid_sync<=0;
            out_de<=0;out_hs<=0;out_vs<=0;out_r<=0;out_g<=0;out_b<=0;vid_y_raddr<=0;
            pip_pend<=0; border_pend<=0; tile_pend<=0; tile_id_pend<=4'hf; tile_addr_pend<=0; tile_raddr<=0;
            in_r_d<=0; in_g_d<=0; in_b_d<=0; in_de_d<=0; in_hs_d<=0; in_vs_d<=0;
        end else begin
            vs_d<=in_vs; cap_we<=0;
            tile_sel_sync1<=tile_sel_sys;
            tile_sel_sync2<=tile_sel_sync1;
            tile_active_sync1<=tile_active_sys;
            tile_active_sync2<=tile_active_sync1;
            busy_vid_sync<={busy_vid_sync[0],hw_busy};
            if(in_vs & ~vs_d) begin
                xcnt<=0;ycnt<=0;line_active<=0;cap_active<=~busy_vid_sync[1];cap_wx<=0;cap_wy<=0;
                tile_sel_frame<=tile_sel_sync2;
                tile_active_frame<=tile_active_sync2;
            end
            if(in_de) begin
                // Derive active width from the actual video stream.  The
                // debayer/HDMI clock bridge can present one or two clocks
                // per source pixel, so comparing against a fixed 1920 count
                // can leave ycnt stuck at zero and fill only the first row.
                if(!line_active) begin xcnt<=0; line_active<=1; end
                if(cap_active && xcnt == tile_x0 + (cap_wx*REGION_W)/TILE &&
                   ycnt == tile_y0 + (cap_wy*REGION_H)/TILE &&
                   (cap_wx<TILE[7:0]) && (cap_wy<TILE[7:0])) begin
                    cap_we<=1;
                    dbg_cap_samples<=dbg_cap_samples+1;
                    dbg_last_x<=xcnt; dbg_last_y<=ycnt;
                    dbg_last_cap_addr<=cap_wy*TILE+cap_wx;
                    cap_wr<=in_r>>1; cap_wg<=in_g>>1; cap_wb<=in_b>>1;
                    // Linear address works for every TILE parameter.  The
                    // former nibble concatenation only happened to be valid
                    // for TILE=16 and made the verification configuration
                    // expose out-of-range writes for smaller tiles.
                    cap_waddr <= cap_wy*TILE + cap_wx;
                    if(cap_wx==TILE[7:0]-1) begin
                        cap_wx<=0;
                        if(cap_wy==TILE[7:0]-1) begin cap_active<=0; cap_tog_vid<=~cap_tog_vid; dbg_cap_tiles<=dbg_cap_tiles+1; end
                        else cap_wy<=cap_wy+1;
                    end else cap_wx<=cap_wx+1;
                end
                xcnt<=xcnt+1;
            end else if(line_active) begin
                line_active<=0;
                xcnt<=0;
                ycnt<=ycnt+1;
            end

            // Stage A: issue Y-plane address; remember PiP/border for next beat
            begin : ov_addr
                reg [11:0] px,py; reg [11:0] sx,sy; reg [3:0] tid; reg [7:0] ta;
                px=xcnt; py=ycnt;
                in_r_d<=in_r; in_g_d<=in_g; in_b_d<=in_b;
                in_de_d<=in_de; in_hs_d<=in_hs; in_vs_d<=in_vs;
                if(in_de && px<PIP_W && py<PIP_H) begin
                    sx=px/SCALE; sy=(py*OUT_H)/PIP_H;
                    vid_y_raddr <= sy*OUT_W + sx;
                    tid=(sy/TILE)*GRID+(sx/TILE);
                    ta=(sy%TILE)*TILE+(sx%TILE);
                    tile_raddr <= ta;
                    pip_pend <= 1'b1;
                    tile_pend <= 1'b1;
                    tile_id_pend <= tid;
                    tile_addr_pend <= ta;
                    border_pend <= (px<2||py<2||px>=PIP_W-2||py>=PIP_H-2);
                end else begin
                    pip_pend <= 1'b0;
                    tile_pend <= 1'b0;
                    border_pend <= 1'b0;
                end
            end

            // Stage B: BRAM data (yr/yg/yb) now matches pending addr from prior cycle
            out_de<=in_de_d; out_hs<=in_hs_d; out_vs<=in_vs_d;
            if(in_de_d && pip_pend) begin
                if (DEBUG_PATTERN != 0) begin
                    // Diagnostic image: red identifies the 4x4 tile, green
                    // is the local y coordinate and blue is the local x
                    // coordinate.  It bypasses both the accelerator and all
                    // tile RAMs, isolating video coordinate/DE alignment.
                    out_r <= {tile_id_pend,4'b0};
                    out_g <= {tile_addr_pend[7:4],4'b0};
                    out_b <= {tile_addr_pend[3:0],4'b0};
                end else if(border_pend) begin
                    // Border marking is disabled for board validation: it
                    // can be mistaken for a real red/purple network pixel.
                    // Use the selector latched at VS.  tile_active_sync2 is
                    // allowed to change whenever a sys-clock tile commit
                    // completes; comparing against it here would switch the
                    // overlay halfway through a video frame and produce a
                    // horizontal stripe/partial tile.
                    if (tile_pend && tile_id_pend==tile_active_frame) begin
                        out_r<=tile_r; out_g<=tile_g; out_b<=tile_b;
                    end else begin
                        out_r<=yr; out_g<=yg; out_b<=yb;
                    end
                end else begin
                    if (tile_pend && tile_id_pend==tile_active_frame) begin
                        out_r<=tile_r; out_g<=tile_g; out_b<=tile_b;
                    end else begin
                        out_r<=yr; out_g<=yg; out_b<=yb;
                    end
                end
            end else begin
                out_r<=in_r_d; out_g<=in_g_d; out_b<=in_b_d;
            end
        end
    end

    localparam SS_IDLE=0, SS_PRE_R=1, SS_PRE_G=2, SS_PRE_B=3,
               SS_CH=4, SS_COPYX=5, SS_START=6, SS_WAIT=7, SS_COPYY=8,
               SS_COMMIT_PRE=9, SS_COMMIT=10, SS_COMMIT_DONE=11;
    reg [3:0] ss; reg [9:0] copy_idx; reg [1:0] ch; reg cap_tog_sys_d, hw_done_d;
    reg [1:0] commit_plane; reg [9:0] commit_idx;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            ss<=SS_IDLE; copy_idx<=0; pipe_busy<=0; frame_cnt<=0; ch<=0;
            hw_x_we<=0; hw_x_addr<=0; hw_x_data<=0; hw_load_w<=0; hw_start<=0;
            hw_y_addr<=0; y_we<=0; y_waddr<=0; y_wdata<=0; y_plane<=0;
            dbg_commit_count<=0; dbg_last_commit_addr<=0;
            tile_we<=0; tile_waddr<=0; tile_wdata<=0; tile_plane<=0; sys_tile_raddr<=0;
            commit_plane<=0; commit_idx<=0;
            tile_sel_sys<=0;
            cap_tog_sync<=0; sys_cap_raddr<=0; hw_done_d<=0; cap_tog_sys_d<=0;
        end else begin
            hw_x_we<=0; hw_load_w<=0; hw_start<=0; y_we<=0; tile_we<=0;
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
                // The accelerator output path has two registered memories
                // plus the interface register.  The first sample therefore
                // needs one bubble after issuing address 1; without it the
                // first output byte is repeated and every tile starts with a
                // visible vertical stripe.
                SS_COPYY: begin
                    if(copy_idx==0) begin hw_y_addr<=0; copy_idx<=1; end
                    else if(copy_idx==1) begin hw_y_addr<=1; copy_idx<=2; end
                    else if(copy_idx==2) begin
                        hw_y_addr<=2; copy_idx<=3;
                    end else if(copy_idx==3) begin
                        // Two registered reads plus hw_y_data require two
                        // address lead cycles before the first write.
                        hw_y_addr<=3; copy_idx<=4;
                    end else if(copy_idx<=NP*3+3) begin
                        begin : cy_next
                            reg [9:0] i; reg [7:0] pix; reg [1:0] c;
                            reg [5:0] py,px; reg [1:0] tcx,tcy;
                            i=copy_idx-10'd4; c=i%3; pix=i/3;
                            py=pix/TILE; px=pix%TILE;
                            tcx=tile_sel_sys%GRID; tcy=tile_sel_sys/GRID;
                            // Stage the complete tile first.  The mosaic is
                            // committed only after all 768 bytes are stable.
                            tile_we<=1; tile_plane<=c; tile_waddr<=pix; tile_wdata<=hw_y_data;
                        end
                        hw_y_addr<= {2'b0, copy_idx[9:0]}; copy_idx<=copy_idx+1;
                    end else begin
                        ss<=SS_COMMIT_PRE;
                    end
                end
                // Hold the newly produced tile on the video side while its
                // staged bytes are copied into the mosaic RAM.  This removes
                // the read/write collision that caused the moving top stripe.
                SS_COMMIT_PRE: begin
                    tile_active_sys<=tile_sel_sys;
                    commit_plane<=0; commit_idx<=0; sys_tile_raddr<=0;
                    ss<=SS_COMMIT;
                end
                SS_COMMIT: begin
                    if (commit_idx>0) begin : commit_write
                        reg [9:0] i; reg [5:0] py,px; reg [1:0] tcx,tcy;
                        i=commit_idx-1; py=i/TILE; px=i%TILE;
                        tcx=tile_sel_sys%GRID; tcy=tile_sel_sys/GRID;
                        y_we<=1; y_plane<=commit_plane;
                        y_waddr<=((tcy*TILE+py)*OUT_W)+(tcx*TILE+px);
                        dbg_last_commit_addr<=((tcy*TILE+py)*OUT_W)+(tcx*TILE+px);
                        case(commit_plane)
                          2'd0: y_wdata<=tile_sys_r;
                          2'd1: y_wdata<=tile_sys_g;
                          default: y_wdata<=tile_sys_b;
                        endcase
                    end
                    if (commit_idx==NP[9:0]) begin
                        if (commit_plane!=2'd2) begin
                            commit_plane<=commit_plane+1; commit_idx<=0; sys_tile_raddr<=0;
                        end else begin
                            dbg_commit_count<=dbg_commit_count+1;
                            ss<=SS_COMMIT_DONE;
                        end
                    end else begin
                        sys_tile_raddr<=commit_idx[7:0];
                        commit_idx<=commit_idx+1;
                    end
                end
                SS_COMMIT_DONE: begin
                    // The last y write occurred in the preceding state.
                    // Hide the staging tile before it is reused for the next
                    // inference, then advance the round-robin selector.
                    tile_active_sys<=4'hf;
                    frame_cnt<=frame_cnt+1;
                    tile_sel_sys <= (tile_sel_sys==(GRID*GRID-1)) ? 0 : tile_sel_sys+1;
                    ss<=SS_IDLE; pipe_busy<=0;
                end
                default: ss<=SS_IDLE;
            endcase
        end
    end
// Simulation-only safety net.  Enable with -DST_PIPE_ASSERT; Efinity builds
// leave it disabled.  These checks turn address/handshake mistakes into a
// deterministic failure instead of a plausible-looking corrupted picture.
`ifdef ST_PIPE_ASSERT
always @(posedge vid_clk) begin
    if (cap_we && cap_waddr >= TILE*TILE)
        $fatal(1, "st_vid_pipe capture address out of range: %0d", cap_waddr);
    if (in_de && pip_pend && vid_y_raddr >= OUT_W*OUT_H)
        $fatal(1, "st_vid_pipe output read address out of range: %0d", vid_y_raddr);
    if (tile_sel_frame >= GRID*GRID)
        $fatal(1, "st_vid_pipe tile selector out of range: %0d", tile_sel_frame);
end
always @(posedge sys_clk) begin
    if (hw_x_we && hw_x_addr >= TILE*TILE)
        $fatal(1, "st_vid_pipe accelerator input address out of range: %0d", hw_x_addr);
    if (y_we && y_waddr >= OUT_W*OUT_H)
        $fatal(1, "st_vid_pipe mosaic write address out of range: %0d", y_waddr);
    // One terminal value is reached after the final write before the FSM
    // returns to idle; it is not an address request.
    if (ss == SS_COPYY && copy_idx > NP*3+4)
        $fatal(1, "st_vid_pipe accelerator output copy index out of range: %0d", copy_idx);
end
`endif
endmodule
