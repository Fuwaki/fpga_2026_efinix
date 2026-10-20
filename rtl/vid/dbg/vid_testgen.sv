// vid_testgen.sv -- frame source for DMA self-tests.
//
// Emits frames of geom.w x geom.h pixels as 2-pixel words carrying
// test_word(frame, line, word), at one frame per FRAME_CYCLES and one line per
// LINE_CYCLES, i.e. with the line and frame blanking a sensor has.  Honours
// ready; while it is low the source simply waits (it is a test source, not a
// camera).
module vid_testgen
    import vid_pkg::*;
#(
    parameter int FRAME_CYCLES = 3_333_333,   // 30 fps at 100 MHz
    parameter int LINE_CYCLES  = 2_000
) (
    vstream_if.src          o,
    input  frame_geom_t     geom,
    input  logic            enable,
    output logic [15:0]     frame         // number of the frame being emitted
);
    logic [31:0] fcyc;
    logic [15:0] lcyc;
    logic [11:0] y, w;
    logic        in_line, in_frame;

    wire [11:0] wpl = 12'(geom.w / 13'd2);

    always_ff @(posedge o.clk or negedge o.rst_n) begin
        if (!o.rst_n) begin
            fcyc     <= '0;
            lcyc     <= '0;
            y        <= '0;
            w        <= '0;
            in_line  <= 1'b0;
            in_frame <= 1'b0;
            frame    <= '0;
            o.valid  <= 1'b0;
            o.sof    <= 1'b0;
            o.eol    <= 1'b0;
            o.data   <= '0;
        end else begin
            fcyc <= (fcyc == 32'(FRAME_CYCLES - 1)) ? '0 : fcyc + 1'b1;
            lcyc <= (lcyc == 16'(LINE_CYCLES - 1) || fcyc == 32'(FRAME_CYCLES - 1)) ? '0 : lcyc + 1'b1;

            if (fcyc == 32'(FRAME_CYCLES - 1) && enable && !in_frame) begin
                in_frame <= 1'b1;
                y        <= '0;
            end
            if (in_frame && !in_line && lcyc == '0) begin
                in_line <= 1'b1;
                w       <= '0;
            end

            if (o.valid && o.ready)
                o.valid <= 1'b0;

            if (in_line && (!o.valid || o.ready)) begin
                o.valid <= 1'b1;
                o.data  <= test_word(frame, y, w);
                o.sof   <= (y == 0) && (w == 0);
                o.eol   <= (w == wpl - 1'b1);
                if (w == wpl - 1'b1) begin
                    in_line <= 1'b0;
                    if (y == 12'(geom.h) - 1'b1) begin
                        in_frame <= 1'b0;
                        frame    <= frame + 1'b1;
                    end else begin
                        y <= y + 1'b1;
                    end
                end else begin
                    w <= w + 1'b1;
                end
            end
        end
    end
endmodule
