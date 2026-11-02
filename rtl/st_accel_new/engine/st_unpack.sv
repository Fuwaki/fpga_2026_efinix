// st_unpack.sv -- DDR tensor beats -> group stream (ST block engine).
//
// Input: the 128-bit beats tile_dma_rd reads from a tensor region, one image
// line per DMA line (docs/st-accel-engine-adr.md, DDR tensor format): HWC,
// a pixel is PB = cfg_pb bytes = PB/16 beats, channel c at byte c*elem,
// little-endian.  Output: the group stream every engine stage uses -- per
// pixel G = ceil(C/4) beats of four 10-bit signed lanes, group 0 first,
// lanes beyond C zero, with last (last group of a pixel), eol (last beat of
// an output line) and sof (first beat of the frame).
//
// A group is 4 or 8 bytes and never straddles a beat, so groups are cut
// straight from the beat register: elem 1 gives 4 groups per beat, elem 2
// gives 2.  int16 elements keep their low 10 bits (the add outputs are
// within +-254).  The beats of the current pixel are also kept in a pixel
// buffer (8 x 128 bits); with cfg_hrep every pixel is emitted a second time
// from it -- the horizontal half of the 2x nearest upsample.  The vertical
// half is tile_dma_rd's line_shift, so input and output line counts match.
//
// Throughput: one group per cycle; a beat is taken in the cycle its
// predecessor's last group leaves.  Cycles per pixel: G (x2 with hrep), at
// least PB/16.
//
// Configuration is sampled on start while idle; busy stays high until the
// last group has been accepted downstream.
module st_unpack (
    input  logic          clk,
    input  logic          rst_n,

    input  logic          start,
    input  logic [6:0]    cfg_c,       // channels, 1..64
    input  logic          cfg_elem2,   // 1: int16 elements, 0: int8
    input  logic [7:0]    cfg_pb,      // pixel bytes, 16..128, multiple of 16
    input  logic [9:0]    cfg_w,       // source pixels per line
    input  logic [9:0]    cfg_h,       // lines
    input  logic          cfg_hrep,    // emit every pixel twice
    output logic          busy,

    input  logic          in_valid,
    output logic          in_ready,
    input  logic [127:0]  in_data,
    input  logic          in_sof,      // unused: the geometry is configured
    input  logic          in_eol,

    output logic          out_valid,
    input  logic          out_ready,
    output logic [39:0]   out_data,    // lane j = bits [10j+9:10j]
    output logic          out_last,
    output logic          out_eol,
    output logic          out_sof
);
    // ------------------------------------------------------------ config
    logic [6:0]   c;
    logic         elem2, hrep;
    logic [9:0]   w, h;
    logic [4:0]   gl;                  // G - 1

    // ------------------------------------------------------------- state
    logic         run;                 // groups still to emit
    logic         have;                // beat register holds a beat
    logic [127:0] beat;
    logic [127:0] pbuf [8];            // beats of the current pixel
    logic [2:0]   bi;                  // next beat index within the pixel
    logic [3:0]   g;                   // next group of the pixel
    logic         rep;                 // emitting the hrep copy from pbuf
    logic [9:0]   x, y;
    logic         first;               // next group is the frame's first

    // Group g of the pixel lives in beat g/4 (g/2 for int16), sub-group
    // g%4 (g%2).
    wire  [1:0]   sub     = elem2 ? {1'b0, g[0]} : g[1:0];
    wire  [2:0]   gbeat   = elem2 ? g[3:1] : {1'b0, g[3:2]};
    wire          sub_end = elem2 ? g[0] : (g[1:0] == 2'd3);
    wire          pix_end = ({1'b0, g} == gl);
    wire  [127:0] src     = rep ? pbuf[gbeat] : beat;

    logic [39:0]  grp;
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            logic [9:0] v;
            if (elem2)
                v = src[64*sub + 16*j +: 10];                        // halfword sub*4 + j
            else
                v = {{2{src[32*sub + 8*j + 7]}}, src[32*sub + 8*j +: 8]};
            grp[10*j +: 10] = ({1'b0, g, 2'(j)} < c) ? v : 10'd0;
        end
    end

    // A group leaves when the output register is free.
    wire can  = !out_valid || out_ready;
    wire emit = run && can && (rep || have);
    // Last copy of this pixel: the plain one without hrep, the replay with it.
    wire last_copy = rep || !hrep;
    wire line_end  = emit && pix_end && last_copy && (x == w - 10'd1);
    wire frame_end = line_end && (y == h - 10'd1);
    // The beat register frees when its last group leaves on the plain copy.
    wire consume   = emit && !rep && (sub_end || pix_end);

    assign in_ready = run && !rep && (!have || (consume && !(pix_end && hrep)))
                    && !frame_end;
    wire   take     = in_valid && in_ready;

    assign busy = run || out_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run       <= 1'b0;
            have      <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            if (!busy && start) begin
                c     <= cfg_c;
                elem2 <= cfg_elem2;
                hrep  <= cfg_hrep;
                w     <= cfg_w;
                h     <= cfg_h;
                gl    <= 5'((cfg_c + 7'd3) >> 2) - 5'd1;
                run   <= 1'b1;
                have  <= 1'b0;
                bi    <= '0;
                g     <= '0;
                rep   <= 1'b0;
                x     <= '0;
                y     <= '0;
                first <= 1'b1;
            end

            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (emit) begin
                out_valid <= 1'b1;
                out_data  <= grp;
                out_last  <= pix_end;
                out_eol   <= pix_end && last_copy && (x == w - 10'd1);
                out_sof   <= first;
                first     <= 1'b0;
                if (pix_end) begin
                    g <= '0;
                    if (!rep && hrep) begin
                        rep <= 1'b1;
                    end else begin
                        rep <= 1'b0;
                        bi  <= '0;
                        if (x == w - 10'd1) begin
                            x <= '0;
                            y <= y + 10'd1;
                        end else begin
                            x <= x + 10'd1;
                        end
                    end
                end else begin
                    g <= g + 4'd1;
                end
                if (frame_end)
                    run <= 1'b0;
            end

            if (consume)
                have <= 1'b0;
            if (take) begin
                have <= 1'b1;
                beat <= in_data;
                // The beat index restarts with a pixel that begins this cycle.
                pbuf[(consume && pix_end) ? 3'd0 : bi] <= in_data;
                bi   <= ((consume && pix_end) ? 3'd0 : bi) + 3'd1;
            end
        end
    end

`ifndef SYNTHESIS
    // The DMA's line boundary must fall on a pixel boundary of this geometry.
    logic [2:0] pbl;
    always_ff @(posedge clk) if (!busy && start) pbl <= 3'((cfg_pb >> 4) - 8'd1);
    always @(posedge clk)
        if (rst_n && take) begin
            automatic logic [2:0] idx = (consume && pix_end) ? 3'd0 : bi;
            if (in_eol && idx != pbl)
                $error("st_unpack: DMA eol on beat %0d of a %0d-beat pixel", idx, pbl + 1);
        end
`endif

    logic unused;
    assign unused = in_sof;
endmodule
