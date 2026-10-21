// vid_patgen.sv -- emits pat_pixel() frames as RGB565 pixel pairs, with
// sensor-like line and frame blanking.  Honours ready.  Element 0 of each
// word is the left pixel.
module vid_patgen
    import vid_pkg::*;
#(
    parameter int FRAME_CYCLES = 3_333_333,   // 30 fps at 100 MHz
    parameter int LINE_CYCLES  = 2_000
) (
    vstream_if.src          o,
    input  logic            enable,
    output logic [15:0]     frame             // number of the frame being emitted
);
    localparam int WPL = CAM_W / 2;

    logic [31:0] fcyc;
    logic [15:0] lcyc;
    logic [11:0] y, w;
    logic        in_line, in_frame;

    rgb888_t p0, p1;
    assign p0 = pat_pixel({w[10:0], 1'b0}, y, frame);
    assign p1 = pat_pixel({w[10:0], 1'b1}, y, frame);

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
                o.valid   <= 1'b1;
                o.data[0] <= pack565(p0);
                o.data[1] <= pack565(p1);
                o.sof     <= (y == 0) && (w == 0);
                o.eol     <= (w == 12'(WPL - 1));
                if (w == 12'(WPL - 1)) begin
                    in_line <= 1'b0;
                    if (y == 12'(CAM_H - 1)) begin
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
