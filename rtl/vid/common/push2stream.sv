// push2stream.sv -- a vpush_if source into a vstream_if sink, no buffering.
//
// A fixed-latency pipeline cannot wait, so a beat the sink cannot take is
// dropped and counted.  valid is only raised while ready is high, so every
// offered beat transfers at once and the vstream_if hold rule is kept.  The
// sink (vdma_wr) has its own FIFO and treats a frame with a missing beat as
// broken, so a drop costs that frame, never the alignment of the next.
module push2stream (
    vpush_if.snk          p,
    vstream_if.src        s,
    output logic [15:0]   st_dropped
);
    assign s.valid = p.valid && s.ready;
    assign s.sof   = p.sof;
    assign s.eol   = p.eol;
    assign s.data  = p.data;

    always_ff @(posedge p.clk or negedge p.rst_n)
        if (!p.rst_n)                    st_dropped <= '0;
        else if (p.valid && !s.ready)    st_dropped <= st_dropped + 1'b1;
endmodule
