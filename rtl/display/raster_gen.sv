// raster_gen.sv -- CEA-861 raster generator, counted in video clocks.
//
// Owns every timing decision.  It has no input other than clock, reset and the
// timing registers, so nothing upstream can stall the monitor's lock: a frame
// that has not arrived renders black, never "no signal".
//
// Counting domain: the video clock (74.25 MHz), half the pixel clock.  Each
// horizontal figure is therefore the CEA pixel count halved: a 1920-pixel
// active line is 960 video clocks.  The 2:1 expansion to 148.5 Mpixel/s is
// done downstream by the existing pair unpacker, which is unrelated to timing.
//
// The timing fields are input ports rather than parameters on purpose: they
// belong to the panel's mode, which a CSR block may reconfigure at runtime.
// A parameter would freeze the raster at synthesis time and force a recompile
// for every mode change.
module raster_gen #(
    parameter int unsigned MAX_H = 2048,
    parameter int unsigned MAX_V = 2048
) (
    input  logic        clk,
    input  logic        rst_n,

    // timing for the current mode, in video clocks / lines
    input  logic [12:0] h_active,
    input  logic [12:0] h_fp,
    input  logic [12:0] h_sync,
    input  logic [12:0] h_bp,
    input  logic [12:0] v_active,
    input  logic [12:0] v_fp,
    input  logic [12:0] v_sync,
    input  logic [12:0] v_bp,

    output logic        hs,
    output logic        vs,
    output logic        de,
    output logic [12:0] x,
    output logic [12:0] y,
    output logic        sof,
    output logic        vline_zero   // high for the whole of line 0
);

    wire [12:0] h_total = h_active + h_fp + h_sync + h_bp;
    wire [12:0] v_total = v_active + v_fp + v_sync + v_bp;
    wire [12:0] h_start = h_sync + h_bp;
    wire [12:0] v_start = v_sync + v_bp;

    logic [12:0] hc, vc;

    wire last_col = (hc == h_total - 13'd1);
    wire last_row = (vc == v_total - 13'd1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hc <= '0;
            vc <= '0;
        end else if (last_col) begin
            hc <= '0;
            vc <= last_row ? 13'd0 : vc + 13'd1;
        end else begin
            hc <= hc + 13'd1;
        end
    end

    // CEA order within a line and a frame: sync, back porch, active, front porch.
    wire h_act = (hc >= h_start) && (hc < h_start + h_active);
    wire v_act = (vc >= v_start) && (vc < v_start + v_active);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs  <= 1'b0;
            vs  <= 1'b0;
            de  <= 1'b0;
            x   <= '0;
            y   <= '0;
            sof <= 1'b0;
            vline_zero <= 1'b0;
        end else begin
            hs  <= (hc < h_sync);
            vs  <= (vc < v_sync);
            de  <= h_act && v_act;
            x   <= h_act ? (hc - h_start) : 13'd0;
            y   <= v_act ? (vc - v_start) : 13'd0;
            sof <= h_act && v_act &&
                   (hc == h_start) && (vc == v_start);
            // Line 0 spans H_TOTAL clocks; frame_sync needs the whole window.
            vline_zero <= (vc == 13'd0);
        end
    end

endmodule
