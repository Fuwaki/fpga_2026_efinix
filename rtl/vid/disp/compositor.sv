// compositor.sv -- builds the HDMI raster from layers in DDR.
//
// Runs in the pixel clock, one pixel per clock.  raster_gen owns the timing
// (CEA-861 1080p60 by default); nothing upstream can stall it, so a missing
// frame shows black, never "no signal".
//
// v1: one CAM_W x CAM_H layer centred in the raster, black around it.
// frame_req toggles once per raster frame, at line 0, long before the layer's
// first line; the layer's reader starts on it (in its own clock domain).
module compositor
    import vid_pkg::*;
#(
    parameter int H_ACTIVE = 1920, H_FP = 88, H_SYNC = 44, H_BP = 148,
    parameter int V_ACTIVE = 1080, V_FP = 4,  V_SYNC = 5,  V_BP = 36
) (
    vstream_if.snk          layer0,       // pixel clock domain
    output logic            frame_req,    // toggles at the start of each raster frame

    output logic [7:0]      r,
    output logic [7:0]      g,
    output logic [7:0]      b,
    output logic            de,
    output logic            hs,
    output logic            vs,

    output logic [15:0]     st_bad_lines,
    output logic [15:0]     st_resyncs,
    // Brightness of what was actually sent: sum of r+g+b per raster frame,
    // and how often it jumped.  Static content gives a constant sum; a
    // moving test block changes it by at most a few million.
    output logic [31:0]     st_frame_sum,
    output logic [15:0]     st_jumps
);
    localparam int X0 = (H_ACTIVE - CAM_W) / 2;
    localparam int Y0 = (V_ACTIVE - CAM_H) / 2;

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

    // -------------------------------------------------------------- layer
    wire [12:0] lx = ras_x - 13'(X0);
    wire [12:0] ly = ras_y - 13'(Y0);
    wire in_x = (ras_x >= 13'(X0)) && (ras_x < 13'(X0 + CAM_W));
    wire in_y = (ras_y >= 13'(Y0)) && (ras_y < 13'(Y0 + CAM_H));
    wire want = ras_de && in_x && in_y;

    logic    l0_valid;
    rgb888_t l0_pix;

    layer_unpack u_l0 (
        .s           (layer0),
        .frame_start (frame_start),
        .want        (want),
        .line_first  (want && lx == 13'd0),
        .line_last   (want && lx == 13'(CAM_W - 1)),
        .lx0         (lx[0]),
        .ly_zero     (ly == 13'd0),
        .pix_valid   (l0_valid),
        .pix         (l0_pix),
        .st_bad_lines(st_bad_lines),
        .st_resyncs  (st_resyncs)
    );

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
            if (l0_valid) begin
                r <= l0_pix.r; g <= l0_pix.g; b <= l0_pix.b;
            end else begin
                r <= '0; g <= '0; b <= '0;
            end
        end
    end

endmodule
