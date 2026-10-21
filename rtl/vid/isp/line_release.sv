// line_release.sv -- moves capture words from the CSI pixel clock into the
// core clock and releases them one whole line at a time.
//
// The ISP stages are fixed-latency (vpush_if) and their line buffers need
// every line to arrive as one unbroken run followed by real blanking.  The CSI
// side has neither guarantee: the receiver may pause inside a line.  So a line
// is only released once its last word (eol) is in the FIFO, then it streams
// out at 2 pixels per clock without a hole, followed by at least MIN_GAP idle
// cycles.
//
// Rates: 4 px at 50 MHz in, 2 px at 100 MHz out, so a line leaves as fast as
// it arrives and the FIFO holds about one line.  A line takes 640 clocks to
// leave and the sensor sends one every ~1600, so the gap costs nothing.
//
// Complete lines are counted across the clock domains with a Gray-coded eol
// counter.  It is synchronised through two extra flops so it never overtakes
// the FIFO's own write pointer, which crosses through the usual two.
module line_release
    import vid_pkg::*;
#(
    parameter int DEPTH   = 512,     // words of 4 pixels; one line is CAM_W / 4
    parameter int MIN_GAP = 16
) (
    // capture side
    input  logic          wclk,
    input  logic          wrst_n,
    input  logic          wen,
    input  logic [41:0]   wdata,     // {sof, eol, p3 .. p0}
    output logic          wfull,

    // core side
    vpush_if.src          o,         // raw10_t, PPC 2
    output logic [15:0]   st_holes   // times a released line found the FIFO empty
);
    localparam int LW = $clog2(DEPTH);

    // ---------------------------------------------------------------- FIFO
    logic          f_rvalid, f_rready;
    logic [41:0]   f_rdata;
    logic [LW:0]   unused_wlevel, unused_rlevel;

    fifo_async_core #(.W(42), .DEPTH(DEPTH)) u_fifo (
        .wclk(wclk), .wrst_n(wrst_n), .wen(wen), .wdata(wdata), .wfull(wfull), .wlevel(unused_wlevel),
        .rclk(o.clk), .rrst_n(o.rst_n), .rready(f_rready), .rvalid(f_rvalid), .rdata(f_rdata),
        .rlevel(unused_rlevel));

    // ------------------------------------------------- complete-line count
    logic [3:0] eol_w, eol_w_gray;
    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            eol_w      <= '0;
            eol_w_gray <= '0;
        end else if (wen && !wfull && wdata[40]) begin
            eol_w      <= eol_w + 1'b1;
            eol_w_gray <= (eol_w + 1'b1) ^ ((eol_w + 1'b1) >> 1);
        end
    end

    (* async_reg = "true" *) logic [3:0] eol_s1, eol_s2;
    logic [3:0] eol_s3, eol_s4;
    logic [3:0] eol_r;               // eol words released so far
    logic [3:0] eol_in;              // eol words known to be in the FIFO

    function automatic logic [3:0] g2b(input logic [3:0] g);
        return {g[3], g[3] ^ g[2], g[3] ^ g[2] ^ g[1], g[3] ^ g[2] ^ g[1] ^ g[0]};
    endfunction

    always_ff @(posedge o.clk or negedge o.rst_n) begin
        if (!o.rst_n) begin
            eol_s1 <= '0; eol_s2 <= '0; eol_s3 <= '0; eol_s4 <= '0;
            eol_in <= '0;
        end else begin
            eol_s1 <= eol_w_gray;
            eol_s2 <= eol_s1;
            eol_s3 <= eol_s2;
            eol_s4 <= eol_s3;
            eol_in <= g2b(eol_s4);
        end
    end

    wire line_ready = (eol_in != eol_r);

    // ------------------------------------------------------------- release
    typedef enum logic { ST_GAP, ST_RUN } state_e;
    state_e      state;
    logic        half;               // 0: pixels 0-1 of the head word, 1: pixels 2-3
    logic [7:0]  gap;

    wire take = (state == ST_RUN) && f_rvalid;
    assign f_rready = take && half;

    always_ff @(posedge o.clk or negedge o.rst_n) begin
        if (!o.rst_n) begin
            state    <= ST_GAP;
            half     <= 1'b0;
            gap      <= '0;
            eol_r    <= '0;
            o.valid  <= 1'b0;
            o.sof    <= 1'b0;
            o.eol    <= 1'b0;
            o.data   <= '0;
            st_holes <= '0;
        end else begin
            o.valid <= 1'b0;
            o.sof   <= 1'b0;
            o.eol   <= 1'b0;
            unique case (state)
                ST_GAP: begin
                    if (gap != 0)
                        gap <= gap - 1'b1;
                    else if (line_ready) begin
                        state <= ST_RUN;
                        half  <= 1'b0;
                    end
                end
                ST_RUN: begin
                    if (!f_rvalid) begin
                        // Cannot happen while the eol count trails the write
                        // pointer; counted in case it does.
                        st_holes <= st_holes + 1'b1;
                    end else begin
                        o.valid   <= 1'b1;
                        o.data[0] <= half ? f_rdata[29:20] : f_rdata[9:0];
                        o.data[1] <= half ? f_rdata[39:30] : f_rdata[19:10];
                        o.sof     <= !half && f_rdata[41];
                        o.eol     <= half && f_rdata[40];
                        half      <= !half;
                        if (half && f_rdata[40]) begin
                            eol_r <= eol_r + 1'b1;
                            gap   <= 8'(MIN_GAP);
                            state <= ST_GAP;
                        end
                    end
                end
                default: state <= ST_GAP;
            endcase
        end
    end

endmodule
