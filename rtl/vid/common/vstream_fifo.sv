// vstream_fifo.sv -- vstream_if FIFOs, single- and dual-clock.
//
// The payload is {sof, eol, data}, sized from the connected interface, so the
// same module serves every pixel type.  Both interfaces must carry the same
// element type and PPC.

module vstream_fifo #(
    parameter int DEPTH = 512
) (
    vstream_if.snk           s,
    vstream_if.src           m,
    output logic [$clog2(DEPTH):0] level
);
    localparam int DW = $bits(s.data);

    initial begin
        if ($bits(m.data) != DW)
            $error("vstream_fifo: input and output streams differ in width");
    end

    logic          wfull;
    logic [DW+1:0] rword;

    fifo_sync_core #(.W(DW + 2), .DEPTH(DEPTH)) u_core (
        .clk    (s.clk),
        .rst_n  (s.rst_n),
        .wen    (s.valid),
        .wdata  ({s.sof, s.eol, s.data}),
        .wfull  (wfull),
        .rready (m.ready),
        .rvalid (m.valid),
        .rdata  (rword),
        .level  (level)
    );

    assign s.ready = !wfull;
    assign {m.sof, m.eol, m.data} = rword;
endmodule


module vstream_async_fifo #(
    parameter int DEPTH = 512
) (
    vstream_if.snk                 s,       // write side, s.clk
    vstream_if.src                 m,       // read side, m.clk
    output logic [$clog2(DEPTH):0] s_level,
    output logic [$clog2(DEPTH):0] m_level
);
    localparam int DW = $bits(s.data);

    initial begin
        if ($bits(m.data) != DW)
            $error("vstream_async_fifo: input and output streams differ in width");
    end

    logic          wfull;
    logic [DW+1:0] rword;

    fifo_async_core #(.W(DW + 2), .DEPTH(DEPTH)) u_core (
        .wclk   (s.clk),
        .wrst_n (s.rst_n),
        .wen    (s.valid),
        .wdata  ({s.sof, s.eol, s.data}),
        .wfull  (wfull),
        .wlevel (s_level),
        .rclk   (m.clk),
        .rrst_n (m.rst_n),
        .rready (m.ready),
        .rvalid (m.valid),
        .rdata  (rword),
        .rlevel (m_level)
    );

    assign s.ready = !wfull;
    assign {m.sof, m.eol, m.data} = rword;
endmodule
