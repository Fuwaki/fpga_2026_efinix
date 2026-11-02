#!/usr/bin/env python3
"""Vectors for rtl/st_accel_new/engine/st_pre.sv and st_post.sv.

Writes into --out, for the full frame (1280x720 ISP slot -> p0 -> 1280x720
PROC slot, docs/st-accel-engine-adr.md):

  pre_in.hex     the ISP frame as tile_dma_rd delivers it: 160 beats per line,
                 720 lines, 128-bit beats, RGB565 little-endian, 8 px per
                 beat, pixel 0 in bits [15:0].
  pre_exp.hex    p0 = st_golden.ddr_image(quantize_input(pre(frame)), 0): 320
                 beats per line, 240 lines, one beat per pixel, bytes 0..2 =
                 q of R, G, B, the rest zero.
  post_in.hex    the head output as the engine's group stream: one beat per
                 pixel, 320x240, lanes 0..2 = R, G, B (0..255).
  post_exp.hex   st_golden.post(): the PROC slot, 160 beats per line, 720
                 lines, 2 source pixels x 4 per beat.

Beat files hold "%032h <sof> <eol>" per line; the group-beat file holds
"%010h <last> <sof> <eol>".  Every expected beat comes from tools/st_golden.py
itself, so the RTL is compared with the model rather than with a second
implementation of it.

The camera frame is deterministic: --frame takes a real 1280x720 PNG, without
it the synthetic frame below (gradients, colour bars, hard edges, 1..3 px
lines) is built and also saved as frame.png for inspection.

Usage: st_prepost_vectors.py --out DIR [--frame cam.png] [--manifest DIR]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import CAM_H, CAM_W, Net, ddr_image, post, pre, to565  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "config/manifest/ink_dw_w8a8"
BEAT_PIX = 8
OUT_PX = 320            # p0 pixels per line == head pixels per line


# ---------------------------------------------------------------- the frame
def synth_frame() -> np.ndarray:
    """Deterministic 1280x720 RGB: gradients (bit order), colour bars (channel
    order), hard edges and 1/2/3-px lines (the 4x3 box average sees every
    phase), a moving band (nothing is cached)."""
    h, w = CAM_H, CAM_W
    y = np.arange(h, dtype=np.int32)[:, None]
    x = np.arange(w, dtype=np.int32)[None, :]
    img = np.zeros((h, w, 3), np.uint8)

    # rows 0..239: two-axis gradient over a blue ramp
    g = slice(0, 240)
    gx = (x * 255 // (w - 1))[0]
    gy = (y * 255 // 239)[:240, 0]
    img[g, :, 0] = gx[None, :]
    img[g, :, 1] = gy[:, None]
    img[g, :, 2] = (96 + (gx[None, :] + gy[:, None]) // 2) % 256

    # rows 240..479: eight colour bars, inverted over a 4-px checker
    g = slice(240, 480)
    bars = np.array([[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
                     [0, 255, 255], [255, 0, 255], [255, 255, 255], [0, 0, 0]],
                    np.uint8)
    img[g, :, :] = bars[(x * 8 // w)[0]][None, :, :]
    m = ((x[0, :] // 4) % 2)[None, :] ^ ((y[240:480, 0] // 4) % 2)[:, None]
    img[g, :, :] = np.where(m[..., None] != 0, img[g, :, :], 255 - img[g, :, :])

    # rows 480..719: 1, 2 and 3-px lines on a mid grey, under a ramp
    g = slice(480, 720)
    base = np.full((240, w, 3), 64, np.uint8)
    base[:, :, 2] = 160
    for px, col in ((1, (255, 255, 255)), (2, (255, 128, 0)), (3, (0, 64, 255))):
        base[:, ((x[0, :] % (2 * px + 4)) < px), :] = col
    ramp = ((y[480:720, 0][:, None] * (x[0, :][None, :] // 24)) % 256).astype(np.uint8)
    base[:, :, 0] = (base[:, :, 0].astype(np.int32) + ramp // 2).astype(np.uint8)
    img[g, :, :] = base
    return img


# ------------------------------------------------------------------ writers
def beat_lines(beats: bytes, bpl: int) -> list[str]:
    """DDR bytes -> one 128-bit beat per line, with sof/eol per line."""
    out = []
    for i in range(len(beats) // 16):
        v = int.from_bytes(beats[i * 16:(i + 1) * 16], "little")
        out.append(f"{v:032x} {1 if i == 0 else 0} {1 if (i + 1) % bpl == 0 else 0}")
    return out


def group_lines(rgb: np.ndarray) -> list[str]:
    """320x240 RGB8 -> one 40-bit group beat per pixel, last on every beat."""
    h, w, _ = rgb.shape
    out = []
    for yy in range(h):
        row = rgb[yy].astype(np.int32)
        for xx in range(w):
            v = (int(row[xx, 0]) & 0x3FF) | (int(row[xx, 1]) & 0x3FF) << 10 \
                | (int(row[xx, 2]) & 0x3FF) << 20
            out.append(f"{v:010x} 1 {1 if (yy == 0 and xx == 0) else 0} "
                       f"{1 if xx == w - 1 else 0}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--frame", help="1280x720 RGB PNG; default: the synthetic frame")
    ap.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    a = ap.parse_args()

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    if a.frame:
        from PIL import Image
        frame = np.asarray(Image.open(a.frame).convert("RGB"))
        assert frame.shape[:2] == (CAM_H, CAM_W), \
            f"--frame must be {CAM_W}x{CAM_H}, got {frame.shape[1]}x{frame.shape[0]}"
    else:
        from PIL import Image
        frame = synth_frame()
        Image.fromarray(frame).save(out / "frame.png")

    rgb = pre(to565(frame))                             # 240x320x3, net input
    net = Net(a.manifest, False)
    p0 = net.quantize_input(rgb)                        # the point-0 codes

    # -------- pre: ISP slot beats in, p0 beats out
    src = to565(frame).astype("<u2").tobytes()          # 720 lines of the slot
    (out / "pre_in.hex").write_text("\n".join(beat_lines(src, CAM_W // BEAT_PIX)) + "\n")
    exp0 = ddr_image(p0, 0)
    (out / "pre_exp.hex").write_text("\n".join(beat_lines(exp0, OUT_PX)) + "\n")

    # -------- post: head output in, PROC slot out
    head = net.run(rgb).transpose(1, 2, 0).astype(np.uint8)   # 240x320x3
    assert head.shape == (240, OUT_PX, 3), head.shape
    proc = post(head)
    (out / "post_in.hex").write_text("\n".join(group_lines(head)) + "\n")
    (out / "post_exp.hex").write_text(
        "\n".join(beat_lines(proc.astype("<u2").tobytes(), CAM_W // BEAT_PIX)) + "\n")

    print(f"PASS st_prepost_vectors: {out}: "
          f"pre {len(src)//16} in / {len(exp0)//16} out beats, "
          f"post {OUT_PX*240} in / {len(proc.tobytes())//16} out beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
