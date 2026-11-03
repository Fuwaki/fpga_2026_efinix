#!/usr/bin/env python3
"""Tap-stream vectors for rtl/st_accel_new/engine/st_film.sv.

Writes into --out:

  tap.hex    one line per group beat of the plane: "<data:10 hex> <last>"
             (data = 4 lanes of 10-bit two's complement, lane j at bits
             10j+9:10j; last marks the pixel's final group beat)
  coef.hex   the expected coefficient writes, one per line per group of four
             channels: "<grp> <mul0> <mul1> <mul2> <mul3> <off0> .. <off3>"
             (grp decimal, mul 5 hex digits, off 6 hex digits, two's
             complement, lane j = channel 4*grp + j)
  meta.txt   "nbeat npix cfg_g", decimal

The expected coefficients are st_guided.film_coeffs of the per-channel sums
of the tap stream, so the testbench and the golden model cannot disagree.
film_coeffs takes the sums as it computes them -- the RTL sums the same lanes
in the same order -- and every value is checked to fit the port widths.

Cases (--case):

  real    the FiLM pass input of the guided net: net.ddr[17] after
          Guided.run on g360/in/cat.png, one plane of 320x180 pixels.
  max     every code +254, 57600 pixels.
  min     every code -254.
  rand    random codes in -254..254 (seeded, so a rerun is identical).

The tap stream is the st_pack input of the pass, which carries the p17 codes
of the pixel as 10 group beats -- exactly net.ddr[17] in raster order.

Usage: st_film_vectors.py --case NAME --out DIR [--manifest DIR] [--image PNG]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_guided import Guided, film_coeffs  # noqa: E402

MANIFEST = "/data/competition/2026fpga/st_work/board_w8a8"
IMAGE = "/data/competition/2026fpga/st_work/g360/in/cat.png"
NET_H, NET_W = 360, 640
GAP_H, GAP_W = NET_H // 2, NET_W // 2          # the FiLM plane is H/2
NC, G = 40, 10                                  # channels, groups per pixel
PLANE = GAP_H * GAP_W                           # 57600
MUL_MAX = (1 << 17) - 1
OFF_MAX = (1 << 23) - 1
LANE_MAX = 254                                  # |add output| <= 254


def plane(case: str, manifest: str, image: str, style: int) -> np.ndarray:
    """(NC, H, W) int codes of the FiLM pass input."""
    if case == "real":
        net = Guided(manifest, style=style)
        rgb = np.asarray(Image.open(image).convert("RGB"))
        assert rgb.shape[:2] == (NET_H, NET_W), f"{image} is not {NET_W}x{NET_H}"
        net.run(rgb)
        x = net.ddr[17].astype(np.int64)
        assert x.shape == (NC, GAP_H, GAP_W), f"p17 is {x.shape}"
        return x
    if case == "max":
        return np.full((NC, GAP_H, GAP_W), LANE_MAX, np.int64)
    if case == "min":
        return np.full((NC, GAP_H, GAP_W), -LANE_MAX, np.int64)
    if case == "rand":
        rng = np.random.default_rng(1234)
        return rng.integers(-LANE_MAX, LANE_MAX + 1, (NC, GAP_H, GAP_W), dtype=np.int64)
    raise SystemExit(f"st_film_vectors: unknown case {case}")


def beats(x: np.ndarray):
    """(NC, H, W) -> group beats: lane j of beat b of a pixel is channel 4b+j."""
    c, h, w = x.shape
    assert c == NC
    px = x.transpose(1, 2, 0).reshape(h * w, NC)        # raster order, channels
    for p in range(h * w):
        for b in range(G):
            v = 0
            for j in range(4):
                code = int(px[p, 4 * b + j])
                assert -512 <= code <= 511, f"code {code} does not fit a lane"
                v |= (code & 0x3FF) << (10 * j)
            yield v, b == G - 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True, choices=["real", "max", "min", "rand"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--image", default=IMAGE)
    ap.add_argument("--style", type=int, default=0, help="style packet (the tb's +STYLE)")
    a = ap.parse_args()

    x = plane(a.case, a.manifest, a.image, a.style)
    net = Guided(a.manifest, style=a.style)
    spec = net.film["film_h2"]
    assert spec["in_point"] == 17 and spec["channels"] == NC
    gap_sum = x.sum((1, 2))
    assert (np.abs(gap_sum) < (1 << 24)).all(), "a GAP sum exceeds 2**24"
    # the shifts st_film has: one set for every style
    mul, off, _ = film_coeffs(spec, gap_sum, PLANE, net.film_sh["film_h2"])
    assert mul.shape == (NC,) and off.shape == (NC,)
    assert (np.abs(mul) <= MUL_MAX).all() and (np.abs(off) <= OFF_MAX).all()

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    nbeat = 0
    with open(out / "tap.hex", "w") as fh:
        for v, last in beats(x):
            fh.write(f"{v:010x} {int(last)}\n")
            nbeat += 1
    assert nbeat == PLANE * G, f"{nbeat} beats for {PLANE} pixels"
    with open(out / "coef.hex", "w") as fh:
        for grp in range(NC // 4):
            m = " ".join(f"{int(mul[4*grp + j]) & 0x3FFFF:05x}" for j in range(4))
            o = " ".join(f"{int(off[4*grp + j]) & 0xFFFFFF:06x}" for j in range(4))
            fh.write(f"{grp} {m} {o}\n")
    (out / "meta.txt").write_text(f"{nbeat} {PLANE} {G}\n")
    print(f"st_film_vectors: {a.case} style {a.style}: {nbeat} beats, {PLANE} pixels, "
          f"mul {int(mul.min())}..{int(mul.max())}, off {int(off.min())}..{int(off.max())}")


if __name__ == "__main__":
    main()
