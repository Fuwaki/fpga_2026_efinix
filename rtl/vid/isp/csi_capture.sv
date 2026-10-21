// csi_capture.sv -- CSI-2 RX pixel port to a framed word stream, in the CSI
// pixel clock, written into a dual-clock FIFO (the ISP runs in core_clk).
//
// The RX delivers 4 RAW10 pixels per clock (p0, the leftmost, in bits [9:0])
// while vs/hs mark the frame and the line; a beat is valid when de && hs.
// Every beat is kept: the FIFO write is the only place a pixel can be lost,
// and losses are counted, never hidden.
//
// Framing: sof on the first beat after vs rises, eol on the last beat of a
// line.  The last beat is only known when hs falls, so each beat is held one
// beat and written when the next one arrives or the line ends.
//
// PATTERN = 1 replaces the pixels (not the timing) with a fixed picture,
// raw = (x[9:0] ^ {y[6:0], 3'b000}) + y, so the ISP output is predictable on
// the board; see capture_pattern() in sim/ref/isp_ref.py.
module csi_capture
    import vid_pkg::*;
#(
    parameter bit PATTERN = 0
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 vs,
    input  logic                 hs,
    input  logic                 de,
    input  logic [39:0]          data,

    // FIFO write port: {sof, eol, 4 pixels}
    output logic                 wen,
    output logic [41:0]          wdata,
    input  logic                 wfull,

    output logic [SEQ_W-1:0]     st_frames,    // vs rising edges
    output logic [15:0]          st_lines,     // lines in the last complete frame
    output logic [15:0]          st_beats,     // beats in the last line
    output logic [15:0]          st_dropped    // beats lost to a full FIFO
);
    logic        vs_d, hs_d;
    logic        sof_pend;
    logic        h_v, h_sof;          // the held beat
    logic [39:0] h_data;
    logic [15:0] lines, beats;
    logic [11:0] px;                  // pattern: x of p0
    logic [11:0] py;

    wire beat   = de && hs;
    wire vs_up  = vs && !vs_d;
    wire hs_end = hs_d && !hs;

    // Pattern pixel at (x, y).
    function automatic logic [9:0] pat(input logic [11:0] x, input logic [11:0] y);
        return (x[9:0] ^ {y[6:0], 3'b000}) + y[9:0];
    endfunction

    logic [39:0] in_data;
    always_comb begin
        in_data = data;
        if (PATTERN)
            for (int i = 0; i < 4; i++)
                in_data[10*i +: 10] = pat(px + 12'(i), py);
    end

    // One write per cycle at most: a held beat is written either because a
    // new beat arrived (hs high) or because the line ended (hs low).
    logic        w_req, w_eol;
    always_comb begin
        w_req = h_v && (beat || hs_end);
        w_eol = !beat;
    end

    assign wen   = w_req && !wfull;
    assign wdata = {h_sof, w_eol, h_data};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d       <= 1'b0;
            hs_d       <= 1'b0;
            sof_pend   <= 1'b0;
            h_v        <= 1'b0;
            h_sof      <= 1'b0;
            h_data     <= '0;
            lines      <= '0;
            beats      <= '0;
            px         <= '0;
            py         <= '0;
            st_frames  <= '0;
            st_lines   <= '0;
            st_beats   <= '0;
            st_dropped <= '0;
        end else begin
            vs_d <= vs;
            hs_d <= hs;

            if (vs_up) begin
                sof_pend  <= 1'b1;
                st_frames <= st_frames + 1'b1;
                st_lines  <= lines;
                lines     <= '0;
                py        <= '0;
            end

            if (w_req && wfull)
                st_dropped <= st_dropped + 1'b1;

            if (beat) begin
                h_v      <= 1'b1;
                h_sof    <= sof_pend && !vs_up;
                h_data   <= in_data;
                if (!vs_up)
                    sof_pend <= 1'b0;
                beats    <= beats + 1'b1;
                px       <= px + 12'd4;
            end else if (hs_end) begin
                h_v      <= 1'b0;
                st_beats <= beats;
                beats    <= '0;
                px       <= '0;
                if (h_v && !vs_up) begin
                    lines <= lines + 1'b1;
                    py    <= py + 1'b1;
                end
            end
        end
    end

endmodule
