// compositor.sv -- builds the HDMI raster from layers in DDR.
//
// Runs in the pixel clock, one pixel per clock.  raster_gen owns the timing
// (CEA-861 720p60 by default); nothing upstream can stall it, so a missing
// frame shows black, never "no signal".
//
// Two CAM_W x CAM_H layers share one window.  With the 720p60 defaults the
// 1280x720 picture fills the raster; a larger raster centres it and leaves
// black around it:
//   COMP_SINGLE  layer cfg.single_sel everywhere
//   COMP_SPLIT   layer 0 left of cfg.split_col, layer 1 from it on
// Each layer's reader fetches only the 8-pixel-aligned columns that can be
// shown (crop_beats() below), so a split costs no more DDR bandwidth than one
// layer.  Each layer's unpacker consumes its own window; the column of the
// split only picks which one is shown.
//
// frame_req toggles once per raster frame, at line 0, long before the
// window's first line; the readers start on it (in their own clock domain).
module compositor
    import vid_pkg::*;
#(
    parameter int H_ACTIVE = 1280, H_FP = 110, H_SYNC = 40, H_BP = 220,
    parameter int V_ACTIVE = 720,  V_FP = 5,   V_SYNC = 5,  V_BP = 20,
    parameter comp_cfg_t CFG = COMP_CFG_DEFAULT,
    // 1 = under live a layer opens to the full frame only while it is the
    // full-screen layer; otherwise it keeps its compile-time crop.  The
    // readers must fetch the same windows (vid_subsystem CROP_VIEW).
    parameter bit CROP_VIEW = 0
) (
    vstream_if.snk          layer0,       // pixel clock domain
    vstream_if.snk          layer1,
    output logic            frame_req,    // toggles at the start of each raster frame

    output logic [7:0]      r,
    output logic [7:0]      g,
    output logic [7:0]      b,
    output logic            de,
    output logic            hs,
    output logic            vs,

    output logic [15:0]     st_bad_lines [2],
    output logic [15:0]     st_resyncs   [2],
    // Brightness of what was actually sent: sum of r+g+b per raster frame,
    // and how often it jumped.  Static content gives a constant sum; a
    // moving test block changes it by at most a few million.
    output logic [31:0]     st_frame_sum,
    output logic [15:0]     st_jumps,

    // Pixel-clock menu.  Defaults keep existing benches connected.
    // live == 0 keeps the compile-time crop and CFG mux.  live == 1 opens
    // both layer windows to the full frame; view_full then picks one layer
    // instead of the split.  view_full does not resize a burst.
    input logic             live       = 1'b0,
    input logic             osd_en     = 1'b0,
    input logic             view_full  = 1'b0,
    input logic             single_sel = 1'b1,
    input logic             cursor     = 1'b0,
    input logic [1:0]       style      = 2'd0,
    input logic [6:0]       fps        = 7'd0
);
    localparam int X0 = (H_ACTIVE - CAM_W) / 2;
    localparam int Y0 = (V_ACTIVE - CAM_H) / 2;

    // Columns of each layer that are read and consumed, in beats.
    localparam logic [7:0] X0B0 = crop_beats(CFG, 0, 1'b0), NB0 = crop_beats(CFG, 0, 1'b1);
    localparam logic [7:0] X0B1 = crop_beats(CFG, 1, 1'b0), NB1 = crop_beats(CFG, 1, 1'b1);

    initial begin
        if (X0 % 2 != 0 || Y0 % 2 != 0)
            $error("compositor: layer offset must be even");
    end

    wire clk   = layer0.clk;
    wire rst_n = layer0.rst_n;

    // ------------------------------------------------------------- raster
    logic        ras_hs, ras_vs, ras_de, ras_sof, ras_vline0;
    logic [12:0] ras_x, ras_y;

    raster_gen u_raster (
        .clk       (clk),
        .rst_n     (rst_n),
        .h_active  (13'(H_ACTIVE)), .h_fp (13'(H_FP)), .h_sync (13'(H_SYNC)), .h_bp (13'(H_BP)),
        .v_active  (13'(V_ACTIVE)), .v_fp (13'(V_FP)), .v_sync (13'(V_SYNC)), .v_bp (13'(V_BP)),
        .hs        (ras_hs),
        .vs        (ras_vs),
        .de        (ras_de),
        .x         (ras_x),
        .y         (ras_y),
        .sof       (ras_sof),
        .vline_zero(ras_vline0)
    );

    // Frame marker: rising edge of line 0.
    logic vline0_d;
    wire  frame_start = ras_vline0 && !vline0_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vline0_d  <= 1'b0;
            frame_req <= 1'b0;
        end else begin
            vline0_d <= ras_vline0;
            if (frame_start)
                frame_req <= ~frame_req;
        end
    end

    // ------------------------------------------------------------- layers
    wire [12:0] lx = ras_x - 13'(X0);
    wire [12:0] ly = ras_y - 13'(Y0);
    // A zero origin makes `ras >= 0` a constant unsigned compare.  Write the
    // bound out, the same way show1 treats a split at column 0.
    wire in_y = (Y0 == 0 || ras_y >= 13'(Y0)) && (ras_y < 13'(Y0 + CAM_H));
    wire in_x = (X0 == 0 || ras_x >= 13'(X0)) && (ras_x < 13'(X0 + CAM_W));

    logic    l_valid [2];
    rgb888_t l_pix   [2];

    // live is static in the design (tied off).  A 0 keeps the compile-time
    // crop; a 1 consumes the whole frame on both layers.
    wire        l0_open = live && (!CROP_VIEW || (view_full && !single_sel));
    wire        l1_open = live && (!CROP_VIEW || (view_full &&  single_sel));
    wire [12:0] l0_x0 = l0_open ? 13'd0 : 13'(8 * int'(X0B0));
    wire [12:0] l0_x1 = l0_open ? 13'(CAM_W) : 13'(8 * (int'(X0B0) + int'(NB0)));
    wire [12:0] l1_x0 = l1_open ? 13'd0 : 13'(8 * int'(X0B1));
    wire [12:0] l1_x1 = l1_open ? 13'(CAM_W) : 13'(8 * (int'(X0B1) + int'(NB1)));

    comp_layer u_l0 (
        .s(layer0), .frame_start(frame_start), .de(ras_de && in_x && in_y), .lx(lx), .ly(ly),
        .x0(l0_x0), .x1(l0_x1),
        .pix_valid(l_valid[0]), .pix(l_pix[0]),
        .st_bad_lines(st_bad_lines[0]), .st_resyncs(st_resyncs[0]));

    comp_layer u_l1 (
        .s(layer1), .frame_start(frame_start), .de(ras_de && in_x && in_y), .lx(lx), .ly(ly),
        .x0(l1_x0), .x1(l1_x1),
        .pix_valid(l_valid[1]), .pix(l_pix[1]),
        .st_bad_lines(st_bad_lines[1]), .st_resyncs(st_resyncs[1]));

    // split_col 0 shows layer 1 everywhere (written out: lx >= 0 is a
    // constant comparison).  live selects the runtime mux; it does not
    // change which beats the readers were told to fetch.
    wire show1_cfg = (CFG.mode != COMP_SPLIT) ? CFG.single_sel
                   : (CFG.split_col == '0) || (lx >= 13'(CFG.split_col));
    wire show1_run = view_full ? single_sel
                   : (CFG.split_col == '0) || (lx >= 13'(CFG.split_col));
    wire show1 = live ? show1_run : show1_cfg;

    // ------------------------------------------------------- brightness
    localparam logic [31:0] JUMP = 32'd8_000_000;
    logic [31:0] acc;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc          <= '0;
            st_frame_sum <= '0;
            st_jumps     <= '0;
        end else if (frame_start) begin
            acc          <= '0;
            st_frame_sum <= acc;
            if (((acc > st_frame_sum) ? acc - st_frame_sum : st_frame_sum - acc) > JUMP)
                st_jumps <= st_jumps + 1'b1;
        end else if (de) begin
            acc <= acc + 32'(r) + 32'(g) + 32'(b);
        end
    end

    // ------------------------------------------------------------- output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r  <= '0; g <= '0; b <= '0;
            de <= 1'b0; hs <= 1'b0; vs <= 1'b0;
        end else begin
            de <= ras_de;
            hs <= ras_hs;
            vs <= ras_vs;
            if (show1 ? l_valid[1] : l_valid[0]) begin
                {r, g, b} <= show1 ? l_pix[1] : l_pix[0];
            end else begin
                r <= '0; g <= '0; b <= '0;
            end
            // Same cycle as ras_de/ras_x/ras_y: the registers above delay the
            // video pixel and the glyph together.  Unlit cells keep video.
            if (ras_de && osd_en &&
                osd_font::lit(ras_x, ras_y, view_full, cursor, style, fps)) begin
                {r, g, b} <= osd_font::yellow(ras_x, ras_y, cursor)
                           ? 24'hFFFF00 : 24'hFFFFFF;
            end
        end
    end

endmodule


// One layer of the compositor: unpacks the columns [x0, x1) of the window
// (layer coordinates).  An empty window (x1 == x0) means the layer is not
// read; its stream is drained so nothing upstream waits on it.
module comp_layer
    import vid_pkg::*;
(
    vstream_if.snk          s,
    input  logic            frame_start,
    input  logic            de,          // raster inside the window
    input  logic [12:0]     lx,
    input  logic [12:0]     ly,
    input  logic [12:0]     x0,
    input  logic [12:0]     x1,
    output logic            pix_valid,
    output rgb888_t         pix,
    output logic [15:0]     st_bad_lines,
    output logic [15:0]     st_resyncs
);
    wire on   = x1 > x0;
    wire want = on && de && (lx >= x0) && (lx < x1);

    // Gate the stream so an empty window holds ready high and produces no
    // pixels, matching the old generate-time g_off drain.
    vstream_if #(.T(rgb565_t), .PPC(2)) mid (.clk(s.clk), .rst_n(s.rst_n));
    assign mid.valid = on && s.valid;
    assign mid.sof   = s.sof;
    assign mid.eol   = s.eol;
    assign mid.data  = s.data;
    assign s.ready   = on ? mid.ready : 1'b1;

    logic            un_valid;
    rgb888_t         un_pix;
    logic [15:0]     un_bad, un_rs;
    layer_unpack u_un (
        .s           (mid),
        .frame_start (frame_start),
        .want        (want),
        .line_first  (want && lx == x0),
        .line_last   (want && lx == (x1 - 13'd1)),
        .lx0         (lx[0]),
        .ly_zero     (ly == 13'd0),
        .pix_valid   (un_valid),
        .pix         (un_pix),
        .st_bad_lines(un_bad),
        .st_resyncs  (un_rs));

    assign pix_valid    = on && un_valid;
    assign pix          = on ? un_pix : '0;
    assign st_bad_lines = on ? un_bad : '0;
    assign st_resyncs   = on ? un_rs : '0;
endmodule
