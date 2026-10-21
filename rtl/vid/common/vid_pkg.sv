// vid_pkg.sv -- types and constants shared by every stage of the video
// subsystem (capture, ISP, frame DMA, processing, compositor).
//
// The subsystem is built from three contracts, all defined here or in the
// interfaces next to this file:
//
//   pixel streams   vpush_if (fixed-latency, no back-pressure) and vstream_if
//                   (valid/ready).  Both carry sof (first beat of a frame) and
//                   eol (last beat of a line) next to the data.
//   frame handoff   frame_ring: a producer acquires a slot, writes a whole
//                   frame, and commits it; consumers acquire the latest
//                   committed frame and release it when done.  frame_token_t
//                   is what a consumer holds.
//   DDR access      axi4_wr_if / axi4_rd_if, one per master, arbitrated onto the
//                   controller's single port.
//
// Frames in DDR are RGB565, one slot per frame, LINE_STRIDE bytes per line.
package vid_pkg;

  // ------------------------------------------------------------------ pixels
  typedef logic [9:0] raw10_t;

  typedef struct packed {
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
  } rgb888_t;

  // Bit layout matches the usual RGB565 word: r[15:11] g[10:5] b[4:0].
  typedef struct packed {
    logic [4:0] r;
    logic [5:0] g;
    logic [4:0] b;
  } rgb565_t;

  function automatic rgb565_t pack565(input rgb888_t p);
    pack565.r = p.r[7:3];
    pack565.g = p.g[7:2];
    pack565.b = p.b[7:3];
  endfunction

  // Replicate the top bits into the bottom so full scale stays full scale.
  function automatic rgb888_t unpack565(input rgb565_t p);
    unpack565.r = {p.r, p.r[4:2]};
    unpack565.g = {p.g, p.g[5:4]};
    unpack565.b = {p.b, p.b[4:2]};
  endfunction

  // ------------------------------------------------------------- geometry
  localparam int CAM_W = 1280;
  localparam int CAM_H = 720;

  // ------------------------------------------------------------ DDR / AXI
  localparam int AXI_AW     = 32;
  localparam int AXI_DW     = 128;
  localparam int AXI_IW     = 4;
  localparam int BEAT_BYTES = AXI_DW / 8;
  localparam int PIX_BYTES  = 2;                       // RGB565
  localparam int BEAT_PIX   = BEAT_BYTES / PIX_BYTES;  // 8 pixels per beat
  localparam int MAX_BURST  = 128;                     // beats, 2 KiB

  // A line never crosses a 4 KiB page: 1280 px * 2 B = 2560 B < 4096 B.
  localparam int LINE_STRIDE = 4096;
  localparam int SLOT_BYTES  = 4 * 1024 * 1024;        // 720 lines * 4 KiB = 2.8 MiB used

  // Ring regions sit above everything the legacy frame store touches
  // (0 .. ~24 MiB), so both paths can coexist while the new one is brought up.
  localparam logic [AXI_AW-1:0] RING_ISP_BASE  = 32'h0400_0000;
  localparam logic [AXI_AW-1:0] RING_PROC_BASE = 32'h0600_0000;
  localparam logic [AXI_AW-1:0] RING_TEST_BASE = 32'h0700_0000;

  localparam int RING_SLOT_W = 3;   // up to 8 slots per ring
  localparam int SEQ_W       = 16;

  function automatic logic [AXI_AW-1:0] slot_base(input logic [AXI_AW-1:0] ring_base,
                                                  input logic [RING_SLOT_W-1:0] slot);
    return ring_base + AXI_AW'(slot) * AXI_AW'(SLOT_BYTES);
  endfunction

  function automatic logic [AXI_AW-1:0] line_addr(input logic [AXI_AW-1:0] base,
                                                  input logic [11:0] y);
    return base + (AXI_AW'(y) << $clog2(LINE_STRIDE));
  endfunction

  typedef struct packed {
    logic [12:0] w;       // pixels
    logic [12:0] h;       // lines
  } frame_geom_t;

  localparam frame_geom_t CAM_GEOM = '{w: 13'(CAM_W), h: 13'(CAM_H)};

  // What a consumer holds while it reads a frame.
  typedef struct packed {
    logic                   valid;
    logic [RING_SLOT_W-1:0] slot;
    logic [SEQ_W-1:0]       seq;      // commit order within this ring
    logic [SEQ_W-1:0]       src_seq;  // seq of the frame this one was made from
  } frame_token_t;

  typedef enum logic {
    ACQ_REPEAT_OK = 1'b0,   // the same frame may be handed out again (display)
    ACQ_NEW_ONLY  = 1'b1    // only a frame this consumer has not seen (processing)
  } acq_policy_e;

  // Frame-ring operations; see rtl/vid/dma/ring_if.sv for the contract.
  typedef enum logic [1:0] {
    RING_P_ACQ    = 2'd0,
    RING_P_COMMIT = 2'd1,
    RING_P_ABORT  = 2'd2
  } ring_p_op_e;

  typedef enum logic {
    RING_C_ACQ = 1'b0,
    RING_C_REL = 1'b1
  } ring_c_op_e;

  typedef struct packed {
    logic [SEQ_W-1:0] commits;
    logic [SEQ_W-1:0] drops;       // producer found no free slot
    logic [SEQ_W-1:0] aborts;
    logic             proto_err;   // sticky
  } ring_status_t;

  // ---------------------------------------------------------- configuration
  // Compile-time today.  Every stage takes these as ports so a CSR block can
  // drive them later without touching the stages.

  // Gains are Q2.8 (256 = 1.0).
  typedef struct packed {
    logic       bypass_all;  // raw -> gray replicate, for bit-exact path checks
    logic       bypass_gamma;
    logic       bypass_sat;
    logic       dither_en;
    logic [9:0] blc_level;   // in 10-bit raw units
    logic [9:0] blc_gain;    // stretch back to full scale after subtraction
    logic [9:0] wb_r;
    logic [9:0] wb_g;
    logic [9:0] wb_b;
    logic [9:0] sat;         // saturation, 256 = unchanged
  } isp_cfg_t;

  // Values carried over from the verified ac6b658 display-side pipeline:
  // BLC 16/255 in 8 bit = 64 in 10 bit, stretch 255/239 ~= 273/256,
  // WB_G 0.52 (gray world), saturation 1.5x.
  localparam isp_cfg_t ISP_CFG_DEFAULT = '{
    bypass_all:   1'b0,
    bypass_gamma: 1'b0,
    bypass_sat:   1'b0,
    dither_en:    1'b1,
    blc_level:    10'd64,
    blc_gain:     10'd273,
    wb_r:         10'd256,
    wb_g:         10'd133,
    wb_b:         10'd256,
    sat:          10'd384
  };

  typedef enum logic [1:0] {
    COMP_SINGLE = 2'd0,     // one layer, centred
    COMP_SPLIT  = 2'd1      // left of split_col from layer 0, right from layer 1
  } comp_mode_e;

  typedef struct packed {
    comp_mode_e  mode;
    logic        single_sel;  // which layer SINGLE shows
    logic [11:0] split_col;   // in layer pixels, 0..CAM_W
  } comp_cfg_t;

  localparam comp_cfg_t COMP_CFG_DEFAULT = '{
    mode:       COMP_SINGLE,
    single_sel: 1'b0,
    split_col:  12'(CAM_W / 2)
  };

  // ----------------------------------------------------- subsystem status
  // Everything vid_subsystem reports, for telemetry.  Counters wrap.
  typedef struct packed {
    ring_status_t     test_ring;
    logic [SEQ_W-1:0] tw_frames;      // test writer: committed
    logic [SEQ_W-1:0] tw_errors;      //              aborted / resynchronised
    logic [SEQ_W-1:0] tw_skipped;     //              no free slot
    logic [31:0]      tw_sig;         //              signature of the last frame
    logic [SEQ_W-1:0] tc_frames;      // test checker: frames read back intact
    logic [SEQ_W-1:0] tc_bad_frames;
    logic [31:0]      tc_bad_words;
    logic [31:0]      tc_first_bad;
    logic [31:0]      tc_last_bad;    //              last wrong word received
    logic [31:0]      tc_last_pos;    //              where: {frame[7:0], line[11:0], word[11:0]}
    logic [SEQ_W-1:0] tr_miss;        // test reader: nothing new to read
    logic [15:0]      lg_wlen_err;    // legacy writer: bursts whose W beat count != awlen + 1
    logic [7:0]       lg_last_len;    //                awlen of the last such burst
    logic [7:0]       lg_last_beats;  //                beats it actually sent
    logic [15:0]      lg_ar_wd;       // legacy reader: arvalid dropped before arready
    logic [15:0]      lg_aw_wd;       // legacy writer: awvalid dropped before awready
  } vid_status_t;

  // ------------------------------------------------------- test pattern
  // Word w of line y of frame f, for DMA self-tests in simulation and on the
  // board.  Encodes all three so a checker can tell a wrong frame, line or
  // word apart; the low bits are a check field.  No multiplies, so it costs a
  // few LUTs.
  // Only the low bits of each coordinate fit in the word; that is enough to
  // tell neighbouring frames, lines and words apart.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] test_word(input logic [15:0] f,
                                            input logic [11:0] y,
                                            input logic [11:0] w);
    logic [5:0] chk;
    chk = f[5:0] ^ y[5:0] ^ w[5:0] ^ {y[9:6], 2'b10} ^ {w[9:6], 2'b01};
    return {f[5:0], y[9:0], w[9:0], chk};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------- helpers
  function automatic int clog2u(input int v);
    int r = 0;
    int x = v - 1;
    while (x > 0) begin
      r++;
      x >>= 1;
    end
    return (r < 1) ? 1 : r;
  endfunction

endpackage
