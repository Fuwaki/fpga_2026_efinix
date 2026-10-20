// layer_fetch.sv -- buffer the frame store's pixel stream for the raster.
//
// What this replaces was one state machine producing HDMI sync *and* the frame
// store's read enable, which forced the store's read rate to equal the display
// pixel rate exactly.  Here the raster only says which pixel is wanted; the
// store delivers at its own pace into a FIFO.
//
// Units: the store hands over 16-bit words of the raw Bayer stream (par2ser
// unpacks 128-bit AXI beats into 16-bit slices).  One word is two sensor
// pixels, so a 1920-pixel line is 960 words.  This module does not interpret
// the payload; debayer happens after it.
//
// A dry FIFO is not an error: black for that pixel, raster keeps running.
//
// Storage is a simple dual-port RAM with registered read, so it infers block
// RAM.  The registered read introduces one clock of latency between presenting
// an address and receiving its data; the read address is therefore issued one
// clock AHEAD of the pop, and the output stage aligns the word with the raster.
// Issuing address and pop together would fetch the NEXT word, rotating every
// line by one beat -- visible as a strip of the right edge appearing at the
// left edge.
module layer_fetch #(
    parameter int unsigned FIFO_DEPTH = 2048,
    parameter int unsigned DATA_W     = 16
) (
    input  logic              clk,
    input  logic              rst_n,

    // Frame boundary: empties the FIFO.  Held for the whole of vsync line 0,
    // after the previous frame's active area and before the store pushes the
    // next frame's first word.  Without it, any word left over from a frame
    // (start-up, a short or long frame) stays at the head forever: production
    // equals consumption per frame, so the surplus is never drained and every
    // line shows the previous line's last beat first.  data_tx did the same by
    // resetting its FIFO on the falling edge of fifo_rd_period.
    input  logic              flush,

    // raster
    input  logic              de,
    input  logic [11:0]       x,
    input  logic [11:0]       y,

    // active window in raster coordinates
    input  logic [11:0]       layer_x,
    input  logic [11:0]       layer_y,
    input  logic [11:0]       layer_w,   // in words
    input  logic [11:0]       layer_h,
    input  logic              layer_en,

    // upstream: words from the frame store, at the store's own rate
    input  logic              in_valid,
    input  logic [DATA_W-1:0] in_data,

    // downstream: one word per display clock
    output logic [DATA_W-1:0] out_data,
    output logic              out_valid,
    output logic              stall,

    // occupancy, for the producer's back-pressure
    output logic [11:0]       level
);

    localparam int unsigned AW = $clog2(FIFO_DEPTH);

    // ---------------------------------------------------------------- memory
    // No reset on the array: resetting it would force the synthesizer to build
    // it from registers instead of RAM.
    logic [DATA_W-1:0] mem [FIFO_DEPTH];

    logic [AW-1:0] wr_ptr, rd_ptr;
    logic [AW:0]   count;

    wire full  = (count == FIFO_DEPTH[AW:0]);
    wire empty = (count == '0);

    logic in_window;
    always_comb begin
        in_window = layer_en &&
                    (x >= layer_x) && (x < layer_x + layer_w) &&
                    (y >= layer_y) && (y < layer_y + layer_h);
    end

    // Flush is consumed as a single-cycle event: it clears the pointers once
    // and must not gate push/pop for a whole line.  Gating for the full line
    // would block the display while it is already able to show pixels.
    wire push = in_valid && !full;

    // The raster wants a word only inside the window, and only when one exists.
    wire want = de && in_window;
    wire pop  = want && !empty;

    // ------------------------------------------------------------- pointers
    // Clear on the leading edge of flush only.  flush is asserted for a whole
    // line (vc == 0), and holding the pointers at zero for that long would
    // stall the display for a line it could otherwise draw.
    logic flush_d;
    wire  flush_pulse = flush & ~flush_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            flush_d <= 1'b0;
        else
            flush_d <= flush;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else if (flush_pulse) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (push)
                wr_ptr <= wr_ptr + 1'b1;
            if (pop)
                rd_ptr <= rd_ptr + 1'b1;

            case ({push, pop})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

    // ----------------------------------------------------------- RAM access
    // `rd_ptr` is the word being consumed this cycle, so it is the correct
    // address to present now.  The RAM returns that word on the next clock,
    // and the output stage delays the valid flag by the same single clock, so
    // data and valid stay together.  Driving the address from a delayed copy
    // of the pointer instead would fetch the following word and rotate the
    // line by one beat.
    logic [DATA_W-1:0] rd_data;

    always_ff @(posedge clk) begin
        if (push)
            mem[wr_ptr] <= in_data;
    end

    always_ff @(posedge clk) begin
        rd_data <= mem[rd_ptr];
    end

    // Valid flag for the word arriving from the RAM.  rd_data and valid_q are
    // both one clock behind the pop, so they are already aligned: adding a
    // second register on the data path alone would lag it one clock behind its
    // own valid flag and shift the picture.
    logic valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_q <= 1'b0;
        else
            valid_q <= pop;
    end

    // Outside the window the reader still clocks, but the word must not leak
    // through: a stale RAM output would smear the previous line into the
    // border.  valid_q marks "a word was popped last cycle", which is exactly
    // the word rd_data is presenting now, so it is the right gate -- gating on
    // in_window instead would be one position ahead and drop the last word of
    // every line.
    assign out_data  = valid_q ? rd_data : '0;
    assign out_valid = valid_q;
    assign stall     = want && empty;
    assign level     = count[11:0];

endmodule
