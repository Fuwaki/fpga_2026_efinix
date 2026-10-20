// vpush_if.sv -- fixed-latency pixel stream (no back-pressure).
//
// Used inside pipelines whose stages have a fixed latency and cannot stall,
// which is every ISP stage (the demosaic line buffers advance on line
// boundaries, not on demand).  Same framing as vstream_if: sof marks the first
// beat of a frame, eol the last beat of a line, element 0 is leftmost.
//
// Extra contract, because the line-buffered stages need real blanking:
//   * After an eol there are at least MIN_GAP idle cycles before the next
//     valid beat.  line_release guarantees this at the head of the pipeline
//     and every stage preserves it (a fixed delay does not shorten gaps).
interface vpush_if #(
    parameter type T   = logic [15:0],
    parameter int  PPC = 1
) (
    input logic clk,
    input logic rst_n
);
    logic         valid;
    logic         sof;
    logic         eol;
    T [PPC-1:0]   data;

    modport src (input clk, rst_n, output valid, sof, eol, data);
    modport snk (input clk, rst_n, valid, sof, eol, data);
endinterface
