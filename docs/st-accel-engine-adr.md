# ADR: ST Accelerator DDR-Resident Graph Execution Engine

Date: 2026-11-02
Status: Accepted (user-approved multi-pass layer-loop approach)

## Context

The 15-layer tiny_dw_guided style-transfer graph cannot run as a single
stream-through pass because intermediate feature maps (up to 480×480×20
int8 = 4.5 MB) far exceed on-chip BRAM (~160 KB usable). The current
`st_accel_wrapper` is a single-pass stream (DMA→rgb2yc→engine stub→DMA)
that only works for one layer at a time.

Three blocking bugs prevent the existing `tile_engine` from synthesizing
with real DSP usage:
1. `pw_conv1x1.sv:173` connects `.right_shift(requant_shift)` but
   `requant.sv` now has `mult [MAC_ROWS][15:0]` (per-channel uint16
   multiplier = round(requant_fp × 2^16)), not a shift field.
2. `tile_engine.sv:99` references `desc.out_scale_shift[5:0]` but
   `layer_desc_t` now has `requant_bram_addr`, not `out_scale_shift`.
3. `pw_conv1x1` uses static-parameter `weight [OUT_CHANNELS][IN_CHANNELS]`
   array ports — cannot handle 15 layers with varying channel counts
   (2→16, 16→32, 32→12, 12→20, 20→4, 4→3).

## Decision

Build a **multi-pass layer-loop engine** where the wrapper is a sequencer
that drives one layer at a time: DMA reads the input feature map from DDR,
the engine computes one layer, DMA writes the output back to DDR.

### DDR scratch layout (ACCEL_SCRATCH_BASE = 0x0800_0000)

| Buffer   | Base       | Size | Content                  |
|----------|------------|------|--------------------------|
| BUF_A    | 0x08000000 | 4MB  | stem out 480×480×16       |
| BUF_B    | 0x08400000 | 1MB  | enc0dw out 240×240×16    |
| BUF_C    | 0x08500000 | 2MB  | enc0pw/enc1pw/decdw4     |
| BUF_D    | 0x08700000 | 2MB  | enc1dw/decpw4-tmp        |
| BUF_E    | 0x08900000 | 1MB  | decpw4 out 240×240×12    |
| BUF_F    | 0x08A00000 | 3MB  | upsamp/decdw2            |
| BUF_G    | 0x08D00000 | 3MB  | decdw2 out 480×480×12    |
| BUF_H    | 0x09000000 | 5MB  | decpw2 out 480×480×20   |
| BUF_I    | 0x09500000 | 2MB  | h2guide out 480×480×5   |
| BUF_J    | 0x09700000 | 5MB  | h2proj out 480×480×20   |
| BUF_K    | 0x09C00000 | 1MB  | toguide out 480×480×4   |
| BUF_L    | 0x09D00000 | 1MB  | guide out 480×480×4     |
| BUF_M    | 0x09E00000 | 1MB  | headdw out 480×480×4    |
| **Total** |           | **31MB** | ends at 0x09F00000   |

YC input (480×480×2 = 450KB) is written to a pinned location
(0x07800000) by the pre-pass and read by guide-branch layers 9,12.

### Pass schedule

```
Pass 0:  ISP ring → rgb2yc → BUF_YC (pinned)
Pass 1:  BUF_YC → stem(conv3x3)    → BUF_A
Pass 2:  BUF_A  → enc0.dw(dw,s2)  → BUF_B    [A freed]
Pass 3:  BUF_B  → enc0.pw(pw)     → BUF_C    [B freed]
Pass 4:  BUF_C  → enc1.dw(dw)     → BUF_D    [C freed]
Pass 5:  BUF_D  → enc1.pw(pw)     → BUF_C    [D freed, reuse C]
Pass 6:  BUF_C  → dec_h4.dw(dw)   → BUF_D    [C freed]
Pass 7:  BUF_D  → dec_h4.pw(pw)   → BUF_E    [D freed]
Pass 8:  BUF_E  → upsample(2x)    → BUF_F    [E freed]   ← phase 2
Pass 9:  BUF_F  → dec_h2.dw(dw)   → BUF_G    [F freed]
Pass 10: BUF_G  → dec_h2.pw(pw)   → BUF_H    [G freed]
--- guide branch (phase 2) ---
Pass 11: BUF_YC → h2_guide(conv3x3) → BUF_I
Pass 12: BUF_I  → h2_proj(pw)       → BUF_J  [I freed]
Pass 13: BUF_H+BUF_J → to_guide(add+pw) → BUF_K  [H,J freed]
Pass 14: BUF_YC → guide(conv3x3)    → BUF_L  [YC freed]
Pass 15: BUF_K+BUF_L → head.dw(add+dw) → BUF_M  [K,L freed]
Pass 16: BUF_M → head.pw(pw) → PROC ring (RGB565)
```

### Phase 1 (this work): linear trunk passes 1-10

Only conv/dw/pw operators. Upsample (pass 8) is a simple 2× nearest-neighbor
replication done in the wrapper as a DMA pass with address arithmetic.
Guide branch (passes 11-16) deferred to phase 2.

### Weight loading architecture

Weights are stored in a flat int8 BRAM (3666 bytes, initialized via
`$readmemh`). Each layer's weights start at `desc.weight_bram_addr`.

For PW (1×1): weight layout is [out_c][in_c] row-major.
At each output tile (8 output channels), preload 8 × in_c weights into a
local register file (max 8×32 = 256 int8 = 256 FFs), then stream input
pixels through mac_array. Preload takes in_c cycles per output-tile-row
(8 reads/cycle from a wide BRAM port, or sequential with a 64-bit port).

For DW (3×3): weight layout is [kh][kw][out_c].
Only 9 × out_c weights per layer (max 9×32 = 288 int8). Preload all at
layer start into a register file.

### requant interface

`requant.sv` takes `mult [MAC_ROWS][15:0]` (per-channel uint16) and
`bias [MAC_ROWS][31:0]` (per-channel int32). Both are read from BRAM
at the addresses in `desc.requant_bram_addr` and `desc.bias_bram_addr`.
The engine loads the current output tile's 8 bias + 8 mult values at
tile start.

## Consequences

- Wrapper becomes a state machine driving ~10 passes per frame.
- Each pass: set DMA in/out addresses + layer desc → start engine →
  wait done → advance.
- Engine is a single-layer executor, not a 15-layer FSM.
- DSP count should reach 32 (mac_array) after this phase.
- Estimated frame time: ~150ms (8 PW layers × ~9ms + DW layers) → ~6fps
  before optimization. 1fps smoke test is comfortably achievable.
