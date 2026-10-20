// vstream_if.sv -- elastic pixel stream (valid/ready).
//
// Contract, checked by sva/vstream_sva.sv:
//   * A beat transfers on a clock edge where valid && ready.
//   * Once valid is high, valid, data, sof and eol hold until the beat
//     transfers.  ready may change freely.
//   * sof marks the first beat of a frame, eol the last beat of a line.  The
//     first beat of every line other than the first follows an eol.
//   * Each beat carries PPC elements of type T; element 0 is the leftmost.
//
// Producers that cannot stall (the camera) still use this interface; they
// count beats dropped while ready is low as an overflow instead of waiting.
interface vstream_if #(
    parameter type T   = logic [15:0],
    parameter int  PPC = 1
) (
    input logic clk,
    input logic rst_n
);
    logic         valid;
    logic         ready;
    logic         sof;
    logic         eol;
    T [PPC-1:0]   data;

    // One beat transfers this cycle.  A convenience for users; not every
    // instance reads it.
    /* verilator lint_off UNUSEDSIGNAL */
    wire xfer = valid && ready;
    /* verilator lint_on UNUSEDSIGNAL */

    modport src (input clk, rst_n, ready, output valid, sof, eol, data);
    modport snk (input clk, rst_n, valid, sof, eol, data, output ready);
    modport mon (input clk, rst_n, valid, ready, sof, eol, data);
endinterface
