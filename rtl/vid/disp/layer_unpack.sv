// layer_unpack.sv -- turns a tagged stream of RGB565 pixel pairs into one
// pixel per clock at the raster positions of a layer.
//
// The raster asks for layer pixel (lx, ly) whenever want is high, left to
// right, top to bottom.  Each word holds two pixels (element 0 left); it is
// consumed after its second pixel.  Alignment comes from the tags, not from
// counting, so a fault costs at most the current line:
//
//   line start, ly == 0:  the head word must carry sof
//   line start, ly  > 0:  the head word must not carry sof
//   during the line:      a missing word (underflow) blanks the rest of it
//   last word of a line:  must carry eol
//
// A line that fails any check is shown black and counted.  Between lines
// (want low) the unpacker drops words to re-align: up to and including the
// next eol after a broken line, or up to the next sof when a frame is
// expected and the head is not one.  A head word carrying sof in the middle
// of a frame means the next frame arrived early: it waits for ly == 0.
module layer_unpack
    import vid_pkg::*;
(
    vstream_if.snk          s,           // in the raster clock domain
    input  logic            frame_start, // one cycle, before the layer's first line
    input  logic            want,        // raster is inside the layer
    input  logic            line_first,  // want && lx == 0
    input  logic            line_last,   // want && lx == width - 1
    input  logic            lx0,         // lx[0]
    input  logic            ly_zero,     // ly == 0

    output logic            pix_valid,   // pixel below is from the layer
    output rgb888_t         pix,
    output logic [15:0]     st_bad_lines,
    output logic [15:0]     st_resyncs
);
    typedef enum logic [1:0] { D_NONE, D_TO_EOL, D_TO_SOF } drain_e;
    drain_e drain;
    logic   line_ok;

    // Checks on the word at the head when a line starts.
    wire start_ok = s.valid && (s.sof == ly_zero);
    wire ok_now   = line_first ? start_ok : line_ok;
    wire have     = s.valid && ok_now;

    // Pixel out: left or right half of the head word.
    assign pix_valid = want && have;
    assign pix       = unpack565(lx0 ? s.data[1] : s.data[0]);

    // Consume after the right pixel, or while draining between lines.
    wire pop_line  = want && have && lx0;
    wire pop_drain = !want && s.valid &&
                     ((drain == D_TO_EOL) || (drain == D_TO_SOF && !s.sof));
    assign s.ready = pop_line || pop_drain;

    always_ff @(posedge s.clk or negedge s.rst_n) begin
        if (!s.rst_n) begin
            drain        <= D_NONE;
            line_ok      <= 1'b0;
            st_bad_lines <= '0;
            st_resyncs   <= '0;
        end else begin
            if (want) begin
                if (line_first) begin
                    line_ok <= start_ok;
                    if (!start_ok) begin
                        st_bad_lines <= st_bad_lines + 1'b1;
                        // A sof too early is kept.  Anything else, including
                        // a line whose words have not arrived yet (they will
                        // be late), is dropped.
                        if (!(s.valid && s.sof)) begin
                            drain      <= ly_zero ? D_TO_SOF : D_TO_EOL;
                            st_resyncs <= st_resyncs + 1'b1;
                        end
                    end
                end else if (line_ok && !s.valid) begin
                    // Underflow: the rest of this line's words come late.
                    line_ok      <= 1'b0;
                    drain        <= D_TO_EOL;
                    st_bad_lines <= st_bad_lines + 1'b1;
                    st_resyncs   <= st_resyncs + 1'b1;
                end
                if (line_last && have && lx0 && !s.eol) begin
                    // Line too long in the stream: drop the excess.
                    drain      <= D_TO_EOL;
                    st_resyncs <= st_resyncs + 1'b1;
                end
                if (pop_line && s.eol && !line_last) begin
                    // Line too short: the next word belongs to the next line.
                    line_ok      <= 1'b0;
                    st_bad_lines <= st_bad_lines + 1'b1;
                end
            end else if (pop_drain) begin
                if (drain == D_TO_EOL && s.eol)
                    drain <= D_NONE;
            end else if (drain == D_TO_SOF && s.valid && s.sof) begin
                drain <= D_NONE;
            end

            // A new raster frame: whatever is left of the last one goes.
            // Last, so it wins over the line bookkeeping above.
            if (frame_start && !(s.valid && s.sof))
                drain <= D_TO_SOF;
        end
    end
endmodule
