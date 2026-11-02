// tile_dma_wr.sv — AXI4 write master that drains a tile stream back to DDR.
//
// Accepts beats from a vstream_if source, buffers them in a FIFO, then
// issues AXI write bursts to reconstruct the tile in DDR at base_addr with
// line_stride bytes between rows. Mirrors the read-side contract:
//   sof on first beat, eol on last beat of every row.
// Issues WR_BURST-beat bursts or flushes the row when eol is seen.

module tile_dma_wr
    import vid_pkg::*;
#(
    parameter int FIFO_BEATS = 256,
    parameter int WR_BURST   = 64
) (
    axi4_wr_if.mst          m,
    vstream_if.snk          i,        // tile beats from tile_engine output

    input  logic                        flush,
    input  logic [AXI_AW-1:0]           base_addr,
    input  logic [15:0]                 beats_per_line,
    input  logic [15:0]                 lines,
    input  logic [AXI_AW-1:0]           line_stride,

    output logic                        busy,
    output logic [SEQ_W-1:0]            st_done,
    output logic [SEQ_W-1:0]            st_err
);
    localparam int LW = $clog2(FIFO_BEATS);

    initial begin
        if (WR_BURST > FIFO_BEATS) $error("tile_dma_wr: burst > FIFO depth");
    end

    // ─── Input FIFO ────────────────────────────────────────────────────────────
    logic [AXI_DW+1:0] q_wdata, q_rdata;
    logic              q_wen, q_full, q_ren, q_empty;
    logic [LW:0]       q_level;
    logic              f_sof, f_eol;
    logic [AXI_DW-1:0] f_data;

    fifo_sync_core #(.W(AXI_DW + 2), .DEPTH(FIFO_BEATS)) u_fifo (
        .clk    (m.clk),  .rst_n  (m.rst_n),
        .wen    (q_wen),  .wdata  (q_wdata), .wfull (q_full),
        .rready (q_ren),  .rvalid (),
        .rdata  (q_rdata),                   .level (q_level)
    );
    assign {f_sof, f_eol, f_data} = q_rdata;

    // Accept input when not full
    assign i.ready  = !q_full;
    assign q_wen    = i.valid && i.ready;
    assign q_wdata  = {i.sof, i.eol, i.data};

    // ─── Write address machine ─────────────────────────────────────────────────
    logic [AXI_AW-1:0] cur_addr;
    logic [15:0]        row_cnt, col_cnt, burst_rem, row_left;

    typedef enum logic [1:0] { IDLE, AW_PHASE, W_PHASE, B_PHASE } state_t;
    state_t state;

    logic [7:0]  burst_len;    // AXI len field for current burst
    logic [15:0] beat_cnt;     // beats written in current W phase

    always_ff @(posedge m.clk or negedge m.rst_n) begin
        if (!m.rst_n) begin
            state       <= IDLE;
            cur_addr    <= '0;
            row_cnt     <= '0;
            col_cnt     <= '0;
            burst_rem   <= '0;
            row_left    <= '0;
            burst_len   <= '0;
            beat_cnt    <= '0;
            busy        <= 1'b0;
            st_done     <= '0;
            st_err      <= '0;
            m.awvalid   <= 1'b0;
            m.awaddr    <= '0;
            m.awlen     <= '0;
            m.awid      <= '0;
            m.wvalid    <= 1'b0;
            m.wdata     <= '0;
            m.wlast     <= 1'b0;
            m.bready    <= 1'b1;
            q_ren       <= 1'b0;
        end else begin
            m.awvalid <= 1'b0;
            m.wvalid  <= 1'b0;
            m.wlast   <= 1'b0;
            q_ren     <= 1'b0;
            st_done   <= '0;

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (!q_empty) begin
                        cur_addr <= base_addr;
                        row_cnt  <= '0;
                        col_cnt  <= '0;
                        row_left <= beats_per_line;
                        busy     <= 1'b1;
                        state    <= AW_PHASE;
                    end
                end

                AW_PHASE: begin
                    if (!q_empty && q_level >= 1) begin
                        automatic logic [15:0] blen = (row_left < WR_BURST)
                                                     ? row_left : WR_BURST;
                        m.awvalid  <= 1'b1;
                        m.awaddr   <= cur_addr;
                        m.awlen    <= blen[7:0] - 8'd1;
                        burst_len  <= blen[7:0];
                        burst_rem  <= blen;
                        beat_cnt   <= '0;
                        if (m.awready) begin
                            state <= W_PHASE;
                        end
                    end
                end

                W_PHASE: begin
                    if (!q_empty && m.wready) begin
                        q_ren     <= 1'b1;
                        m.wvalid  <= 1'b1;
                        m.wdata   <= f_data;
                        beat_cnt  <= beat_cnt + 1;
                        col_cnt   <= col_cnt + 1;

                        if (beat_cnt == burst_rem - 1) begin
                            m.wlast   <= 1'b1;
                            row_left  <= row_left - burst_rem;
                            cur_addr  <= cur_addr
                                         + AXI_AW'(burst_rem) * AXI_AW'(BEAT_BYTES);
                            state     <= B_PHASE;
                        end

                        if (col_cnt + 1 == beats_per_line) begin
                            col_cnt  <= '0;
                            row_cnt  <= row_cnt + 1;
                            cur_addr <= base_addr
                                        + AXI_AW'(row_cnt + 1) * line_stride;
                            row_left <= beats_per_line;
                        end
                    end
                end

                B_PHASE: begin
                    m.bready <= 1'b1;
                    if (m.bvalid) begin
                        if (m.bresp != 2'b00) st_err <= st_err + 1;

                        if (row_cnt == lines) begin
                            st_done <= st_done + 1;
                            busy    <= 1'b0;
                            state   <= IDLE;
                        end else if (row_left == 0) begin
                            // row done, start next row
                            state <= AW_PHASE;
                        end else begin
                            // more beats in this row
                            state <= AW_PHASE;
                        end
                    end
                end
            endcase
        end
    end

endmodule
