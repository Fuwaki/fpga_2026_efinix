// fifo_sync_core.sv -- single-clock FIFO, block-RAM storage, first-word
// fall-through read side.  Same read-side scheme as fifo_async_core: the
// RAM's registered output is the output register.
module fifo_sync_core #(
    parameter int W     = 16,
    parameter int DEPTH = 512,                 // power of two, >= 2
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
            $error("fifo_sync_core: DEPTH must be a power of two >= 2");
    end

    logic [W-1:0] mem [DEPTH];
    logic [AW:0]  wptr, rptr;

    wire empty    = (wptr == rptr);
    wire do_write = wen && !wfull;
    wire do_read  = !empty && (!rvalid || rready);

    assign wfull = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    assign level = wptr - rptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr   <= '0;
            rptr   <= '0;
            rvalid <= 1'b0;
        end else begin
            if (do_write)
                wptr <= wptr + 1'b1;
            if (do_read)
                rptr <= rptr + 1'b1;
            if (do_read)
                rvalid <= 1'b1;
            else if (rready)
                rvalid <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (do_write)
            mem[wptr[AW-1:0]] <= wdata;
        if (do_read)
            rdata <= mem[rptr[AW-1:0]];
    end

endmodule
