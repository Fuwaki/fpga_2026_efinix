// vstream_bfm.sv -- stream source and checking sink for unit tests.
//
// The source emits frames of LINES x BEATS beats whose payload is a running
// beat counter (so any loss, duplication or reordering is visible), with a
// random gap pattern.  The sink applies random back-pressure and checks the
// counter and the sof/eol framing.  Both obey the vstream_if contract; the
// bound vstream_sva checks that too.

module vstream_rand_src #(
    parameter int VALID_PCT = 60,
    parameter int BEATS     = 8,
    parameter int LINES     = 4,
    parameter int FRAMES    = 4,
    parameter bit MISBEHAVE = 0     // withdraw offered beats: must trip vstream_sva
) (
    vstream_if.src m,
    output logic   done
);
    localparam int DW = $bits(m.data);
    longint unsigned n;
    int unsigned     x, y, f;

    always_ff @(posedge m.clk or negedge m.rst_n) begin
        if (!m.rst_n) begin
            m.valid <= 1'b0;
            m.sof   <= 1'b0;
            m.eol   <= 1'b0;
            m.data  <= '0;
            n <= 0; x <= 0; y <= 0; f <= 0;
            done <= 1'b0;
        end else begin
            if (m.valid && m.ready)
                m.valid <= 1'b0;
            if (MISBEHAVE && m.valid && !m.ready && $urandom_range(99) < 20)
                m.valid <= 1'b0;
            if ((!m.valid || m.ready) && f < FRAMES && $urandom_range(99) < VALID_PCT) begin
                m.valid <= 1'b1;
                m.data  <= DW'(n);
                m.sof   <= (x == 0 && y == 0);
                m.eol   <= (x == BEATS - 1);
                n <= n + 1;
                if (x == BEATS - 1) begin
                    x <= 0;
                    if (y == LINES - 1) begin
                        y <= 0;
                        f <= f + 1;
                    end else begin
                        y <= y + 1;
                    end
                end else begin
                    x <= x + 1;
                end
            end
            if (f == FRAMES && !(m.valid && !m.ready))
                done <= 1'b1;
        end
    end
endmodule


module vstream_check_sink #(
    parameter int READY_PCT = 60,
    parameter int BEATS     = 8,
    parameter int LINES     = 4
) (
    vstream_if.snk   s,
    output longint unsigned count,
    output int unsigned     errors
);
    localparam int DW = $bits(s.data);
    int unsigned x, y;

    always_ff @(posedge s.clk or negedge s.rst_n) begin
        if (!s.rst_n) begin
            s.ready <= 1'b0;
            count   <= 0;
            errors  <= 0;
            x <= 0; y <= 0;
        end else begin
            s.ready <= $urandom_range(99) < READY_PCT;
            if (s.valid && s.ready) begin
                if (s.data != DW'(count)) begin
                    errors <= errors + 1;
                    if (errors < 8)
                        $error("%m: beat %0d carries %0h", count, s.data);
                end
                if (s.sof != (x == 0 && y == 0) || s.eol != (x == BEATS - 1)) begin
                    errors <= errors + 1;
                    if (errors < 8)
                        $error("%m: framing wrong at beat %0d (x %0d y %0d sof %0b eol %0b)",
                               count, x, y, s.sof, s.eol);
                end
                count <= count + 1;
                if (x == BEATS - 1) begin
                    x <= 0;
                    y <= (y == LINES - 1) ? 0 : y + 1;
                end else begin
                    x <= x + 1;
                end
            end
        end
    end
endmodule
