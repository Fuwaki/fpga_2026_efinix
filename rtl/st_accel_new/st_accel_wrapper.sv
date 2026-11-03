// st_accel_wrapper.sv -- the ST accelerator as the processing engine of the
// video subsystem (vid_subsystem PROC_EXT = 1).
//
// For each new frame of the ISP ring:
//   1. acquire the frame (NEW_ONLY) and a slot of the PROC ring;
//   2. run st_engine: the style network as DDR passes, the first two reading the
//      ISP slot, the last writing the whole PROC slot
//      (docs/st-accel-engine-adr.md);
//   3. release the ISP frame as soon as pre_done rises, while the network
//      passes still run;
//   4. commit the PROC slot with the ISP frame's src_seq (abort on a DMA or
//      framing error).
// No frame in the ISP ring: retry after POLL cycles.  No free PROC slot: the
// ISP frame is released and counted as skipped.  st_cycles is the engine
// time of the last frame.
module st_accel_wrapper
    import vid_pkg::*;
#(
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

    // ─── Style packet (ui_regs MENU style, same clock), sampled per frame ───
    input  logic [1:0]         style,

    // ─── Status ─────────────────────────────────────────────────────────────
    output logic               busy,
    output logic [SEQ_W-1:0]   st_frames,    // PROC frames committed
    output logic [SEQ_W-1:0]   st_miss,      // polls with no new ISP frame
    output logic [SEQ_W-1:0]   st_errors,    // frames aborted on a DMA error
    output logic [SEQ_W-1:0]   st_skipped,   // no free PROC slot
    output logic [31:0]        st_cycles     // engine cycles of the last frame
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
  // Block engine
  // ==========================================================================
  logic              eng_go, eng_busy, eng_pre_done, eng_err;
  logic [AXI_AW-1:0] isp_base, proc_base;
  logic [3:0]        unused_pass;

  st_engine u_engine (
    .clk(clk), .rst_n(rst_n), .m_wr(mwr), .m_rd(mrd),
    .start(eng_go), .isp_base(isp_base), .proc_base(proc_base),
    .first_pass(4'd0), .last_pass(4'(st_net_pkg::ST_N_PASSES - 1)), .style(style),
    .busy(eng_busy), .pre_done(eng_pre_done), .err(eng_err),
    .pass(unused_pass), .cycles(st_cycles));

  // ==========================================================================
  // Frame sequencer
  // ==========================================================================
  typedef enum logic [3:0] {
    S_IDLE, S_SACQ, S_DACQ, S_RUN, S_SREL, S_WAIT, S_FIN, S_SKIP
  } state_e;
  state_e state;

  logic [15:0]            poll;
  logic                   wait1;        // engine busy is valid from next cycle
  frame_token_t           tok;
  logic [RING_SLOT_W-1:0] slot;

  wire eng_idle = !wait1 && !eng_go && !eng_busy;

  assign busy = (state != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      poll        <= '0;
      wait1       <= 1'b0;
      tok         <= '0;
      slot        <= '0;
      eng_go      <= 1'b0;
      isp_base    <= '0;
      proc_base   <= '0;
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
      eng_go <= 1'b0;
      wait1  <= eng_go;

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
            slot      <= dst_slot;
            isp_base  <= slot_base(RING_ISP_BASE, tok.slot);
            proc_base <= slot_base(RING_PROC_BASE, dst_slot);
            eng_go    <= 1'b1;
            state     <= S_RUN;
          end else begin
            st_skipped <= st_skipped + 1'b1;
            src_op     <= RING_C_REL;
            src_req    <= 1'b1;
            state      <= S_SKIP;
          end
        end

        // pre_done: the ISP slot is no longer read
        S_RUN: if (!wait1 && !eng_go && (eng_pre_done || !eng_busy)) begin
          src_op  <= RING_C_REL;
          src_req <= 1'b1;
          state   <= S_SREL;
        end

        S_SREL: if (src_ack) begin
          src_req <= 1'b0;
          state   <= S_WAIT;
        end

        S_WAIT: if (eng_idle) begin
          dst_op      <= eng_err ? RING_P_ABORT : RING_P_COMMIT;
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
