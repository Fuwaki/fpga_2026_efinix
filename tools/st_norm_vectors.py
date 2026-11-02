#!/usr/bin/env python3
"""Group-stream vectors for rtl/st_accel_new/engine/st_norm.sv.

Writes into --out/NAME:

  cfg.txt    "<mode> <g> <npix>": 1 LN, 2 FILM; groups per pixel; pixels
  in.hex     one group beat per line: "<data:10 hex> <last> <eol> <sof>"
  out.hex    the expected output beats, same format
  coef.txt   FILM only: one line per channel, "<mul> <off>" decimal, channel
             order 0..C-1; the testbench writes them through coef_we

Every expected value comes from tools/st_guided.py, the normative model:
ln_int for both LN cases and the model's own FiLM output for the FiLM case
(the coefficients are film_coeffs of the input's code sums, as st_film will
compute them).

Cases (--case):

  ln      the real LayerNorm of the guided net: in = net.ddr[10]
          (80 ch, 160x90) as group beats, exp = ln_int(ddr[10]) which must
          equal net.ddr[11] (asserted).
  ln_syn  2000 synthetic pixels with hand-picked statistics: all-equal
          pixels (D = 1), the +-254 extremes, big S with small D, and
          uniform random int9 codes in [-254, 254].
  film    in = net.ddr[17] (40 ch, 320x180), coefficients =
          film_coeffs(spec, ddr[17].sum((1,2)), 57600), exp = net.ddr[18].

Usage: st_norm_vectors.py --case NAME --out DIR [--manifest DIR]
                          [--image PNG] [--cache DIR]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import st_guided as G  # noqa: E402
from st_golden import Net  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = Path("/data/competition/2026fpga/st_work/p90_ln_w8a8")
DEFAULT_IMAGE = "/data/competition/2026fpga/st_work/g360/in/cat.png"

GROUP = 4                       # lanes per group beat
LN_POINT, LN_OUT = 10, 11       # trunk.sum -> trunk.norm
FILM_IN, FILM_OUT = 17, 18      # h2_add -> film_h2
FILM_PLANE = 320 * 180          # the FiLM layer's plane
SYN_PIX = 2000


def groups(t: np.ndarray) -> list[str]:
    """CHW int tensor -> group beats, raster order, lanes beyond C zero."""
    c, h, w = t.shape
    g_n = -(-c // GROUP)
    pad = np.zeros((g_n * GROUP, h, w), np.int64)
    pad[:c] = t
    rows = []
    for y in range(h):
        for x in range(w):
            for g in range(g_n):
                v = 0
                for j in range(GROUP):
                    v |= (int(pad[GROUP * g + j, y, x]) & 0x3FF) << (10 * j)
                last = g == g_n - 1
                rows.append(f"{v:010x} {int(last)} {int(last and x == w - 1)} "
                            f"{int(y == 0 and x == 0 and g == 0)}")
    return rows


def golden(img: Path, cache: Path, manifest: Path) -> Path:
    """Run the golden model once; the DDR dumps land in cache."""
    stamp = cache / "stamp.json"
    key = {"image": str(img), "exists": img.exists(), "manifest": str(manifest)}
    if stamp.exists() and json.loads(stamp.read_text()) == key:
        return cache
    cache.mkdir(parents=True, exist_ok=True)
    if img.exists():
        rgb = np.asarray(Image.open(img).convert("RGB"))
    else:
        print(f"st_norm_vectors: {img} missing, using a synthetic image")
        yy, xx = np.mgrid[0:G.NET_H, 0:G.NET_W]
        rgb = np.stack([xx * 255 // (G.NET_W - 1), yy * 255 // (G.NET_H - 1),
                        ((xx // 40 + yy // 30) % 2) * 200 + 20], -1).astype(np.uint8)
    G.Guided(str(manifest), False).run(rgb, str(cache))
    stamp.write_text(json.dumps(key))
    return cache


def write_case(out: Path, mode: int, g_n: int, x: np.ndarray, y: np.ndarray,
               coef: np.ndarray | None = None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    c, h, w = x.shape
    npix = h * w
    (out / "cfg.txt").write_text(f"{mode} {g_n} {npix}\n")
    (out / "in.hex").write_text("\n".join(groups(x)) + "\n")
    (out / "out.hex").write_text("\n".join(groups(y)) + "\n")
    if coef is not None:
        mul, off = coef
        assert len(mul) == c
        (out / "coef.txt").write_text(
            "".join(f"{int(m)} {int(o)}\n" for m, o in zip(mul, off)))


# ------------------------------------------------------------------- cases
def case_ln(out: Path, cache: Path) -> None:
    spec = SPEC["norm_layers"][0]
    x = np.load(cache / f"p{LN_POINT}.npy").astype(np.int64)
    exp = G.ln_int(x, spec, QMAX)
    ref = np.load(cache / f"p{LN_OUT}.npy").astype(np.int64)
    if not np.array_equal(exp, ref):
        sys.exit(f"st_norm_vectors: FAIL ln_int(ddr[{LN_POINT}]) != ddr[{LN_OUT}]")
    g_n = -(-x.shape[0] // GROUP)
    write_case(out, 1, g_n, x, exp)
    print(f"st_norm_vectors: ln: {x.shape[0]} ch {x.shape[2]}x{x.shape[1]}, "
          f"{g_n} groups, {x.shape[1] * x.shape[2]} pixels")


def case_ln_syn(out: Path) -> None:
    """2000 pixels whose statistics cover the ends of the LN datapath."""
    spec = SPEC["norm_layers"][0]
    n = spec["channels"]
    g_n = -(-n // GROUP)
    px = []
    # all-equal pixels: D = 1 (the LUT's first entry), S = N*c
    for c in (0, 1, 2, 127, 254, -1, -127, -254):
        px.append(np.full(n, c, np.int64))
    # the extremes: all +254, all -254, alternating, two runs
    px.append(np.full(n, 254, np.int64))
    px.append(np.full(n, -254, np.int64))
    alt = np.where(np.arange(n) % 2 == 0, 254, -254).astype(np.int64)
    px.append(alt)
    px.append(-alt)
    run = np.where(np.arange(n) < n // 2, 254, -254).astype(np.int64)
    px.append(run)
    px.append(-run)
    # one channel at each extreme, the rest at zero: small S, large Q
    for c in (254, -254):
        for k in (0, n // 2, n - 1):
            v = np.zeros(n, np.int64)
            v[k] = c
            px.append(v)
    rng = np.random.default_rng(12345)
    while len(px) < SYN_PIX:
        k = len(px) % 5
        if k == 0:
            px.append(rng.integers(-254, 255, n))
        elif k == 1:
            px.append(rng.integers(-8, 9, n))
        elif k == 2:
            px.append(rng.integers(-254, 255, n) // 2)
        elif k == 3:
            px.append(rng.integers(-254, 255, n) * (rng.integers(0, 2, n) * 2 - 1))
        else:
            px.append(rng.integers(-1, 2, n))
    px = px[:SYN_PIX]
    x = np.stack(px, 1)[:, None, :]                  # CHW, one row
    exp = G.ln_int(x, spec, QMAX)
    write_case(out, 1, g_n, x, exp)
    print(f"st_norm_vectors: ln_syn: {SYN_PIX} pixels, {g_n} groups")


def case_film(out: Path, cache: Path) -> None:
    spec = SPEC["film_layers"][0]
    x = np.load(cache / f"p{FILM_IN}.npy").astype(np.int64)
    ref = np.load(cache / f"p{FILM_OUT}.npy").astype(np.int64)
    plane = x.shape[1] * x.shape[2]
    if plane != FILM_PLANE:
        sys.exit(f"st_norm_vectors: FAIL plane {plane} != {FILM_PLANE}")
    mul, off, _ = G.film_coeffs(spec, x.sum((1, 2)), plane)
    y = (x * mul[:, None, None] + off[:, None, None]
         + (1 << (G.FILM_P - 1))) >> G.FILM_P
    exp = np.clip(y, -QMAX, QMAX)
    if not np.array_equal(exp, ref):
        sys.exit(f"st_norm_vectors: FAIL film_coeffs affine != ddr[{FILM_OUT}]")
    g_n = -(-x.shape[0] // GROUP)
    write_case(out, 2, g_n, x, exp, (mul, off))
    print(f"st_norm_vectors: film: {x.shape[0]} ch {x.shape[2]}x{x.shape[1]}, "
          f"{g_n} groups, {plane} pixels, |mul| <= {int(np.abs(mul).max())}, "
          f"|off| <= {int(np.abs(off).max())}")


def main() -> int:
    global SPEC, QMAX
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True, choices=["ln", "ln_syn", "film"])
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--image", default=DEFAULT_IMAGE)
    ap.add_argument("--cache", type=Path, default=None)
    a = ap.parse_args()

    SPEC = json.loads((a.manifest / "manifest.json").read_text())
    QMAX = int(SPEC["act_qmax"])
    cache = a.cache or (a.out.parent / "st_norm_golden")
    if a.case in ("ln", "film"):
        cache = golden(Path(a.image), cache, a.manifest)
    if a.case == "ln":
        case_ln(a.out, cache)
    elif a.case == "ln_syn":
        case_ln_syn(a.out)
    else:
        case_film(a.out, cache)
    return 0


if __name__ == "__main__":
    sys.exit(main())
