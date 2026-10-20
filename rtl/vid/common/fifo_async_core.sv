// fifo_async_core.sv -- dual-clock FIFO, block-RAM storage, first-word
// fall-through read side.
//
// Pointers cross domains as Gray code through two-flop synchronisers
// (Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO
// Design").  The read side keeps the RAM's registered output as its output
// register: a word is fetched whenever the output is empty or being consumed,
// so rvalid/rdata behave like a stream source and sustain one word per clock.
//
// Levels are approximate in the far domain by the synchroniser delay, which is
// what flow control on them needs.
module fifo_async_core #(
    parameter int W     = 16,
    parameter int DEPTH = 512,                 // power of two, >= 4
    parameter int AW    = $clog2(DEPTH)        // derived; do not override
) (
    input  logic          wclk,
    input  logic          wrst_n,
    input  logic          wen,
    input  logic [W-1:0]  wdata,
    output logic          wfull,
    output logic [AW:0]   wlevel,

    input  logic          rclk,
    input  logic          rrst_n,
    input  logic          rready,
    output logic          rvalid,
    output logic [W-1:0]  rdata,
    output logic [AW:0]   rlevel
);
    initial begin
        if (DEPTH != (1 << AW) || AW < 2)
            $error("fifo_async_core: DEPTH must be a power of two >= 4");
    end

    // No reset on the array, so it maps to block RAM.
    logic [W-1:0] mem [DEPTH];

    function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
        return b ^ (b >> 1);
    endfunction

    function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
        logic [AW:0] b;
        b[AW] = g[AW];
        for (int i = AW - 1; i >= 0; i--)
            b[i] = b[i + 1] ^ g[i];
        return b;
    endfunction

    logic [AW:0] wbin, wgray;    // write pointer, write domain
    logic [AW:0] rbin, rgray;    // read pointer, read domain
    (* async_reg = "true" *) logic [AW:0] rgray_w1, rgray_w2;   // read ptr in write domain
    (* async_reg = "true" *) logic [AW:0] wgray_r1, wgray_r2;   // write ptr in read domain

    // ---------------------------------------------------------- write side

    wire do_write = wen && !wfull;

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin     <= '0;
            wgray    <= '0;
            rgray_w1 <= '0;
            rgray_w2 <= '0;
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
            if (do_write) begin
                wbin  <= wbin + 1'b1;
                wgray <= bin2gray(wbin + 1'b1);
            end
        end
    end

    always_ff @(posedge wclk) begin
        if (do_write)
            mem[wbin[AW-1:0]] <= wdata;
    end

    // Full when the write pointer has lapped the read pointer exactly once.
    assign wfull  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    assign wlevel = wbin - gray2bin(rgray_w2);

    // ----------------------------------------------------------- read side

    wire empty   = (rgray == wgray_r2);
    wire do_read = !empty && (!rvalid || rready);

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin     <= '0;
            rgray    <= '0;
            wgray_r1 <= '0;
            wgray_r2 <= '0;
            rvalid   <= 1'b0;
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
            if (do_read) begin
                rbin  <= rbin + 1'b1;
                rgray <= bin2gray(rbin + 1'b1);
            end
            if (do_read)
                rvalid <= 1'b1;
            else if (rready)
                rvalid <= 1'b0;
        end
    end

    always_ff @(posedge rclk) begin
        if (do_read)
            rdata <= mem[rbin[AW-1:0]];
    end

    assign rlevel = gray2bin(wgray_r2) - rbin;

endmodule
