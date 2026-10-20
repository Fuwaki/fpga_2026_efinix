// vid_testchk.sv -- checks frames read back by vdma_rd against test_word().
//
// The frame number comes from the reader's token (src_seq), latched when the
// sof word arrives, so every word of every frame is compared exactly.
module vid_testchk
    import vid_pkg::*;
(
    vstream_if.snk          s,
    input  frame_geom_t     geom,
    input  logic [15:0]     frame_id,     // src_seq of the frame being read
    output logic [15:0]     st_frames,    // frames checked without error
    output logic [15:0]     st_bad_frames,
    output logic [31:0]     st_bad_words,
    output logic [31:0]     st_first_bad, // first wrong word seen
    output logic [31:0]     st_last_bad,  // most recent wrong word
    output logic [31:0]     st_last_pos   // its expected {frame[7:0], line, word}
);
    logic [15:0] f;
    logic [11:0] y, w;
    logic        frame_bad;

    wire [11:0] wpl = 12'(geom.w / 13'd2);
    wire        is_sof = s.valid && s.sof;
    wire [15:0] cur_f = is_sof ? frame_id : f;
    wire [11:0] cur_y = is_sof ? '0 : y;
    wire [11:0] cur_w = is_sof ? '0 : w;
    wire        bad   = (s.data != test_word(cur_f, cur_y, cur_w))
                     || (s.eol != (cur_w == wpl - 1'b1));
    wire        fb    = is_sof ? 1'b0 : frame_bad;    // frame already bad before this word
    wire        eol_w = (cur_w == wpl - 1'b1);
    wire        eof_w = eol_w && (cur_y == 12'(geom.h) - 1'b1);

    assign s.ready = 1'b1;

    always_ff @(posedge s.clk or negedge s.rst_n) begin
        if (!s.rst_n) begin
            f             <= '0;
            y             <= '0;
            w             <= '0;
            frame_bad     <= 1'b0;
            st_frames     <= '0;
            st_bad_frames <= '0;
            st_bad_words  <= '0;
            st_first_bad  <= '0;
            st_last_bad   <= '0;
            st_last_pos   <= '0;
        end else if (s.valid) begin
            f         <= cur_f;
            w         <= eol_w ? '0 : cur_w + 1'b1;
            y         <= eof_w ? '0 : (eol_w ? cur_y + 1'b1 : cur_y);
            frame_bad <= eof_w ? 1'b0 : (fb || bad);
            if (bad) begin
                st_bad_words <= st_bad_words + 1'b1;
                if (st_bad_words == '0)
                    st_first_bad <= s.data;
                st_last_bad <= s.data;
                st_last_pos <= {cur_f[7:0], cur_y, cur_w};
            end
            if (eof_w) begin
                if (fb || bad)
                    st_bad_frames <= st_bad_frames + 1'b1;
                else
                    st_frames <= st_frames + 1'b1;
            end
        end
    end
endmodule
