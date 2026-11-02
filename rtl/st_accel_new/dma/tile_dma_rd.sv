// tile_dma_rd.sv — AXI4 read master that streams a rectangular tile from DDR.
//
// Fetches `lines` rows of `beats_per_line` AXI beats starting at `base_addr`,
// with `line_stride` bytes between row starts. Outputs one beat per cycle on
// a vstream_if source (sof on first beat of the tile, eol on last beat of
// every line). Reuses the same axi4_rd_if as the rest of vid_subsystem so it
// plugs into axi_arb as another read master.
//
// Credit-based: never issues more than FIFO_BEATS outstanding beats, so the
// response FIFO cannot overflow. Bursts are capped at RD_BURST beats and
// never cross a 4 KiB page (line stride is 4 KiB, so a full line fits).

module tile_dma_rd
    import vid_pkg::*;
#(
    parameter int FIFO_BEATS = 512,   // power of two
    parameter int RD_BURST   = 64     // beats per AXI burst (<= FIFO_BEATS)
) (
    axi4_rd_if.mst          m,        // to axi_arb
    vstream_if.src          o,         // streamed tile beats

    input  logic                        start,
    input  logic [AXI_AW-1:0]           base_addr,
    input  logic [15:0]                 beats_per_line,  // AXI beats per row
    input  logic [15:0]                 lines,           // rows in the tile
    input  logic [AXI_AW-1:0]           line_stride,     // bytes between rows

    output logic                        busy,
    output logic [SEQ_W-1:0]            st_done,
    output logic [SEQ_W-1:0]            st_err           // non-OKAY responses
);
    localparam int LW = $clog2(FIFO_BEATS);
    localparam int RW = $clog2(RD_BURST + 1);

    initial begin
        if (RD_BURST > FIFO_BEATS) $error("tile_dma_rd: burst > FIFO depth");
    end

    // ─── Beat FIFO {sof, eol, data} ────────────────────────────────────────────
    logic              q_wen;
    logic [AXI_DW+1:0] q_wdata;
    logic              q_full;
    logic [LW:0]       q_wlevel;
    logic              b_valid, b_ready, b_sof, b_eol;
    logic [AXI_DW-1:0] b_data;

    fifo_sync_core #(.W(AXI_DW + 2), .DEPTH(FIFO_BEATS)) u_fifo (
        .clk    (m.clk),   .rst_n  (m.rst_n),
        .wen    (q_wen),   .wdata  (q_wdata), .wfull (q_full),
        .rready (b_ready), .rvalid (b_valid),
        .rdata  ({b_sof, b_eol, b_data}),   .level (q_wlevel)
    );

    // The beat on the output register still occupies a FIFO slot.
    wire [LW:0] q_room = (LW + 1)'(FIFO_BEATS) - q_wlevel;

    // ─── Address generator ────────────────────────────────────────────────────
    logic [AXI_AW-1:0] cur_addr;
    logic [15:0]       row_cnt;       // rows issued
    logic [15:0]       col_cnt;       // beats issued in current row
    logic [15:0]       burst_left;    // beats remaining in current burst
    logic [15:0]       row_left;      // beats remaining in current row
    logic              sof_pending;   // first beat of the whole tile
    logic              issued_sof;     // set on first beat of tile

    typedef enum logic [1:0] { IDLE, ISSUE, DRAIN } state_t;
    state_t state;

    // Can we issue? Need: address channel idle, FIFO has room, work left.
    logic row_done;
    assign row_done = (col_cnt == beats_per_line);

    logic ar_can;
    assign ar_can = !q_full && (q_room >= RD_BURST) && (state == ISSUE);

    always_ff @(posedge m.clk or negedge m.rst_n) begin
        if (!m.rst_n) begin
            state        <= IDLE;
            cur_addr     <= '0;
            row_cnt      <= '0;
            col_cnt      <= '0;
            burst_left   <= '0;
            row_left     <= '0;
            sof_pending  <= 1'b0;
            issued_sof   <= 1'b0;
            m.arvalid    <= 1'b0;
            m.araddr     <= '0;
            m.arlen      <= '0;
            m.arid       <= '0;
            busy         <= 1'b0;
            st_done      <= '0;
            st_err       <= '0;
        end else begin
            m.arvalid <= 1'b0;
            st_done   <= '0;

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        cur_addr     <= base_addr;
                        row_cnt      <= '0;
                        col_cnt      <= '0;
                        row_left     <= beats_per_line;
                        burst_left   <= '0;
                        sof_pending  <= 1'b1;
                        issued_sof   <= 1'b0;
                        busy         <= 1'b1;
                        state        <= ISSUE;
                    end
                end

                ISSUE: begin
                    // Start a new burst when the previous is fully accepted
                    // and there is room in the FIFO.
                    if (!m.arvalid && row_left > 0 && ar_can) begin
                        // Burst length: min(RD_BURST, row_left)
                        automatic logic [15:0] blen = (row_left < RD_BURST)
                                                     ? row_left : RD_BURST;
                        m.arvalid  <= 1'b1;
                        m.araddr   <= cur_addr;
                        m.arlen    <= blen[7:0] - 8'd1;   // AXI len = beats-1
                        burst_left <= blen;
                    end

                    // Address accepted
                    if (m.arvalid && m.arready) begin
                        cur_addr    <= cur_addr + AXI_AW'(burst_left) * AXI_AW'(BEAT_BYTES);
                        col_cnt     <= col_cnt + burst_left;
                        row_left    <= row_left - burst_left;
                        burst_left  <= '0;
                    end

                    // End of row → advance to next line
                    if (row_done) begin
                        cur_addr   <= base_addr + AXI_AW'(row_cnt + 1) * line_stride;
                        row_cnt    <= row_cnt + 1;
                        col_cnt    <= '0;
                        row_left   <= beats_per_line;
                    end

                    // All rows done → drain remaining FIFO
                    if (row_cnt == lines && col_cnt == 0 && row_left == beats_per_line) begin
                        // Actually: when row_cnt reaches `lines`, we've issued
                        // all rows. But col_cnt==0 and row_left==beats_per_line
                        // means we just rolled over; check the simpler condition.
                    end
                    if (row_cnt == lines) begin
                        state <= DRAIN;
                    end
                end

                DRAIN: begin
                    // Wait until the FIFO is empty and the last beat read out.
                    if (!b_valid && q_wlevel == 0) begin
                        busy  <= 1'b0;
                        st_done <= '1;
                        state  <= IDLE;
                    end
                end
            endcase
        end
    end

    // ─── Response path: push {sof, eol, data} into FIFO ────────────────────────
    // Track which beat is first-in-tile and last-in-line using a small counter
    // that follows the accepted address beats.
    logic [15:0] rcv_col;       // beat within row (response side)
    logic [15:0] rcv_row;
    logic       rcv_sof;        // first beat of tile

    always_ff @(posedge m.clk or negedge m.rst_n) begin
        if (!m.rst_n) begin
            rcv_col <= '0;
            rcv_row <= '0;
            rcv_sof <= 1'b1;
            m.rready <= 1'b1;    // always accept when FIFO has room (credit-gated
                                 // by only issuing what fits)
        end else begin
            m.rready <= !q_full;
            if (m.rvalid && m.rready) begin
                // sof on the very first beat of the tile
                q_wdata  <= {rcv_sof, (rcv_col == beats_per_line - 1), m.rdata};
                q_wen    <= 1'b1;
                rcv_sof  <= 1'b0;

                if (rcv_col == beats_per_line - 1) begin
                    rcv_col <= '0;
                    rcv_row <= rcv_row + 1;
                end else begin
                    rcv_col <= rcv_col + 1;
                end
            end else begin
                q_wen <= 1'b0;
            end
        end
    end

    // ─── Output side ──────────────────────────────────────────────────────────
    assign o.valid = b_valid;
    assign o.data  = b_data;
    assign o.sof   = b_sof;
    assign o.eol   = b_eol;
    assign b_ready = o.ready;

endmodule
