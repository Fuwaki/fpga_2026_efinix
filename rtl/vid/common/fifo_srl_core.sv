// fifo_srl_core.sv -- single-clock FIFO in SRL cells, the same ports and
// first-word fall-through read side as fifo_sync_core.
//
// For short FIFOs the Titanium RAM10 is the wrong storage: a 16 x 43 FIFO
// costs two blocks (the width sets the count, the depth is free).  Here the
// words are a shift register with one asynchronous tap, the form Efinity maps
// to SRL8 cells (st_dw's column delay line): a write shifts every word one
// place and puts the new one at index 0, so the oldest stored word is at
// index count-1, and the read registers that tap into rdata.  A write and a
// read in the same cycle both use the words before the edge, so the read
// takes the old tap while the write shifts.
module fifo_srl_core #(
    parameter int W     = 16,
    parameter int DEPTH = 16,                  // power of two, >= 2
    parameter int AW    = $clog2(DEPTH)        // derived; do not override
) (
    input  logic          clk,
    input  logic          rst_n,

    input  logic          wen,
    input  logic [W-1:0]  wdata,
    output logic          wfull,

    input  logic          rready,
    output logic          rvalid,
    output logic [W-1:0]  rdata,

    // Words stored, not counting the one presented on rdata.
    output logic [AW:0]   level
);
    initial begin
        if (DEPTH != (1 << AW) || AW < 1)
            $error("fifo_srl_core: DEPTH must be a power of two >= 2");
    end

    logic [DEPTH-1:0][W-1:0] sr;
    logic [AW:0]             cnt;

    wire do_write = wen && !wfull;
    wire do_read  = (cnt != 0) && (!rvalid || rready);

    assign wfull = (cnt == (AW+1)'(DEPTH));
    assign level = cnt;

    // the oldest word: index cnt-1 (only read when cnt != 0)
    wire [AW-1:0] tap_i = AW'(cnt - 1'b1);
    wire [W-1:0]  tap   = sr[tap_i];

    always_ff @(posedge clk)
        if (do_write)
            sr <= {sr[DEPTH-2:0], wdata};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt    <= '0;
            rvalid <= 1'b0;
        end else begin
            cnt <= cnt + (AW+1)'(do_write) - (AW+1)'(do_read);
            if (do_read)
                rvalid <= 1'b1;
            else if (rready)
                rvalid <= 1'b0;
        end
    end

    always_ff @(posedge clk)
        if (do_read)
            rdata <= tap;

endmodule
