// st_accel_wrapper.sv — Top-level wrapper for the style-transfer accelerator.
//
// External interface mirrors the vid_subsystem `ext_*` ports: a single AXI4
// write master + read master that plug into axi_arb master index 0. Internally
// it:
//   1. Reads an RGB565 frame from the ISP ring (tile_dma_rd).
//   2. Converts each pixel to Y/C dual-plane (rgb2yc).
//   3. Streams the Y/C plane into tile_engine which runs the 15-layer
//      tiny_dw_guided graph (weights/bias/requant in BRAM).
//   4. Writes the stylised RGB565 frame back to the PROC ring (tile_dma_wr).
//
// The wrapper is frame-driven: a `start` pulse begins one inference; `done`
// asserts when the output frame is fully written back. Frame-rate skipping
// (process every Nth ISP frame) is handled by the caller — this module just
// executes on demand.

module st_accel_wrapper
    import st_accel_pkg::*;
    import vid_pkg::*;
#(
    parameter int FRAME_W = 640,
    parameter int FRAME_H = 480,
    parameter int RD_FIFO  = 512,
    parameter int WR_FIFO  = 256,
    parameter int RD_BURST = 64,
    parameter int WR_BURST = 64
) (
    input  logic clk,
    input  logic rst_n,

    // ─── AXI4 master ports (connect to vid_subsystem ext_*) ──────────────────
    // Write channel
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
    // Read channel
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

    // ─── Control ───────────────────────────────────────────────────────────────
    input  logic               start,          // begin one inference
    output logic               done,           // output frame committed
    output logic               busy,

    // DDR addresses (set by firmware before start)
    input  logic [AXI_AW-1:0]  isp_base_addr,  // ISP ring slot base
    input  logic [AXI_AW-1:0]  proc_base_addr, // PROC ring slot base
    input  logic [AXI_AW-1:0]  line_stride     // bytes per row (4 KiB)
);

    // ==========================================================================
    // AXI interfaces
    // ==========================================================================
    axi4_wr_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mwr (.clk(clk), .rst_n(rst_n));
    axi4_rd_if #(.AW(AXI_AW), .DW(AXI_DW), .IW(AXI_IW)) mrd (.clk(clk), .rst_n(rst_n));

    // Map flat ports → interfaces.
    // Outputs from this master (driven by wrapper → vid_subsystem inputs):
    assign m_axi_awid    = mwr.awid;
    assign m_axi_awaddr  = mwr.awaddr;
    assign m_axi_awlen   = mwr.awlen;
    assign m_axi_awvalid = mwr.awvalid;
    assign m_axi_wdata   = mwr.wdata;
    assign m_axi_wlast   = mwr.wlast;
    assign m_axi_wvalid  = mwr.wvalid;
    assign m_axi_bready  = mwr.bready;
    // Inputs to this master (driven by vid_subsystem → wrapper):
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
    // Inputs to this master:
    assign mrd.arready   = m_axi_arready;
    assign mrd.rid       = m_axi_rid;
    assign mrd.rdata     = m_axi_rdata;
    assign mrd.rresp     = m_axi_rresp;
    assign mrd.rlast     = m_axi_rlast;
    assign mrd.rvalid    = m_axi_rvalid;

    // ==========================================================================
    // Pixel stream between DMA and rgb2yc
    // ==========================================================================
    // BEAT_PIX is already defined in vid_pkg (8 pixels/beat); use it directly.

    vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_in (.clk(clk), .rst_n(rst_n));

    logic                       rd_busy;
    logic [SEQ_W-1:0]           rd_done;
    logic [15:0]                beats_per_line;
    logic [15:0]                frame_lines;
    logic [AXI_AW-1:0]          cur_stride;

    assign beats_per_line = FRAME_W / BEAT_PIX;   // 640/8 = 80
    assign frame_lines    = FRAME_H;             // 480
    assign cur_stride     = line_stride;

    // ==========================================================================
    // tile_dma_rd: fetch ISP frame
    // ==========================================================================
    tile_dma_rd #(
        .FIFO_BEATS (RD_FIFO),
        .RD_BURST   (RD_BURST)
    ) u_dma_rd (
        .m               (mrd),
        .o               (s_in),
        .start           (start),
        .base_addr       (isp_base_addr),
        .beats_per_line   (beats_per_line),
        .lines            (frame_lines),
        .line_stride      (cur_stride),
        .busy             (rd_busy),
        .st_done          (rd_done),
        .st_err           ()
    );

    // ==========================================================================
    // rgb2yc: convert RGB565 → Y + C dual plane (streaming, one beat → one beat)
    // The RGB565 beat carries BEAT_PIX pixels; rgb2yc outputs the same number of
    // Y/C samples packed into a 128-bit beat (16 bytes = 8 Y + 8 C).
    // ==========================================================================
    vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_yc (.clk(clk), .rst_n(rst_n));

    rgb2yc u_rgb2yc (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (s_in.valid),
        .in_data   (s_in.data),
        .in_sof    (s_in.sof),
        .in_eol    (s_in.eol),
        .in_ready  (s_in.ready),
        .out_valid (s_yc.valid),
        .out_data  (s_yc.data),
        .out_sof   (s_yc.sof),
        .out_eol   (s_yc.eol),
        .out_ready (s_yc.ready)
    );

    // ==========================================================================
    // tile_engine: run the 15-layer graph
    // For now the wrapper feeds the Y/C stream directly; the engine's full
    // layer loop is driven by layer_desc_rom. Output is an RGB565 beat stream
    // to tile_dma_wr.
    // ==========================================================================
    vstream_if #(.T(logic [AXI_DW-1:0]), .PPC(1)) s_out (.clk(clk), .rst_n(rst_n));

    logic [7:0]        cur_layer;
    layer_desc_t       cur_desc;

    layer_desc_rom #(
        .NUM_LAYERS (15)
    ) u_desc_rom (
        .layer_id (cur_layer),
        .desc     (cur_desc)
    );

    // The engine reads its weights/bias/requant from BRAMs loaded at synthesis
    // time from the hex files emitted by extract_weights.py. These are
    // declared here as simple memories with initial blocks.
    logic signed [7:0]  weight_rom [3666];
    logic signed [31:0] bias_rom    [244];
    logic [15:0]        requant_rom [244];

    initial begin
        $readmemh("rtl/st_accel_new/gen/weights.hex",  weight_rom);
        $readmemh("rtl/st_accel_new/gen/bias.hex",     bias_rom);
        $readmemh("rtl/st_accel_new/gen/requant.hex",  requant_rom);
    end

    // Stub: tile_engine output mirrors input for now (placeholder until the
    // streaming layer loop is fully wired). The full integration lives in
    // tile_engine.sv; this wrapper only carries the plumbing.
    assign s_out.valid = s_yc.valid;
    assign s_out.data  = s_in.data;    // TODO: replace with tile_engine output
    assign s_out.sof   = s_yc.sof;
    assign s_out.eol   = s_yc.eol;
    assign s_yc.ready  = s_out.ready;

    // ==========================================================================
    // tile_dma_wr: write PROC frame
    // ==========================================================================
    logic                       wr_busy;
    logic [SEQ_W-1:0]           wr_done;

    tile_dma_wr #(
        .FIFO_BEATS (WR_FIFO),
        .WR_BURST   (WR_BURST)
    ) u_dma_wr (
        .m               (mwr),
        .i               (s_out),
        .flush           (1'b0),
        .base_addr       (proc_base_addr),
        .beats_per_line   (beats_per_line),
        .lines            (frame_lines),
        .line_stride      (cur_stride),
        .busy             (wr_busy),
        .st_done          (wr_done),
        .st_err           ()
    );

    // ==========================================================================
    // Top-level control: done when write DMA commits the last beat
    // ==========================================================================
    assign busy = rd_busy || wr_busy;
    assign done = (wr_done > 0) && !wr_busy;

endmodule
