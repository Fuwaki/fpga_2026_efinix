#!/usr/bin/env python3
"""Full-frame vectors for sim/tb/tb_st_engine.sv.

A deterministic 1280x720 camera frame (or --frame PNG) goes through
st_guided's board path (RGB565, 2x2 pre, the guided network, 2x2 post).  Written into --out,
one 128-bit beat per line as 32 hex digits (byte 0 in the low bits, the AXI
order):

  frame.hex   the ISP slot, 160 beats per line, 720 lines
  p{N}.hex    the DDR image of every point as its producer pass writes it
              (Guided.ddr, Guided.ddr_image), contiguous from the region base
  proc.hex    the PROC slot, 160 beats per line, 720 lines

Usage: st_engine_vectors.py --out DIR [--frame PNG]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_guided import CAM_H, CAM_W, Guided, post, pre, to565  # noqa: E402

MANIFEST = Path("/data/competition/2026fpga/st_work/p90_ln_w8a8")


def synth_frame() -> np.ndarray:
    """Smooth gradients, a ring pattern, colour bars and hard edges, so every
    layer sees structure at several scales."""
    yy, xx = np.mgrid[0:CAM_H, 0:CAM_W].astype(np.float64)
    r = 128 + 100 * np.sin(xx / 37.0) * np.cos(yy / 53.0)
    g = 255 * yy / (CAM_H - 1)
    b = 128 + 110 * np.sin(np.hypot(xx - 640, yy - 360) / 19.0)
    rgb = np.stack([r, g, b], -1)
    bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    for i, c in enumerate(bars):                       # bars across the bottom
        rgb[600:700, 160 + 120 * i:160 + 120 * (i + 1)] = c
    rgb[100:300, 300:320] = 0                          # thin dark strokes
    rgb[200:202, 300:1000] = 255
    return np.clip(np.rint(rgb), 0, 255).astype(np.uint8)


def hexbeats(raw: bytes) -> str:
    a = np.frombuffer(raw, np.uint8).reshape(-1, 16)
    return "".join(f"{int.from_bytes(b.tobytes(), 'little'):032x}\n" for b in a)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--frame", type=Path)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)

    cam = (np.asarray(Image.open(a.frame).convert("RGB")) if a.frame else synth_frame())
    assert cam.shape[:2] == (CAM_H, CAM_W), f"frame must be {CAM_W}x{CAM_H}"
    f565 = to565(cam)
    rgb = pre(f565)
    dump = a.out / "npy"
    dump.mkdir(exist_ok=True)
    y = Guided(str(MANIFEST)).run(rgb, str(dump))
    proc = post(y)

    (a.out / "frame.hex").write_text(hexbeats(f565.astype("<u2").tobytes()))
    (a.out / "proc.hex").write_text(hexbeats(proc.astype("<u2").tobytes()))
    for f in sorted(dump.glob("p*.bin")):
        (a.out / f"{f.stem}.hex").write_text(hexbeats(f.read_bytes()))
    Image.fromarray(cam).save(a.out / "frame.png")
    print(f"{a.out}: st_engine vectors written", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
