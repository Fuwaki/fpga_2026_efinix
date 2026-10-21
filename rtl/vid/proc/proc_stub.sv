// proc_stub.sv -- placeholder for a frame-processing accelerator: a stream of
// RGB565 pixel pairs in, the same out, one pixel pair per clock, elastic.
//
//   PROC_PASS    copy
//   PROC_INVERT  every channel inverted
//
// A real accelerator replaces this module and keeps its ports: frames come
// in and go out framed by sof/eol, back-pressure in both directions.
module proc_stub
    import vid_pkg::*;
#(
    parameter proc_mode_e MODE = PROC_INVERT
) (
    vstream_if.snk   i,      // rgb565_t x 2
    vstream_if.src   o       // rgb565_t x 2
);
    function automatic rgb565_t op(input rgb565_t p);
        unique case (MODE)
            PROC_INVERT: return rgb565_t'(~p);
            default:     return p;
        endcase
    endfunction

    // One register stage, refilled whenever it is empty or being emptied.
    assign i.ready = !o.valid || o.ready;

    always_ff @(posedge i.clk or negedge i.rst_n) begin
        if (!i.rst_n) begin
            o.valid <= 1'b0;
            o.sof   <= 1'b0;
            o.eol   <= 1'b0;
            o.data  <= '0;
        end else if (i.ready) begin
            o.valid   <= i.valid;
            o.sof     <= i.sof;
            o.eol     <= i.eol;
            o.data[0] <= op(i.data[0]);
            o.data[1] <= op(i.data[1]);
        end
    end
endmodule
