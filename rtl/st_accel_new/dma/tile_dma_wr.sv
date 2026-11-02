// tile_dma_wr.sv -- write a stream of AXI beats to a rectangle of DDR.
//
// On a start pulse: write `lines` lines of `beats_per_line` beats, line y at
// base_addr + y * line_stride.  The parameters are sampled at start.  Beats
// may arrive before start; they wait in the FIFO.  busy drops after the B
// response of the last burst, so the data is in DDR when busy falls.
//
// A burst is issued only when all of its beats are already in the FIFO, so W
// never waits on the input (the same rule as vdma_wr).  A burst never crosses
// a 4 KiB boundary.  The input's sof/eol tags are checked against the
// geometry; a mismatch is counted in err/st_err, the data is still written.
module tile_dma_wr
    import vid_pkg::*;
#(
    parameter int FIFO_BEATS = 512,      // power of two, >= WR_BURST
    parameter int WR_BURST   = 128
) (
    axi4_wr_if.mst              m,
    vstream_if.snk              i,       // one AXI beat per word

    input  logic                start,
    input  logic [AXI_AW-1:0]   base_addr,
    input  logic [15:0]         beats_per_line,
    input  logic [15:0]         lines,
    input  logic [AXI_AW-1:0]   line_stride,

    output logic                busy,
    output logic                err,     // tag mismatch or non-OKAY response
    output logic [SEQ_W-1:0]    st_done,
    output logic [SEQ_W-1:0]    st_err
);
    localparam int LW = $clog2(FIFO_BEATS);

    initial begin
        if (WR_BURST > FIFO_BEATS || WR_BURST > 256)
            $error("tile_dma_wr: burst does not fit the FIFO or AXI4");
    end

    // ---------------------------------------------------------- beat FIFO
    logic              f_valid, f_ready, f_sof, f_eol, f_full;
    logic [AXI_DW-1:0] f_data;
    logic [LW:0]       f_lvl;

    assign i.ready = !f_full;

    fifo_sync_core #(.W(AXI_DW + 2), .DEPTH(FIFO_BEATS)) u_fifo (
        .clk    (m.clk),   .rst_n  (m.rst_n),
        .wen    (i.valid && i.ready), .wdata ({i.sof, i.eol, i.data}), .wfull (f_full),
        .rready (f_ready), .rvalid (f_valid),
        .rdata  ({f_sof, f_eol, f_data}), .level (f_lvl));

    wire [LW+1:0] f_avail = (LW + 2)'(f_lvl) + (LW + 2)'(f_valid);

    // ------------------------------------------------------------ control
    typedef enum logic [2:0] { ST_IDLE, ST_PLAN, ST_AW, ST_DATA, ST_FIN } state_e;
    state_e state;

    logic [AXI_AW-1:0] lbase, stride;   // lbase: start of line y
    logic [15:0]       nb, nl, y, xb;
    logic [8:0]        n, bi;           // beats in the burst, sent so far
    logic [7:0]        b_out;           // bursts written, not yet acknowledged

    wire [AXI_AW-1:0] p_addr   = lbase + (AXI_AW'(xb) << $clog2(BEAT_BYTES));
    wire [15:0]       p_remain = nb - xb;
    wire [15:0]       p_page   = 16'((13'h1000 - {1'b0, p_addr[11:0]}) >> $clog2(BEAT_BYTES));
    wire [15:0]       p_n1     = (p_remain < 16'(WR_BURST)) ? p_remain : 16'(WR_BURST);
    wire [15:0]       p_n      = (p_page < p_n1) ? p_page : p_n1;

    wire w_free = !m.wvalid || m.wready;
    wire w_take = (state == ST_DATA) && f_valid && (bi != n) && w_free;
    wire w_done = (state == ST_DATA) && (bi == n) && (!m.wvalid || (m.wready && m.wlast));
    wire w_last = m.wvalid && m.wready && m.wlast;
    wire b_done = m.bvalid && m.bready;

    wire [15:0] beat_x  = xb + 16'(bi);
    wire        exp_sof = (y == 0) && (beat_x == 0);
    wire        exp_eol = (beat_x == nb - 16'd1);

    assign f_ready  = w_take;
    assign busy     = (state != ST_IDLE);
    assign m.awid   = '0;
    assign m.bready = 1'b1;

    always_ff @(posedge m.clk or negedge m.rst_n) begin
        if (!m.rst_n) begin
            state     <= ST_IDLE;
            err       <= 1'b0;
            lbase     <= '0;
            stride    <= '0;
            nb        <= '0;
            nl        <= '0;
            y         <= '0;
            xb        <= '0;
            n         <= '0;
            bi        <= '0;
            b_out     <= '0;
            m.awvalid <= 1'b0;
            m.awaddr  <= '0;
            m.awlen   <= '0;
            m.wvalid  <= 1'b0;
            m.wdata   <= '0;
            m.wlast   <= 1'b0;
            st_done   <= '0;
            st_err    <= '0;
        end else begin
            b_out <= b_out + (w_last ? 8'd1 : 8'd0) - (b_done ? 8'd1 : 8'd0);
            if (b_done && m.bresp != 2'b00) begin
                err    <= 1'b1;
                st_err <= st_err + 1'b1;
            end

            if (m.wvalid && m.wready)
                m.wvalid <= 1'b0;
            if (w_take) begin
                m.wvalid <= 1'b1;
                m.wdata  <= f_data;
                m.wlast  <= (bi == n - 9'd1);
                bi       <= bi + 9'd1;
                if (f_sof != exp_sof || f_eol != exp_eol) begin
                    err    <= 1'b1;
                    st_err <= st_err + 1'b1;
                end
            end

            unique case (state)
                ST_IDLE: if (start && beats_per_line != 0 && lines != 0) begin
                    err    <= 1'b0;
                    lbase  <= base_addr;
                    stride <= line_stride;
                    nb     <= beats_per_line;
                    nl     <= lines;
                    y      <= '0;
                    xb     <= '0;
                    state  <= ST_PLAN;
                end

                ST_PLAN: begin
                    if (y == nl) begin
                        state <= ST_FIN;
                    end else if (f_avail >= (LW + 2)'(p_n)) begin
                        m.awaddr  <= p_addr;
                        m.awlen   <= 8'(p_n - 16'd1);
                        m.awvalid <= 1'b1;
                        n         <= 9'(p_n);
                        bi        <= '0;
                        state     <= ST_AW;
                    end
                end

                ST_AW: if (m.awready) begin
                    m.awvalid <= 1'b0;
                    state     <= ST_DATA;
                end

                ST_DATA: if (w_done) begin
                    if (xb + 16'(n) == nb) begin
                        xb    <= '0;
                        y     <= y + 16'd1;
                        lbase <= lbase + stride;
                    end else begin
                        xb <= xb + 16'(n);
                    end
                    state <= ST_PLAN;
                end

                ST_FIN: if (b_out == 0 && !b_done) begin
                    st_done <= st_done + 1'b1;
                    state   <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
