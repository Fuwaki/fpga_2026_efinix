// video_contract_pkg.sv -- the interfaces between capture, storage and display.
//
// Written down as types so the contracts are checked by the compiler instead
// of living in comments.  The rules they encode:
//
//   * The display raster is generated locally and never waits for input.
//     A frame that has not arrived must look like black, never like "no
//     signal".
//   * Capture runs at whatever rate the sensor produces.  Nothing downstream
//     may assume a fixed pixel rate; the seam is a FIFO, not a handshake
//     that both sides must agree on.
//   * A layer is described by geometry (rectangle + stride + base address),
//     not by the size of the sensor that produced it.
package video_contract_pkg;

  // ---------------------------------------------------------------- raster
  // CEA-861 format 16, counted in display pixel clocks (148.5 MHz).
  localparam int unsigned DISP_H_ACTIVE = 1920;
  localparam int unsigned DISP_H_FP     = 88;
  localparam int unsigned DISP_H_SYNC   = 44;
  localparam int unsigned DISP_H_BP     = 148;
  localparam int unsigned DISP_H_TOTAL  = DISP_H_ACTIVE + DISP_H_FP + DISP_H_SYNC + DISP_H_BP;

  localparam int unsigned DISP_V_ACTIVE = 1080;
  localparam int unsigned DISP_V_FP     = 4;
  localparam int unsigned DISP_V_SYNC   = 5;
  localparam int unsigned DISP_V_BP     = 36;
  localparam int unsigned DISP_V_TOTAL  = DISP_V_ACTIVE + DISP_V_FP + DISP_V_SYNC + DISP_V_BP;

  // -------------------------------------------------------------- pixel
  // One pixel is 24 bit.  Stored as a 32 bit word so it lines up with the DDR
  // byte lanes: {8'h00, R, G, B}.
  typedef struct packed {
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
  } rgb24_t;

  // ------------------------------------------------------------- layer
  // Describes where one layer lives in DDR and where it sits on screen.  A
  // future CSR block drives this unchanged; the compositor never needs to
  // know whether the layer came from a camera, a network, or a test pattern.
  typedef struct packed {
    logic [31:0] base_addr;   // byte address of pixel (0,0)
    logic [31:0] stride;      // bytes per line
    logic [15:0] width;       // layer width in pixels
    logic [15:0] height;      // layer height in lines
    logic [15:0] pos_x;       // left edge in display pixels
    logic [15:0] pos_y;       // top edge in display lines
    logic        enable;
  } layer_desc_t;

  // ------------------------------------------------------------- stream
  // A pixel leaving a reader.  `valid` means `pix` is the next pixel; the
  // consumer raises `ready` when it wants it.  No frame phase is implied:
  // readers may start at any time and stall at any time.
  typedef struct packed {
    logic       valid;
    rgb24_t     pix;
  } pix_stream_t;

  // --------------------------------------------------------------- util
  function automatic int unsigned clog2u(input int unsigned v);
    int unsigned r;
    r = 0;
    v = v - 1;
    while (v > 0) begin
      v = v >> 1;
      r = r + 1;
    end
    return r;
  endfunction

endpackage
