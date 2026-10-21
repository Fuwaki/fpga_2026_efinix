// proc_engine.sv -- DDR -> processing -> DDR: the slot an accelerator plugs
// into.
//
// Reads every new frame of the source ring (NEW_ONLY, so each camera frame is
// processed once), streams it through proc_stub and writes the result to its
// own ring.  The result carries the source frame's src_seq, so a consumer can
// tell which camera frame it came from.  The engine runs as fast as DDR lets
// it; with nothing new to read it polls the source ring every POLL cycles.
module proc_engine
    import vid_pkg::*;
#(
    parameter proc_mode_e MODE = PROC_INVERT,
    parameter int         POLL = 1024
) (
    axi4_rd_if.mst                  mr,
    axi4_wr_if.mst                  mw,
    ring_cons_if.user               src,
    ring_prod_if.user               dst,
    input  logic [AXI_AW-1:0]       src_base,
    input  logic [AXI_AW-1:0]       dst_base,

    output logic [SEQ_W-1:0]        st_frames,   // frames written
    output logic [SEQ_W-1:0]        st_miss,     // polls that found nothing new
    output logic [SEQ_W-1:0]        st_errors,   // writer aborts
    output logic [SEQ_W-1:0]        st_skipped   // no free slot in the result ring
);
    wire clk = mr.clk, rst_n = mr.rst_n;

    vstream_if #(.T(rgb565_t), .PPC(2)) a (.clk(clk), .rst_n(rst_n));
    vstream_if #(.T(rgb565_t), .PPC(2)) b (.clk(clk), .rst_n(rst_n));

    logic             rd_busy, rd_start;
    logic [15:0]      poll;
    frame_token_t     tok;
    logic [SEQ_W-1:0] rd_frames, rd_late;
    logic [31:0]      sig;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_start <= 1'b0;
            poll     <= '0;
        end else begin
            rd_start <= 1'b0;
            if (rd_busy || rd_start)
                poll <= 16'(POLL);
            else if (poll != 0)
                poll <= poll - 1'b1;
            else
                rd_start <= 1'b1;
        end
    end

    vdma_rd #(.FIFO_BEATS(512), .RD_BURST(128)) u_rd (
        .m(mr), .ring(src), .o(a),
        .ring_base(src_base), .start(rd_start), .policy(ACQ_NEW_ONLY), .geom(CAM_GEOM),
        .x0_beat(8'd0), .nbeats(8'(CAM_W / BEAT_PIX)),
        .busy(rd_busy), .token(tok),
        .st_frames(rd_frames), .st_miss(st_miss), .st_late(rd_late));

    proc_stub #(.MODE(MODE)) u_stub (.i(a), .o(b));

    vdma_wr #(.FIFO_BEATS(512)) u_wr (
        .s(b), .m(mw), .ring(dst),
        .ring_base(dst_base), .geom(CAM_GEOM), .src_seq(tok.src_seq),
        .st_frames(st_frames), .st_skipped(st_skipped), .st_errors(st_errors), .st_sig(sig));
endmodule
