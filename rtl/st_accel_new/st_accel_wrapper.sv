// st_accel_wrapper.sv -- the ST accelerator as the processing engine of the
// video subsystem (vid_subsystem PROC_EXT = 1).
//
// For each new frame of the ISP ring:
//   1. acquire the frame (NEW_ONLY) and a slot of the PROC ring;
//   2. pass 1: ISP slot -> rgb2yc -> scratch buffer in DDR (YC planes packed
//      per beat: 8 Y then 8 C);
//   3. release the ISP frame;
//   4. pass 2: scratch -> Y as gray RGB565 -> PROC slot;
//   5. commit the PROC slot with the ISP frame's src_seq (abort on a DMA
//      error).
// No frame in the ISP ring: retry after POLL cycles.  No free PROC slot: the
// ISP frame is released and counted as skipped.
//
// Pass 2 is the placeholder for the network's layer passes: they read and
// write scratch buffers with the same DMA pair.  This version proves the
// path: external AXI master, ring handshakes, DDR round trip through scratch.
module st_accel_wrapper
    import vid_pkg::*;
#(
    parameter logic [AXI_AW-1:0] SCRATCH_BASE = 32'h0800_0000,   // above the TEST ring
    parameter int                POLL         = 1024
) (
    input  logic clk,
    input  logic rst_n,

    // ─── AXI4 master (vid_subsystem ext_*) ──────────────────────────────────
    output logic [AXI_IW-1:0]  m_axi_awid,
    output logic [AXI_AW-1:0]  m_axi_awaddr,
    output logic [7:0]         m_axi_awlen,
    output logic               m_axi_awvalid,
    input  logic               m_axi_awready,
    output logic [AXI_DW-1:0]  m_axi_wdata,
    output logic               m_axi_wlast,
    output logic               m_axi_wvalid,
    input  logic               m_axi_wready,
    input  logic [AXI_IW-1:0]  m_axi_bid,
    input  logic [1:0]         m_axi_bresp,
    input  logic               m_axi_bvalid,
    output logic               m_axi_bready,
    output logic [AXI_IW-1:0]  m_axi_arid,
    output logic [AXI_AW-1:0]  m_axi_araddr,
    output logic [7:0]         m_axi_arlen,
    output logic               m_axi_arvalid,
    input  logic               m_axi_arready,
    input  logic [AXI_IW-1:0]  m_axi_rid,
    input  logic [AXI_DW-1:0]  m_axi_rdata,
    input  logic [1:0]         m_axi_rresp,
    input  logic               m_axi_rlast,
    input  logic               m_axi_rvalid,
    output logic               m_axi_rready,

    // ─── ISP ring, consumer side (vid_subsystem ext_src_*) ──────────────────
    output logic               src_req,
    output ring_c_op_e         src_op,
    input  logic               src_ack,
    input  logic               src_ok,
    input  frame_token_t       src_token,

    // ─── PROC ring, producer side (vid_subsystem ext_dst_*) ─────────────────
    output logic               dst_req,
    output ring_p_op_e         dst_op,
    output logic [SEQ_W-1:0]   dst_src_seq,
    input  logic               dst_ack,
    input  logic               dst_ok,
    input  logic [RING_SLOT_W-1:0] dst_slot,

    // ─── Status ─────────────────────────────────────────────────────────────
    output logic               busy,
    output logic [SEQ_W-1:0]   st_frames,    // PROC frames committed
    output logic [SEQ_W-1:0]   st_miss,      // polls with no new ISP frame
    output logic [SEQ_W-1:0]   st_errors,    // frames aborted on a DMA error
    output logic [SEQ_W-1:0]   st_skipped    // no free PROC slot
);

  // ==========================================================================
  // AXI interfaces
  // ==========================================================================
  axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mwr (.clk(clk), .rst_n(rst_n));
  axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mrd (.clk(clk), .rst_n(rst_n));

  assign m_axi_awid    = mwr.awid;
  assign m_axi_awaddr  = mwr.awaddr;
  assign m_axi_awlen   = mwr.awlen;
  assign m_axi_awvalid = mwr.awvalid;
  assign m_axi_wdata   = mwr.wdata;
  assign m_axi_wlast   = mwr.wlast;
  assign m_axi_wvalid  = mwr.wvalid;
  assign m_axi_bready  = mwr.bready;
  assign mwr.awready   = m_axi_awready;
  assign mwr.wready    = m_axi_wready;
  assign mwr.bid       = m_axi_bid;
  assign mwr.bresp     = m_axi_bresp;
  assign mwr.bvalid    = m_axi_bvalid;

  assign m_axi_arid    = mrd.arid;
  assign m_axi_araddr  = mrd.araddr;
  assign m_axi_arlen   = mrd.arlen;
  assign m_axi_arvalid = mrd.arvalid;
  assign m_axi_rready  = mrd.rready;
  assign mrd.arready   = m_axi_arready;
  assign mrd.rid       = m_axi_rid;
  assign mrd.rdata     = m_axi_rdata;
  assign mrd.rresp     = m_axi_rresp;
  assign mrd.rlast     = m_axi_rlast;
  assign mrd.rvalid    = m_axi_rvalid;

  // ==========================================================================
  // DMA pair and the per-pass beat transform
  // ==========================================================================
  localparam logic [15:0] BPL   = 16'(CAM_W / BEAT_PIX);
  localparam logic [15:0] LINES = 16'(CAM_H);

  vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_rd (.clk(clk), .rst_n(rst_n));
  vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_wr (.clk(clk), .rst_n(rst_n));

  logic              go;                // one-cycle start of both DMAs
  logic              pass2;             // 0: RGB565 -> YC, 1: YC -> gray RGB565
  logic [AXI_AW-1:0] rd_base, wr_base;
  logic              rd_busy, wr_busy, rd_err, wr_err;

  tile_dma_rd #(.FIFO_BEATS(512), .RD_BURST(128)) u_rd (
    .m(mrd), .o(s_rd),
    .start(go), .base_addr(rd_base), .beats_per_line(BPL), .lines(LINES),
    .line_stride(AXI_AW'(LINE_STRIDE)),
    .busy(rd_busy), .err(rd_err), .st_done(), .st_err());

  tile_dma_wr #(.FIFO_BEATS(512), .WR_BURST(128)) u_wr (
    .m(mwr), .i(s_wr),
    .start(go), .base_addr(wr_base), .beats_per_line(BPL), .lines(LINES),
    .line_stride(AXI_AW'(LINE_STRIDE)),
    .busy(wr_busy), .err(wr_err), .st_done(), .st_err());

  // Pass 1: rgb2yc (combinational, flow-through).
  logic [AXI_DW-1:0] yc_beat;
  logic              unused_yc_valid, unused_yc_sof, unused_yc_eol, unused_yc_ready;
  rgb2yc u_rgb2yc (
    .clk(clk), .rst_n(rst_n),
    .in_valid(s_rd.valid), .in_data(s_rd.data), .in_sof(s_rd.sof), .in_eol(s_rd.eol),
    .in_ready(unused_yc_ready),
    .out_valid(unused_yc_valid), .out_data(yc_beat), .out_sof(unused_yc_sof),
    .out_eol(unused_yc_eol), .out_ready(1'b1));

  // Pass 2: Y of pixel p is byte [127 - 8p -: 8]; show it as gray RGB565.
  // vstream_if data is T [PPC-1:0]; flatten before part-selecting bytes.
  logic [AXI_DW-1:0] rd_beat, gray_beat;
  assign rd_beat = s_rd.data;
  always_comb begin
    for (int p = 0; p < BEAT_PIX; p++) begin
      logic [7:0] y;
      y = rd_beat[127 - p*8 -: 8];
      gray_beat[p*16 +: 16] = {y[7:3], y[7:2], y[7:3]};
    end
  end

  assign s_wr.valid = s_rd.valid;
  assign s_wr.sof   = s_rd.sof;
  assign s_wr.eol   = s_rd.eol;
  assign s_wr.data  = pass2 ? gray_beat : yc_beat;
  assign s_rd.ready = s_wr.ready;

  // ==========================================================================
  // Frame sequencer
  // ==========================================================================
  typedef enum logic [3:0] {
    S_IDLE, S_SACQ, S_DACQ, S_P1, S_SREL, S_P2, S_FIN, S_SKIP
  } state_e;
  state_e state;

  logic [15:0]            poll;
  logic                   wait1;        // DMA busy flags valid from next cycle
  logic                   ferr;
  frame_token_t           tok;
  logic [RING_SLOT_W-1:0] slot;

  wire dma_idle = !wait1 && !go && !rd_busy && !wr_busy;

  assign busy = (state != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      poll        <= '0;
      wait1       <= 1'b0;
      ferr        <= 1'b0;
      tok         <= '0;
      slot        <= '0;
      go          <= 1'b0;
      pass2       <= 1'b0;
      rd_base     <= '0;
      wr_base     <= '0;
      src_req     <= 1'b0;
      src_op      <= RING_C_ACQ;
      dst_req     <= 1'b0;
      dst_op      <= RING_P_ACQ;
      dst_src_seq <= '0;
      st_frames   <= '0;
      st_miss     <= '0;
      st_errors   <= '0;
      st_skipped  <= '0;
    end else begin
      go    <= 1'b0;
      wait1 <= go;

      unique case (state)
        S_IDLE: begin
          if (poll != 0) begin
            poll <= poll - 1'b1;
          end else begin
            src_op  <= RING_C_ACQ;
            src_req <= 1'b1;
            state   <= S_SACQ;
          end
        end

        S_SACQ: if (src_ack) begin
          src_req <= 1'b0;
          if (src_ok) begin
            tok     <= src_token;
            dst_op  <= RING_P_ACQ;
            dst_req <= 1'b1;
            state   <= S_DACQ;
          end else begin
            st_miss <= st_miss + 1'b1;
            poll    <= 16'(POLL);
            state   <= S_IDLE;
          end
        end

        S_DACQ: if (dst_ack) begin
          dst_req <= 1'b0;
          if (dst_ok) begin
            slot    <= dst_slot;
            ferr    <= 1'b0;
            pass2   <= 1'b0;
            rd_base <= slot_base(RING_ISP_BASE, tok.slot);
            wr_base <= SCRATCH_BASE;
            go      <= 1'b1;
            state   <= S_P1;
          end else begin
            st_skipped <= st_skipped + 1'b1;
            src_op     <= RING_C_REL;
            src_req    <= 1'b1;
            state      <= S_SKIP;
          end
        end

        S_P1: if (dma_idle) begin
          ferr    <= rd_err || wr_err;
          src_op  <= RING_C_REL;
          src_req <= 1'b1;
          state   <= S_SREL;
        end

        S_SREL: if (src_ack) begin
          src_req <= 1'b0;
          pass2   <= 1'b1;
          rd_base <= SCRATCH_BASE;
          wr_base <= slot_base(RING_PROC_BASE, slot);
          go      <= 1'b1;
          state   <= S_P2;
        end

        S_P2: if (dma_idle) begin
          dst_op      <= (ferr || rd_err || wr_err) ? RING_P_ABORT : RING_P_COMMIT;
          dst_src_seq <= tok.src_seq;
          dst_req     <= 1'b1;
          state       <= S_FIN;
        end

        S_FIN: if (dst_ack) begin
          dst_req <= 1'b0;
          if (dst_op == RING_P_COMMIT) st_frames <= st_frames + 1'b1;
          else                         st_errors <= st_errors + 1'b1;
          state <= S_IDLE;
        end

        S_SKIP: if (src_ack) begin
          src_req <= 1'b0;
          poll    <= 16'(POLL);
          state   <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
