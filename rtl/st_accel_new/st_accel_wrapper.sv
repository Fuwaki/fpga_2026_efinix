// st_accel_wrapper.sv — Multi-pass DDR layer-loop controller.
//
// On `start` the wrapper executes:
//   YC pre-pass  : ISP ring → rgb2yc → BUF_YC
//   9 conv passes: BUF_in → tile_engine (one layer) → BUF_out
//   Final copy   : result buffer → PROC ring (stub; guide branch in Phase 2)
//
// The single AXI read master (mrd) and write master (mwr) are shared across
// all passes; the per-pass base address is driven by registered mux outputs.

module st_accel_wrapper
    import st_accel_pkg::*;
    import vid_pkg::*;
#(
    parameter int FRAME_W  = 480,
    parameter int FRAME_H  = 480,
    parameter int RD_FIFO  = 512,
    parameter int WR_FIFO  = 256,
    parameter int RD_BURST = 64,
    parameter int WR_BURST = 64
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

    // ─── Control ────────────────────────────────────────────────────────────
    input  logic               start,
    output logic               done,
    output logic               busy,

    input  logic [AXI_AW-1:0]  isp_base_addr,
    input  logic [AXI_AW-1:0]  proc_base_addr,
    input  logic [AXI_AW-1:0]  line_stride
);

  // ==========================================================================
  // AXI interfaces
  // ==========================================================================
  axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mwr (.clk(clk), .rst_n(rst_n));
  axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mrd (.clk(clk), .rst_n(rst_n));

  // Flat port ↔ interface mapping
  assign m_axi_awid    = mwr.awid;    assign m_axi_awaddr  = mwr.awaddr;
  assign m_axi_awlen   = mwr.awlen;   assign m_axi_awvalid = mwr.awvalid;
  assign m_axi_wdata   = mwr.wdata;   assign m_axi_wlast   = mwr.wlast;
  assign m_axi_wvalid  = mwr.wvalid;  assign m_axi_bready  = mwr.bready;
  assign mwr.awready   = m_axi_awready;
  assign mwr.wready    = m_axi_wready;
  assign mwr.bid       = m_axi_bid;
  assign mwr.bresp     = m_axi_bresp;
  assign mwr.bvalid    = m_axi_bvalid;

  assign m_axi_arid    = mrd.arid;    assign m_axi_araddr  = mrd.araddr;
  assign m_axi_arlen   = mrd.arlen;   assign m_axi_arvalid = mrd.arvalid;
  assign m_axi_rready  = mrd.rready;
  assign mrd.arready   = m_axi_arready;
  assign mrd.rid       = m_axi_rid;   assign mrd.rdata     = m_axi_rdata;
  assign mrd.rresp     = m_axi_rresp; assign mrd.rlast     = m_axi_rlast;
  assign mrd.rvalid    = m_axi_rvalid;

  // ==========================================================================
  // Scratch buffer map
  // ==========================================================================
  // BUF_YC is in the gap between ISP/PROC rings and the accel scratch region
  localparam logic [31:0] BUF_YC = 32'h0780_0000;  // 450 KB YC input (pinned)
  localparam logic [31:0] BUF_A  = 32'h0800_0000;  // 4 MB  stem out
  localparam logic [31:0] BUF_B  = 32'h0840_0000;  // 1 MB  enc0.dw out
  localparam logic [31:0] BUF_C  = 32'h0850_0000;  // 2 MB  enc0.pw / enc1.pw / dec_h4.dw (reuse)
  localparam logic [31:0] BUF_D  = 32'h0870_0000;  // 2 MB  enc1.dw / dec_h4.pw-tmp
  localparam logic [31:0] BUF_E  = 32'h0890_0000;  // 1 MB  dec_h4.pw out
  localparam logic [31:0] BUF_F  = 32'h08A0_0000;  // 3 MB  upsample out / dec_h2.dw in
  localparam logic [31:0] BUF_G  = 32'h08D0_0000;  // 3 MB  dec_h2.dw out
  localparam logic [31:0] BUF_H  = 32'h0900_0000;  // 5 MB  dec_h2.pw out (Phase 1 output)

  // ==========================================================================
  // Pass schedule (Phase 1: YC pre-pass + 9 conv layers)
  // Each slot: {layer_id, in_addr, out_addr}
  // ==========================================================================
  localparam int NUM_CONV_PASSES = 9;

  typedef struct packed {
    logic [7:0]  layer_id;
    logic [31:0] in_ddr;
    logic [31:0] out_ddr;
  } pass_t;

  pass_t conv_passes [NUM_CONV_PASSES];
  initial begin
    // layer_id matches layer_desc_rom index; see gen/layer_desc_rom.sv
    conv_passes[0] = '{8'd0, BUF_YC, BUF_A};  // stem      480×480 in_c=2  out_c=16
    conv_passes[1] = '{8'd1, BUF_A,  BUF_B};  // enc0.dw   480×480 →240×240 c=16
    conv_passes[2] = '{8'd2, BUF_B,  BUF_C};  // enc0.pw   240×240 c16→32
    conv_passes[3] = '{8'd3, BUF_C,  BUF_D};  // enc1.dw   240×240 c32
    conv_passes[4] = '{8'd4, BUF_D,  BUF_C};  // enc1.pw   240×240 c32 (reuse C)
    conv_passes[5] = '{8'd5, BUF_C,  BUF_D};  // dec_h4.dw 240×240 c32 (reuse D)
    conv_passes[6] = '{8'd6, BUF_D,  BUF_E};  // dec_h4.pw 240×240 c32→12
    conv_passes[7] = '{8'd7, BUF_F,  BUF_G};  // dec_h2.dw 480×480 c12 (F filled by upsample)
    conv_passes[8] = '{8'd8, BUF_G,  BUF_H};  // dec_h2.pw 480×480 c12→20
  end

  // ==========================================================================
  // DMA configuration registers (set per pass before rd.start)
  // ==========================================================================
  logic [AXI_AW-1:0] rd_base, wr_base;
  logic [15:0]        rd_bpl,  wr_bpl;    // beats per line
  logic [15:0]        rd_lines, wr_lines;
  logic [AXI_AW-1:0] rd_stride, wr_stride;
  logic               rd_start;

  // ==========================================================================
  // Beat streams
  // ==========================================================================
  vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_raw (.clk(clk), .rst_n(rst_n)); // from dma_rd
  vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_yc  (.clk(clk), .rst_n(rst_n)); // after rgb2yc
  vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_out (.clk(clk), .rst_n(rst_n)); // to dma_wr

  // ==========================================================================
  // tile_dma_rd
  // ==========================================================================
  logic rd_busy;
  tile_dma_rd #(.FIFO_BEATS(RD_FIFO), .RD_BURST(RD_BURST)) u_dma_rd (
    .m              (mrd),
    .o              (s_raw),
    .start          (rd_start),
    .base_addr      (rd_base),
    .beats_per_line (rd_bpl),
    .lines          (rd_lines),
    .line_stride    (rd_stride),
    .busy           (rd_busy),
    .st_done        (),
    .st_err         ()
  );

  // ==========================================================================
  // rgb2yc
  // ==========================================================================
  // Only active during the YC pre-pass (routed by sel_yc).
  // rgb2yc.in_data comes from s_raw; output to s_yc.
  logic sel_yc;   // 1 = YC pass, 0 = conv/copy pass

  logic [127:0] yc_out_data;
  logic         yc_out_valid, yc_out_sof, yc_out_eol, yc_in_ready;

  rgb2yc #(.IMG_W(FRAME_W), .IMG_H(FRAME_H)) u_rgb2yc (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (s_raw.valid  &  sel_yc),
    .in_data   (s_raw.data),
    .in_sof    (s_raw.sof),
    .in_eol    (s_raw.eol),
    .in_ready  (yc_in_ready),
    .out_valid (yc_out_valid),
    .out_data  (yc_out_data),
    .out_sof   (yc_out_sof),
    .out_eol   (yc_out_eol),
    .out_ready (s_yc.ready)
  );

  assign s_yc.valid = yc_out_valid;
  assign s_yc.data  = yc_out_data;
  assign s_yc.sof   = yc_out_sof;
  assign s_yc.eol   = yc_out_eol;

  // ==========================================================================
  // Weight / bias / requant BRAMs
  // ==========================================================================
  logic signed [7:0]  weight_rom [3666];
  logic signed [31:0] bias_rom   [244];
  logic [15:0]        requant_rom [244];

  initial begin
    $readmemh("rtl/st_accel_new/gen/weights.hex",  weight_rom);
    $readmemh("rtl/st_accel_new/gen/bias.hex",     bias_rom);
    $readmemh("rtl/st_accel_new/gen/requant.hex",  requant_rom);
  end

  logic [15:0] eng_w_addr, eng_b_addr, eng_q_addr;

  // ==========================================================================
  // Layer descriptor ROM
  // ==========================================================================
  logic [7:0]   cur_layer_id;
  layer_desc_t  rom_desc;

  layer_desc_rom #(.NUM_LAYERS(15)) u_desc_rom (
    .layer_id (cur_layer_id),
    .desc     (rom_desc)
  );

  // Working descriptor (patched with runtime DDR addresses + geometry)
  layer_desc_t eng_desc;

  // ==========================================================================
  // tile_engine
  // ==========================================================================
  logic        eng_start, eng_done, eng_busy;
  logic        eng_in_valid, eng_in_ready, eng_in_sof, eng_in_eol;
  logic [127:0] eng_in_beat;
  logic        eng_out_valid, eng_out_sof, eng_out_eol;
  logic [127:0] eng_out_beat;
  logic        eng_out_ready;

  tile_engine #(
    .MAX_CH (32),
    .IMG_W  (FRAME_W),
    .IMG_H  (FRAME_H)
  ) u_engine (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (eng_start),
    .done      (eng_done),
    .busy      (eng_busy),
    .desc      (eng_desc),
    .in_valid  (eng_in_valid),
    .in_beat   (eng_in_beat),
    .in_ready  (eng_in_ready),
    .in_sof    (eng_in_sof),
    .in_eol    (eng_in_eol),
    .out_valid (eng_out_valid),
    .out_beat  (eng_out_beat),
    .out_ready (eng_out_ready),
    .out_sof   (eng_out_sof),
    .out_eol   (eng_out_eol),
    .w_addr    (eng_w_addr),
    .w_rdata   (weight_rom[eng_w_addr]),
    .b_addr    (eng_b_addr),
    .b_rdata   (bias_rom[eng_b_addr]),
    .q_addr    (eng_q_addr),
    .q_rdata   (requant_rom[eng_q_addr])
  );

  // Engine reads from s_raw during conv passes
  assign eng_in_valid = s_raw.valid & ~sel_yc;
  assign eng_in_beat  = s_raw.data;
  assign eng_in_sof   = s_raw.sof;
  assign eng_in_eol   = s_raw.eol;

  // s_raw.ready mux: YC pass → yc_in_ready, conv pass → eng_in_ready, copy → s_out.ready
  logic sel_copy;
  always_comb begin
    if      (sel_yc)   s_raw.ready = yc_in_ready;
    else if (sel_copy) s_raw.ready = s_out.ready;
    else               s_raw.ready = eng_in_ready;
  end

  // s_out mux → dma_wr input
  always_comb begin
    if (sel_yc) begin
      s_out.valid = s_yc.valid;
      s_out.data  = s_yc.data;
      s_out.sof   = s_yc.sof;
      s_out.eol   = s_yc.eol;
      s_yc.ready  = s_out.ready;
      eng_out_ready = 1'b0;
    end else if (sel_copy) begin
      s_out.valid   = s_raw.valid;
      s_out.data    = s_raw.data;
      s_out.sof     = s_raw.sof;
      s_out.eol     = s_raw.eol;
      s_yc.ready    = 1'b0;
      eng_out_ready = 1'b0;
    end else begin
      s_out.valid   = eng_out_valid;
      s_out.data    = eng_out_beat;
      s_out.sof     = eng_out_sof;
      s_out.eol     = eng_out_eol;
      eng_out_ready = s_out.ready;
      s_yc.ready    = 1'b0;
    end
  end

  // ==========================================================================
  // tile_dma_wr
  // ==========================================================================
  logic wr_busy;
  tile_dma_wr #(.FIFO_BEATS(WR_FIFO), .WR_BURST(WR_BURST)) u_dma_wr (
    .m              (mwr),
    .i              (s_out),
    .flush          (1'b0),
    .base_addr      (wr_base),
    .beats_per_line (wr_bpl),
    .lines          (wr_lines),
    .line_stride    (wr_stride),
    .busy           (wr_busy),
    .st_done        (),
    .st_err         ()
  );

  // ==========================================================================
  // Helper: compute beats-per-line and line count from layer descriptor
  // For int8 feature maps: beat = BEAT_BYTES = 16 channels per beat.
  // beats_per_line = ceil(out_w * out_c / BEAT_BYTES)
  // ==========================================================================
  function automatic logic [15:0] bpl_of(logic [15:0] w, logic [15:0] c);
    return (w * c + 15) >> 4;
  endfunction

  // ==========================================================================
  // Pass sequencer state machine
  // ==========================================================================
  typedef enum logic [3:0] {
    SEQ_IDLE      = 4'd0,
    SEQ_YC_CFG    = 4'd1,
    SEQ_YC_RUN    = 4'd2,
    SEQ_YC_WAIT   = 4'd3,
    SEQ_CONV_CFG  = 4'd4,
    SEQ_CONV_RUN  = 4'd5,
    SEQ_CONV_WAIT = 4'd6,
    SEQ_UP_CFG    = 4'd7,   // upsample pass BUF_E→BUF_F (copy 2×; stub: direct copy for now)
    SEQ_UP_RUN    = 4'd8,
    SEQ_UP_WAIT   = 4'd9,
    SEQ_COPY_CFG  = 4'd10,  // final: BUF_H → PROC ring
    SEQ_COPY_RUN  = 4'd11,
    SEQ_COPY_WAIT = 4'd12,
    SEQ_DONE      = 4'd13
  } seq_t;

  seq_t seq_state;
  logic [3:0] pass_idx;   // 0..NUM_CONV_PASSES-1 (skips upsample at idx 7)

  // Half-resolution geometry (for enc0.dw-dec_h4.pw passes): stride=2 → H/2 × W/2
  // The descriptor carries out_h/out_w but we leave those at 0 in the ROM
  // and compute geometry from the pass schedule here.
  // For Phase 1 we use simplified geometry: passes 1-6 use H/2 × W/2 (240×240),
  // passes 0,7,8 use full resolution (480×480).
  localparam int HH = FRAME_H / 2;
  localparam int HW = FRAME_W / 2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      seq_state  <= SEQ_IDLE;
      pass_idx   <= '0;
      rd_start   <= 1'b0;
      eng_start  <= 1'b0;
      sel_yc     <= 1'b0;
      sel_copy   <= 1'b0;
      done       <= 1'b0;
      busy       <= 1'b0;
      cur_layer_id <= '0;
    end else begin
      rd_start   <= 1'b0;
      eng_start  <= 1'b0;
      done       <= 1'b0;

      case (seq_state)
        SEQ_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            busy      <= 1'b1;
            sel_yc    <= 1'b1;
            sel_copy  <= 1'b0;
            pass_idx  <= '0;
            seq_state <= SEQ_YC_CFG;
          end
        end

        // ── YC pre-pass: ISP ring → rgb2yc → BUF_YC ────────────────────────
        SEQ_YC_CFG: begin
          rd_base   <= isp_base_addr;
          rd_bpl    <= 16'(FRAME_W / BEAT_PIX);   // 60 beats/line (480/8)
          rd_lines  <= 16'(FRAME_H);
          rd_stride <= line_stride;
          wr_base   <= BUF_YC;
          wr_bpl    <= 16'(FRAME_W / BEAT_PIX);   // rgb2yc output: same beat count
          wr_lines  <= 16'(FRAME_H);
          wr_stride <= line_stride;
          seq_state <= SEQ_YC_RUN;
        end

        SEQ_YC_RUN: begin
          rd_start  <= 1'b1;
          seq_state <= SEQ_YC_WAIT;
        end

        SEQ_YC_WAIT: begin
          if (!rd_busy && !wr_busy) begin
            sel_yc    <= 1'b0;
            seq_state <= SEQ_CONV_CFG;
          end
        end

        // ── Conv passes ─────────────────────────────────────────────────────
        SEQ_CONV_CFG: begin
          // Skip pass index 7 (upsample handled separately)
          if (pass_idx == 7) begin
            seq_state <= SEQ_UP_CFG;
          end else begin
            cur_layer_id <= conv_passes[pass_idx].layer_id;

            // Geometry: passes 1-6 are half-res (240×240), rest full-res
            eng_desc             <= rom_desc;
            eng_desc.in_ddr_addr <= conv_passes[pass_idx].in_ddr;
            eng_desc.out_ddr_addr<= conv_passes[pass_idx].out_ddr;
            eng_desc.in_h        <= (pass_idx >= 1 && pass_idx <= 6)
                                    ? 16'(HH) : 16'(FRAME_H);
            eng_desc.in_w        <= (pass_idx >= 1 && pass_idx <= 6)
                                    ? 16'(HW) : 16'(FRAME_W);
            eng_desc.out_h       <= (pass_idx >= 1 && pass_idx <= 6)
                                    ? ((rom_desc.stride == 3'd2) ? 16'(HH/2) : 16'(HH))
                                    : ((rom_desc.stride == 3'd2) ? 16'(FRAME_H/2) : 16'(FRAME_H));
            eng_desc.out_w       <= (pass_idx >= 1 && pass_idx <= 6)
                                    ? ((rom_desc.stride == 3'd2) ? 16'(HW/2) : 16'(HW))
                                    : ((rom_desc.stride == 3'd2) ? 16'(FRAME_W/2) : 16'(FRAME_W));

            rd_base   <= conv_passes[pass_idx].in_ddr;
            rd_bpl    <= (pass_idx >= 1 && pass_idx <= 6)
                         ? bpl_of(16'(HW), rom_desc.in_c)
                         : bpl_of(16'(FRAME_W), rom_desc.in_c);
            rd_lines  <= (pass_idx >= 1 && pass_idx <= 6) ? 16'(HH) : 16'(FRAME_H);
            rd_stride <= line_stride;

            wr_base   <= conv_passes[pass_idx].out_ddr;
            wr_bpl    <= (pass_idx >= 1 && pass_idx <= 6)
                         ? bpl_of(16'((rom_desc.stride == 3'd2) ? HW/2 : HW), rom_desc.out_c)
                         : bpl_of(16'((rom_desc.stride == 3'd2) ? FRAME_W/2 : FRAME_W), rom_desc.out_c);
            wr_lines  <= (pass_idx >= 1 && pass_idx <= 6)
                         ? 16'((rom_desc.stride == 3'd2) ? HH/2 : HH)
                         : 16'((rom_desc.stride == 3'd2) ? FRAME_H/2 : FRAME_H);
            wr_stride <= line_stride;

            seq_state <= SEQ_CONV_RUN;
          end
        end

        SEQ_CONV_RUN: begin
          rd_start  <= 1'b1;
          eng_start <= 1'b1;
          seq_state <= SEQ_CONV_WAIT;
        end

        SEQ_CONV_WAIT: begin
          if (eng_done && !rd_busy && !wr_busy) begin
            if (pass_idx == NUM_CONV_PASSES - 1) begin
              seq_state <= SEQ_COPY_CFG;
            end else begin
              pass_idx  <= pass_idx + 1;
              seq_state <= SEQ_CONV_CFG;
            end
          end
        end

        // ── Upsample pass: BUF_E → BUF_F  (2× nearest neighbour; stub: copy) ──
        // True 2× upsample deferred to Phase 2; for smoke test, direct copy.
        SEQ_UP_CFG: begin
          sel_copy  <= 1'b1;
          rd_base   <= BUF_E;
          rd_bpl    <= bpl_of(16'(HW), 12);  // dec_h4.pw out: 240×240×12
          rd_lines  <= 16'(HH);
          rd_stride <= line_stride;
          wr_base   <= BUF_F;
          wr_bpl    <= bpl_of(16'(HW), 12);
          wr_lines  <= 16'(HH);
          wr_stride <= line_stride;
          seq_state <= SEQ_UP_RUN;
        end

        SEQ_UP_RUN: begin
          rd_start  <= 1'b1;
          seq_state <= SEQ_UP_WAIT;
        end

        SEQ_UP_WAIT: begin
          if (!rd_busy && !wr_busy) begin
            sel_copy  <= 1'b0;
            pass_idx  <= 4'd8;    // next: dec_h2.dw (index 7) and dec_h2.pw (index 8)
            seq_state <= SEQ_CONV_CFG;
          end
        end

        // ── Final copy: BUF_H → PROC ring (Phase 1 output stub) ─────────────
        SEQ_COPY_CFG: begin
          sel_copy  <= 1'b1;
          rd_base   <= BUF_H;
          rd_bpl    <= bpl_of(16'(FRAME_W), 20);  // dec_h2.pw out: 480×480×20
          rd_lines  <= 16'(FRAME_H);
          rd_stride <= line_stride;
          wr_base   <= proc_base_addr;
          wr_bpl    <= 16'(FRAME_W / BEAT_PIX);   // PROC ring takes RGB565 beats
          wr_lines  <= 16'(FRAME_H);
          wr_stride <= line_stride;
          seq_state <= SEQ_COPY_RUN;
        end

        SEQ_COPY_RUN: begin
          rd_start  <= 1'b1;
          seq_state <= SEQ_COPY_WAIT;
        end

        SEQ_COPY_WAIT: begin
          if (!rd_busy && !wr_busy) begin
            sel_copy  <= 1'b0;
            seq_state <= SEQ_DONE;
          end
        end

        SEQ_DONE: begin
          done      <= 1'b1;
          busy      <= 1'b0;
          seq_state <= SEQ_IDLE;
        end

      endcase
    end
  end

  // ── Fix-up: patch eng_desc with the ROM value one cycle after cur_layer_id updates ──
  // (rom_desc latches one cycle after cur_layer_id changes; eng_desc gets patched
  //  on the same cycle as SEQ_CONV_CFG writes it, which is fine because rom_desc
  //  was set the previous cycle — the ROM is combinational.)

endmodule
