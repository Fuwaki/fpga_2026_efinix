# ADR: ST accelerator block engine (tiny_dw at 320x240)

Date: 2026-11-02
Status: Accepted.  Supersedes the 2026-11-02 "DDR layer-loop engine" draft
(one layer per pass, 480x480, guide branch), which did not fit the board.

## Context

The ring-driven accelerator path runs on the board (commits 69fff12,
a4c01d0).  The wrapper takes each new ISP frame, runs DMA passes through a
DDR scratch area, and commits the PROC ring.  The compositor shows the PROC
ring on the right half of the screen.  This ADR puts the real network on
that path: `config/manifest/ink_dw_w8a8` (tiny_dw, W8A8, 29 layers, 50,144
weight bytes).

The network does not fit the board as one fused 640x480 pipeline:

* compute: about 6.2k MAC per pixel.  640x480 at 15 fps is 28.7 GMAC/s,
  90% of the peak of 160 DSP48 (2 int8 MACs each at 100 MHz);
* storage: the 3x3 line buffers of a fully fused pipeline need about 344 KB
  at 640x480 and 172 KB at 320x240.  The board has about 150 KB of free RAM.

## Decision

Run the network at **320x240 internally**.  Group its layers into **15
passes**; each pass is one DDR round trip through a single programmable
**block engine**.  The ISP frame is cropped and box-downscaled into the
network input, and the 320x240 result is shown 2x on the right half.

Budget at 320x240: 0.48 GMAC per frame (7.2 GMAC/s at 15 fps), about 3.7 M
engine cycles (37 ms at 100 MHz), and about 12 MB of DDR traffic per frame.

### Numerics: bit-exact with the integer reference

`tools/st_golden.py` is the golden model.  It reproduces
`fpga_st_train::intref` code for code, and every RTL test compares against
it.  The semantics:

* conv: reflect pad 1 (the edge is not repeated) for 3x3 kernels; int32
  accumulate; `+ bias_int32`; requant; clamp to [0,127] (relu), [-127,127]
  (no relu), or [0,255] (head, unsigned).
* requant: `round_half_away(f32(acc) * f32(r))`, computed with integers
  (`f32_mul_round`):
  * `r = mant * 2^(exp-24)`, where `mant` is 24 bits and `exp` is -11..-6;
  * the product `|acc| * mant` is exact in 48 bits;
  * round it to 24 significant bits (round to nearest even, at the leading
    one);
  * shift right by `24-exp` bits, rounding half away from zero;
  * apply the sign.

  Plain 16-bit fixed point is not acceptable: the residual chain amplifies
  its tie flips into 59% wrong output codes.
* add (residual and skip): `clamp(f32_mul_round(src, factor), ±127) +
  trunk`, with no clamp after the add.  The add outputs (points 9, 13, 17,
  21) are 9-bit signed (±254).
* upsample: nearest 2x, a wire.
* input: point 0 is `LUT[rgb8]` with 256 entries: `round_half_away(f32(p) /
  255 / f32(s0))`.

Value ranges: |acc| < 2^21 (the worst case is 64·254·127 + bias), |bias| <
2^15.  PW inputs are always int8.  DW inputs are int9 (they may be add
outputs).

### Passes

| # | name  | input (DDR) | ops on chip | output (DDR) |
|---|-------|-------------|-------------|--------------|
| 0 | pre   | ISP slot 1280x720 RGB565 | crop x 160..1119, 3x3 box average, LUT | p0 320x240x3 |
| 1 | stem  | p0 | im2col 3x3 → PW 27→32 | p1 320x240x32 |
| 2 | enc0  | p1 | DW s2 → PW 32→64 | p3 160x120x64 |
| 3 | enc1  | p3 | DW s2 → PW 64→64 | p5 80x60x64 |
| 4,6,8,10 | resKa | p5/9/13/17 | DW → PW 64→64 | p7/11/15/19 |
| 5,7,9,11 | resKb | p7/11/15/19, aux p5/9/13/17 | DW → PW 64→64 → + requant(aux) | p9/13/17/21 (int16) |
| 12 | up0  | p21 (2x up), aux p3 | + requant(aux) → DW → PW 64→32 → PW 32→32 | p24 160x120x32 |
| 13 | up1a | p24 (2x up) | DW → PW 32→16 → PW 16→16 | p27 320x240x16 |
| 14 | up1b | p27 | DW → PW 16→3 (u8) → post | PROC slot |

Post: RGB8 → RGB565, each pixel and line doubled (640x480), written to the
PROC slot at x 640..1279, y 120..599.  Lines 0..119 and 600..719 of the
right half are written black, so the right half never shows stale memory.

Pre box average: `avg = (sum9 * 455 + 2075) >> 12` (= round(sum9 / 9) for every sum) per channel of the
`unpack565` RGB8 values (`vid_pkg::unpack565`).

### DDR tensor format

* HWC, pixel-major.  An element is int8, or int16 for the add outputs.
* Pixel bytes `PB = roundup16(C * elem_bytes)`, so a pixel is 1, 2, 4 or 8
  whole AXI beats.  Channel `c` sits at byte `c * elem_bytes` of the pixel,
  little-endian: byte k of a beat is bits [8k+7:8k].  Padding bytes are
  zero.
* The line stride is `W * PB`.
* Scratch from `0x0800_0000`; each point has a fixed region (generated, see
  below).

### Block engine

One datapath; a pass descriptor configures it:

```
 rd main ─ unpack ─ [2x up] ─ [+ aux (add_in)] ─ DW stage ─ PW stage ─ [+ aux (add_out)] ─ pack ─ wr
 rd aux  ─ unpack ──────────────┘                                          │
                                                                  post (pass 14) ┘
```

* **DMA**: the existing `tile_dma_rd/wr`.  A second `tile_dma_rd` reads the
  aux stream.  `axi_arb` (NR=2) merges the two readers on the one ext
  master.  `tile_dma_rd` gets a line-repeat option for the vertical 2x
  upsample (line y reads source line y/2).
* **DW stage**: 3x3 window generator over a 2-line buffer plus the
  incoming line, with reflect at all four edges and stride 1 or 2.  Modes:
  * depthwise: 4 channels per cycle, 9 taps, int9 x int8;
  * im2col: stem; emits 27 values, in index order `ic*9 + ky*3 + kx`;
  * bypass.

  The line buffer is at most 2 x 320 x 32 (or 160 x 64) 9-bit elements.
* **PW stage**: an 8-output x 16-input int8 MAC array.  One weight word
  (128 int8 = 1024 bits) per cycle comes from the PW ROM.  For each pixel it
  runs the pass's PW program (1 or 2 layers, chained through a local vector
  buffer): for each output tile of 8, for each input tile of 16, one cycle;
  then bias, requant and clamp.  Cycles per pixel are
  `ceil(Cout/8)*ceil(Cin/16)` per layer.
* **Requant**: 4 lanes of the integer f32 emulation, II = 1.  The aux add
  uses the same lane design (int9 source x 24-bit factor).
* **Parameters**: ROMs initialised with `$readmemh`, generated from the
  manifest by `tools/st_gen_params.py`:
  * PW ROM: 1024-bit words, about 400 deep (about 52 RAM10);
  * DW ROM: 4 channels x 9 taps = 288-bit words;
  * RQ ROM: per channel, bias int16, mant24 and shift.

  The generator also writes `st_net_pkg.sv`: the pass descriptor table, ROM
  bases and the DDR regions.

Estimated resources:
* DSP: PW 64 (dual int8), DW 36 (int9 single), requant and add about 24,
  so about 124 of 160.  The gray-path `rgb2yc` (56 DSP) is removed.
* RAM10: parameters about 70, line buffer about 28, three DMA FIFOs 21.
  The board has about 104 RAM10 without the accelerator: the DMA self-test
  is turned off, `ENABLE_SELFTEST=0`, which saves 14.

Estimated cycles per pass:
* stem: 8 cycles per pixel
* enc0: 16 cycles per output pixel
* enc1 and the res passes: 32 cycles per output pixel
* up0: 24 cycles per pixel
* up1a: 8 cycles per pixel (DW bound)
* up1b: 4 cycles per pixel

That is about 3.7 M cycles per frame.

### Verification

* `st_golden.py --dump` writes, per pass, the input and output tensors and
  their DDR images.
* Unit testbenches (verilator) compare each stage's output against them.
* A pass testbench loads the DDR image into `axi_mem_model`, runs one pass
  and compares the output region byte for byte.
* A full-frame testbench runs patgen → all passes → PROC slot and compares
  with the golden model's 640x720 right half.

## Consequences

* The right half shows the stylised image at 320x240, doubled, with a
  4:3 crop of the camera.  The resolution goes up later with a smaller
  network (fewer MAC per pixel) or more fusion; the engine and the pass
  table carry over.
* Weights live in on-chip ROM: one style per bitstream.  Style switching
  needs the parameters in DDR, loaded per pass through the aux reader.
* The f32 emulation keeps the hardware equal to the training repository's
  integer reference.  A model export can be checked on the board by image
  comparison, without a tolerance.
