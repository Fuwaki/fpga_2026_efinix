// st_pack.sv -- group stream -> DDR tensor beats (ST block engine).
//
// The inverse of st_unpack.  Input: group beats (four 10-bit signed lanes,
// G = ceil(C/4) per pixel, last on the pixel's final group, eol on the
// line's final beat).  Output: the 128-bit beats tile_dma_wr writes into a
// tensor region (docs/st-accel-engine-adr.md): HWC, channel c at byte
// c*elem, int8 (low 8 bits of the lane) or int16 (the lane sign-extended),
// little-endian, padding bytes zero.  sof is on the frame's first beat and
// eol on each line's last beat, which is what tile_dma_wr checks.
//
// A group is 4 or 8 bytes and never straddles a beat: groups fill a beat
// register (4 per beat for int8, 2 for int16) and the beat goes out when it
// is full or the pixel ends.  One group per cycle.
//
// Geometry: C <= 80 so G = ceil(C/4) <= 20 (a 5-bit group counter) and an
// int16 pixel is at most 160 bytes (10 beats); W <= 640, H <= 360.  Padding
// bytes stay zero: the beat register starts cleared and only lanes below C
// are ever written.
//
// Configuration is sampled on start while idle; busy stays high until the
// frame's last beat has been accepted downstream.
module st_pack (
    input  logic          clk,
    input  logic          rst_n,

    input  logic          start,
    input  logic [6:0]    cfg_c,       // channels, 1..80
    input  logic          cfg_elem2,   // 1: int16 elements, 0: int8
    input  logic [9:0]    cfg_h,       // lines
    output logic          busy,

    input  logic          in_valid,
    output logic          in_ready,
    input  logic [39:0]   in_data,
    input  logic          in_last,
    input  logic          in_eol,
    input  logic          in_sof,      // unused: the frame starts at start

    output logic          out_valid,
    input  logic          out_ready,
    output logic [127:0]  out_data,
    output logic          out_sof,
    output logic          out_eol
);
    logic [6:0]   c;
    logic         elem2;
    logic [9:0]   h, y;
    logic         run, first;
    logic [4:0]   g;                   // group of the pixel, 0..G-1
    logic [127:0] acc;                 // beat being filled

    wire  [1:0]   sub     = elem2 ? {1'b0, g[0]} : g[1:0];
    wire          sub_end = elem2 ? g[0] : (g[1:0] == 2'd3);

    // The incoming group placed into the beat being filled.
    logic [127:0] fill;
    wire  [7:0]   ch = {1'b0, c};       // channel index bound, 8-bit to match 4g+j
    always_comb begin
        fill = acc;
        for (int j = 0; j < 4; j++) begin
            logic [9:0] v;
            v = ({1'b0, g, 2'(j)} < ch) ? in_data[10*j +: 10] : 10'd0;
            if (elem2)
                fill[64*sub + 16*j +: 16] = {{6{v[9]}}, v};
            else
                fill[32*sub + 8*j +: 8]   = v[7:0];
        end
    end

    wire done_beat = in_last || sub_end;
    wire can       = !out_valid || out_ready;
    assign in_ready = run && (!done_beat || can);
    wire   take     = in_valid && in_ready;

    assign busy = run || out_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run       <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            if (!busy && start) begin
                c     <= cfg_c;
                elem2 <= cfg_elem2;
                h     <= cfg_h;
                y     <= '0;
                g     <= '0;
                acc   <= '0;
                first <= 1'b1;
                run   <= 1'b1;
            end

            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (take) begin
                g <= in_last ? 5'd0 : g + 5'd1;
                if (done_beat) begin
                    out_valid <= 1'b1;
                    out_data  <= fill;
                    out_sof   <= first;
                    out_eol   <= in_last && in_eol;
                    first     <= 1'b0;
                    acc       <= '0;
                    if (in_last && in_eol) begin
                        y <= y + 10'd1;
                        if (y == h - 10'd1)
                            run <= 1'b0;
                    end
                end else begin
                    acc <= fill;
                end
            end
        end
    end

    logic unused;
    assign unused = in_sof;
endmodule
