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
// within +-254).  Beats are taken one at a time as their last group leaves,
// so the beat register alone feeds every pixel -- there is no per-pixel
// buffer.
//
// cfg_hrep emits every pixel twice (the horizontal half of the 2x nearest
// upsample; the vertical half is tile_dma_rd's line_shift, so input and
// output line counts match).  The replay needs the pixel's beats again after
// the plain copy has consumed them, and in_ready blocks the next pixel until
// the replay is done, so the *last* beat is still in the beat register when
// the replay starts; only the pixel's first beat has to be kept, in a single
// 128-bit register b0 (written when the first beat of the pixel is taken).
// Groups of the first beat are therefore muxed from b0 during the replay and
// from the beat register otherwise.  This needs PB <= 32 -- at most two
// beats per pixel -- which is checked in simulation below; the guided net
// only upsamples p13 (24 int8 channels, 2 beats) and p19 (8 channels,
// 1 beat).  A wider pixel would replay the wrong beats, so cfg_hrep with
// cfg_pb > 32 is a configuration error, not a supported mode.
//
// Geometry: C <= 80 so G = ceil(C/4) <= 20 (a 5-bit group counter), PB <= 160
// so at most 10 beats per pixel (a 4-bit beat counter), W <= 640, H <= 360.
// Registers: 2 x 128 bits of beat data (beat, b0), the 40-bit output
// register and the counters -- about 420 flops, down from 1390 when the
// 10 x 128-bit pixel buffer and its 10:1 mux were still there.
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
    input  logic [6:0]    cfg_c,       // channels, 1..80
    input  logic          cfg_elem2,   // 1: int16 elements, 0: int8
    input  logic [7:0]    cfg_pb,      // pixel bytes, 16..160, multiple of 16
    input  logic [9:0]    cfg_w,       // source pixels per line
    input  logic [9:0]    cfg_h,       // lines
    input  logic          cfg_hrep,    // emit every pixel twice (needs PB <= 32)
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
    logic [127:0] beat;                // the pixel's current beat
    logic [127:0] b0;                  // its first beat, for the hrep replay
    logic [3:0]   bi;                  // next beat index within the pixel
    logic [4:0]   g;                   // next group of the pixel, 0..G-1
    logic         rep;                 // emitting the hrep copy from b0/beat
    logic [9:0]   x, y;
    logic         first;               // next group is the frame's first

    // Group g of the pixel lives in beat g/4 (g/2 for int16), sub-group
    // g%4 (g%2).  G <= 20 so the int16 beat index is g/2 <= 9 (4 bits) and
    // the int8 one is g/4 <= 4.
    wire  [1:0]   sub     = elem2 ? {1'b0, g[0]} : g[1:0];
    wire  [3:0]   gbeat   = elem2 ? g[4:1] : {1'b0, g[4:2]};
    wire          sub_end = elem2 ? g[0] : (g[1:0] == 2'd3);
    wire          pix_end = (g == gl);
    // Under hrep a pixel has at most two beats, so gbeat is 0 or 1 and its
    // low bit is g[1] (int16) / g[2] (int8).
    wire          b0_sel  = elem2 ? g[1] : g[2];
    wire          src_b0  = rep && !b0_sel;
    wire  [127:0] src     = src_b0 ? b0 : beat;

    logic [39:0]  grp;
    wire  [7:0]   ch = {1'b0, c};       // channel index bound, 8-bit to match 4g+j
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            logic [9:0] v;
            if (elem2)
                v = src[64*sub + 16*j +: 10];                        // halfword sub*4 + j
            else
                v = {{2{src[32*sub + 8*j + 7]}}, src[32*sub + 8*j +: 8]};
            grp[10*j +: 10] = ({1'b0, g, 2'(j)} < ch) ? v : 10'd0;
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
    // Index of the beat being taken: it restarts with a pixel that begins
    // this cycle.
    wire [3:0] widx = (consume && pix_end) ? 4'd0 : bi;

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
                    g <= g + 5'd1;
                end
                if (frame_end)
                    run <= 1'b0;
            end

            if (consume)
                have <= 1'b0;
            if (take) begin
                have <= 1'b1;
                beat <= in_data;
                // Only the first beat of an hrep pixel needs keeping: the
                // last one is still in `beat` when the replay starts.
                if (hrep && widx == 4'd0)
                    b0 <= in_data;
                bi   <= widx + 4'd1;
            end
        end
    end

`ifndef SYNTHESIS
    // The DMA's line boundary must fall on a pixel boundary of this geometry.
    logic [3:0] pbl;
    always_ff @(posedge clk) if (!busy && start) pbl <= 4'((cfg_pb >> 4) - 8'd1);
    always @(posedge clk)
        if (rst_n && take)
            if (in_eol && widx != pbl)
                $error("st_unpack: DMA eol on beat %0d of a %0d-beat pixel", widx, pbl + 1);
    // The hrep replay keeps one beat only, so the pixel must not be wider.
    always @(posedge clk)
        if (rst_n && !busy && start && cfg_hrep && cfg_pb > 8'd32)
            $error("st_unpack: cfg_hrep needs cfg_pb <= 32, got %0d", cfg_pb);
`endif

    logic unused;
    assign unused = in_sof;
endmodule
