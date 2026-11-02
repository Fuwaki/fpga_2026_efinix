// tile_dma_rd.sv -- read a rectangle of DDR as a stream of AXI beats.
//
// On a start pulse: read `lines` lines of `beats_per_line` beats, line y at
// base_addr + (y >> line_shift) * line_stride.  line_shift = 1 reads every
// source line twice (the vertical half of a 2x nearest upsample).  The
// parameters are sampled at start.  Output
// beats carry sof on the first beat and eol on the last beat of every line.
// A start while busy is ignored.
//
// Reads are issued against a credit budget the same way vdma_rd does it:
// beats in the FIFO + beats requested but not arrived + the new burst
// <= FIFO_BEATS, so R is always accepted at one beat per clock.  A burst never
// crosses a 4 KiB boundary.
module tile_dma_rd
    import vid_pkg::*;
#(
    parameter int FIFO_BEATS = 512,      // power of two
    parameter int RD_BURST   = 128       // beats per burst, <= FIFO_BEATS
) (
    axi4_rd_if.mst              m,
    vstream_if.src              o,       // one AXI beat per word

    input  logic                start,
    input  logic [AXI_AW-1:0]   base_addr,
    input  logic [15:0]         beats_per_line,
    input  logic [15:0]         lines,
    input  logic [AXI_AW-1:0]   line_stride,
    input  logic                line_shift,  // 1: each source line twice

    output logic                busy,    // until the last beat is in the FIFO
    output logic                err,     // a non-OKAY response in this transfer
    output logic [SEQ_W-1:0]    st_done,
    output logic [SEQ_W-1:0]    st_err
);
    localparam int LW = $clog2(FIFO_BEATS);

    initial begin
        if (RD_BURST > FIFO_BEATS || RD_BURST > 256)
            $error("tile_dma_rd: burst does not fit the FIFO or AXI4");
    end

    // ---------------------------------------------------------- beat FIFO
    logic              q_wen, q_full;
    logic [AXI_DW+1:0] q_wdata;          // {sof, eol, beat}
    logic [LW:0]       q_lvl;
    logic              b_valid, b_sof, b_eol;
    logic [AXI_DW-1:0] b_data;

    fifo_sync_core #(.W(AXI_DW + 2), .DEPTH(FIFO_BEATS)) u_fifo (
        .clk    (m.clk),   .rst_n  (m.rst_n),
        .wen    (q_wen),   .wdata  (q_wdata), .wfull (q_full),
        .rready (o.ready), .rvalid (b_valid),
        .rdata  ({b_sof, b_eol, b_data}),     .level (q_lvl));

    assign o.valid = b_valid;
    assign o.sof   = b_sof;
    assign o.eol   = b_eol;
    assign o.data  = b_data;

    // The beat on the output register still occupies a slot.
    wire [LW+1:0] q_used = (LW + 2)'(q_lvl) + (LW + 2)'(b_valid);

    // ------------------------------------------------------------ control
    logic [AXI_AW-1:0] lbase, stride;   // lbase: start of line y_q
    logic [15:0]       nb, nl;
    logic              shift;

    // Request side.
    logic [15:0]       y_q, xb_q;
    logic [LW+1:0]     inflight;         // beats requested, not yet in the FIFO
    // Receive side.
    logic [15:0]       y_r, xb_r;

    wire [AXI_AW-1:0] q_addr   = lbase + (AXI_AW'(xb_q) << $clog2(BEAT_BYTES));
    wire [15:0]       q_remain = nb - xb_q;
    wire [15:0]       q_page   = (16'h1000 - 16'(q_addr[11:0])) >> $clog2(BEAT_BYTES);
    wire [15:0]       q_n1     = (q_remain < 16'(RD_BURST)) ? q_remain : 16'(RD_BURST);
    wire [15:0]       q_n      = (q_page < q_n1) ? q_page : q_n1;
    wire              q_more   = busy && (y_q != nl);
    wire              credit   = (q_used + inflight + (LW + 2)'(q_n)) <= (LW + 2)'(FIFO_BEATS);
    wire              rx_done  = (y_r == nl);

    assign m.arid   = '0;
    assign m.rready = busy;              // credit guarantees FIFO room
    assign q_wen    = m.rvalid && m.rready;
    assign q_wdata  = {(y_r == 0) && (xb_r == 0), (xb_r == nb - 16'd1), m.rdata};

    logic unused_full;
    assign unused_full = q_full;

    always_ff @(posedge m.clk or negedge m.rst_n) begin
        if (!m.rst_n) begin
            busy      <= 1'b0;
            err       <= 1'b0;
            lbase     <= '0;
            stride    <= '0;
            nb        <= '0;
            nl        <= '0;
            shift     <= 1'b0;
            y_q       <= '0;
            xb_q      <= '0;
            y_r       <= '0;
            xb_r      <= '0;
            inflight  <= '0;
            m.arvalid <= 1'b0;
            m.araddr  <= '0;
            m.arlen   <= '0;
            st_done   <= '0;
            st_err    <= '0;
        end else begin
            inflight <= inflight
                      + ((m.arvalid && m.arready) ? (LW + 2)'(m.arlen) + 1'b1 : '0)
                      - (q_wen ? (LW + 2)'(1) : '0);

            if (q_wen) begin
                if (m.rresp != 2'b00) begin
                    err    <= 1'b1;
                    st_err <= st_err + 1'b1;
                end
                if (xb_r == nb - 16'd1) begin
                    xb_r <= '0;
                    y_r  <= y_r + 1'b1;
                end else begin
                    xb_r <= xb_r + 1'b1;
                end
            end

            if (!busy) begin
                if (start && beats_per_line != 0 && lines != 0) begin
                    busy   <= 1'b1;
                    err    <= 1'b0;
                    lbase  <= base_addr;
                    stride <= line_stride;
                    nb     <= beats_per_line;
                    nl     <= lines;
                    shift  <= line_shift;
                    y_q    <= '0;
                    xb_q   <= '0;
                    y_r    <= '0;
                    xb_r   <= '0;
                end
            end else begin
                if (m.arvalid) begin
                    if (m.arready)
                        m.arvalid <= 1'b0;
                end else if (q_more && credit) begin
                    m.araddr  <= q_addr;
                    m.arlen   <= 8'(q_n - 16'd1);
                    m.arvalid <= 1'b1;
                    if (xb_q + q_n == nb) begin
                        xb_q  <= '0;
                        y_q   <= y_q + 1'b1;
                        if (!shift || y_q[0])
                            lbase <= lbase + stride;
                    end else begin
                        xb_q <= xb_q + q_n;
                    end
                end
                if (rx_done && !m.arvalid) begin
                    busy    <= 1'b0;
                    st_done <= st_done + 1'b1;
                end
            end
        end
    end

endmodule
