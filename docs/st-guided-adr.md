# ADR: the guided network on the ST block engine (640x360)

Date: 2026-11-03
Status: Accepted.  Builds on docs/st-accel-engine-adr.md (the 15-pass
tiny_dw engine, board milestone 9597993), which it replaces on branch
feat/st-guided.

## Context

The board runs tiny_dw at 320x240, ~20.5 fps.  The new model is
fpga_st_train `experiments/tiny_dw_whitebox_480p_prune90/trials/ln`
(tiny_dw_guided), exported W8A8 to `st_work/p90_ln_w8a8`: an encoder at
H/4 (80 channels, one residual block, LayerNorm), a decoder back up to H/2
with a FiLM layer driven by global statistics, and two guide branches that
inject full- and half-resolution detail.  28,334 weight bytes, ~2.55k MAC
per output pixel.  It is the first guided architecture on the FPGA.

## Decision

* **Resolution 640x360.**  The camera frame (1280x720) is box-averaged 2x2
  into the network input, and the output is replicated 2x2 over the whole
  PROC slot: pixel-aligned with the camera, correct aspect, 25% less work
  than 640x480.
* **12 passes** through the same block engine, extended with: a 2x2 pre
  with a pool mode, a 2x2 post, a norm stage (LayerNorm and the FiLM
  affine), a GAP tap plus a FiLM MLP sequencer, a 16-byte-wide im2col path
  from the DW stage to the PW array, and stages widened to 80 channels.

### Numerics

`tools/st_guided.py` is the golden model; every RTL test compares with it
bit for bit.  conv / requant / add / upsample are intref's integer
semantics exactly as in st_golden.py.  Three ops that intref computes in
f32 get integer definitions (st_guided.py is normative):

* pre: `avg = (sum of the 2x2 RGB8 values + 2) >> 2`, then `LUT0[avg]`.
* avg_pool2x: `(sum of the 4 codes + 2) >> 2`.
* layer_norm (per pixel, N = 80 channels, x the int9 codes):
  `S = Σx, Q = Σx², D = N·Q − S² + E` (E = 1);
  `e = (bitlen(D) + 1) >> 1`, `m = D·2^(10−2e)` (floor), m in [256, 1024);
  `R = LUT[m − 256]` (768 x 17 bit, `round(2^20 / sqrt(m + 0.5))`);
  `u = N·x − S`; `t = (u·R + 2^(e+2)) >> (e+3)`;
  `y = clamp((t·Gc + Bc + 2^21) >> 22, ±127)`.
* film: per-channel code sums S of the whole input (GAP), an integer MLP
  (`film_coeffs`) giving per channel `mul` (18 bit) and `off` (24 bit), and
  `y = clamp((x·mul + off + 2^14) >> 15, ±127)`.

The `--ref` mode runs intref's f32 ops instead and matches intref.  On six
demo images at 640x360 the integer definitions cost at most 0.08 dB
against fp32 (intref vs fp32: 36.7..41.6 dB).

Value ranges (worst case unless noted): codes ±127, add outputs ±254;
LN: |S| ≤ 20320, Q < 2^23, D < 2^29, e ≤ 15, |u| < 2^16, |t| < 2^16,
|G| < 2^16, |B| < 2^26; FiLM: |S| < 2^24 per channel (320x180 x 254).

### Passes

Points are the manifest's.  H = 640x360, H2 = 320x180, H4 = 160x90.

| # | name   | main in        | aux      | on chip                                   | out |
|---|--------|----------------|----------|-------------------------------------------|-----|
| 0 | pool   | ISP slot       |          | pre POOL (4x4 → p0 codes → pool)          | p1 H2x3 |
| 1 | guide  | ISP slot       |          | pre FULL → im2col → PW 27→8               | p20 Hx8 |
| 2 | stem   | p1             |          | im2col → PW 27→16                         | p2 H2x16 |
| 3 | h2g    | p1             |          | im2col → PW 27→10 → PW 10→40              | p16 H2x40 |
| 4 | enc0   | p2             |          | DW s2 → PW 16→80                          | p4 H4x80 |
| 5 | enc1   | p4             |          | DW → PW 80→80                             | p6 |
| 6 | res_a  | p6             |          | DW → PW 80→80                             | p8 |
| 7 | res_b  | p8             | p6       | DW → PW 80→80 → + rq(aux)                 | p10 (int16) |
| 8 | dec_h4 | p10            |          | LN → DW → PW 80→24                        | p13 H4x24 |
| 9 | dec_h2 | p13 (2x up)    | p16      | DW → PW 24→40 → + rq(aux), GAP tap        | p17 H2x40 (int16) |
| – | mlp    |                |          | FiLM MLP: GAP sums → mul/off per channel  | |
| 10| film   | p17            |          | FiLM → bypass → PW 40→8                   | p19 H2x8 |
| 11| head   | p19 (2x up)    | p20      | + rq(aux) → DW → PW 8→3 (u8) → post 2x2   | PROC slot |

The ISP slot is released after pass 1.  p0 never goes to DDR.

Cycles at 100 MHz (4-lane stream, PW = max(Σ NO·NI, 2·Σ NO) per pixel):
pool ~0.29M, guide ~0.46M (wide im2col: 2 cycles/px), stem 0.23M, h2g
0.81M, enc0 0.29M, enc1/res_a/res_b 0.72M each, dec_h4 0.29M, dec_h2
0.58M, film 0.58M, head 0.46M: **~6.0M cycles, ~16.7 fps** (DDR may add).
DDR ~49 MB/frame.  Later: 125 MHz, narrower DDR packing of small tensors.

### Stage changes

* **st_pre**: 2x2 box, no multiplier; output is a group stream (lanes 0..2
  = R, G, B codes, one beat per pixel).  FULL: 640x360 pixels into the DW
  stage.  POOL: 320x180 pixels of `pool(p0)` into st_pack.
* **st_post**: 2x2 replication of 640x360 (REP_X = REP_Y = 2).
* **st_unpack / st_pack**: C ≤ 80, PB ≤ 160 (10 beats per pixel).
* **st_dw**: G ≤ 20, line store W·G ≤ 3200 words; IM2COL emits two
  128-bit beats per pixel on a new `out_wide` port (byte k of beat b =
  element 16b + k, n = ic·9 + ky·3 + kx, zero from 27).
* **st_pw**: cin ≤ 80 (collector 2 x 80 bytes); cfg_wide takes 16 bytes per
  beat from `in_wide`; cfg_npix 18 bits.
* **st_norm** (new, between the add IN position and the DW input): modes
  LN and FILM, one beat per cycle, ≤ 9 DSP.  The FILM coefficients are
  written by st_film.
* **st_film** (new): GAP accumulators tapped at the st_pack input of pass
  9; after the pass, a serial sequencer computes `film_coeffs` (≤ 1 DSP)
  and writes mul/off into st_norm.

Budget: PW ROM 204 words (26 RAM10, was 52), DW ROM 92 words; DSP about
152 − 3 (pre) + 9 (norm) + 1 (film) = 159 of 160.
