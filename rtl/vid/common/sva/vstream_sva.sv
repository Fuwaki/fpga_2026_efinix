// vstream_sva.sv -- protocol checker for vstream_if, simulation only.
//
// Bound to every vstream_if instance by sim/bind/vid_bind.sv, so each stream
// in a testbench is checked without the RTL knowing about it.
module vstream_sva #(
    parameter int W = 16
) (
    input logic         clk,
    input logic         rst_n,
    input logic         valid,
    input logic         ready,
    input logic         sof,
    input logic         eol,
    input logic [W-1:0] data
);
    // Once offered, a beat must stay put until it is taken.
    a_hold: assert property (@(posedge clk) disable iff (!rst_n)
        valid && !ready |=> valid && $stable(data) && $stable(sof) && $stable(eol))
        else $error("%m: beat changed or withdrawn before transfer");

    // sof only on the first beat of a line, i.e. right after an eol (or the
    // first beat after reset).
    logic after_eol;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            after_eol <= 1'b1;
        else if (valid && ready)
            after_eol <= eol;
    end

    a_sof_at_line_start: assert property (@(posedge clk) disable iff (!rst_n)
        valid && sof |-> after_eol)
        else $error("%m: sof in the middle of a line");
endmodule
