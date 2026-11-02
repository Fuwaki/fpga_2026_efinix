#!/usr/bin/env python3
"""Test vectors for st_unpack, st_pack and st_add (sim/tb/tb_st_io.sv,
sim/tb/tb_st_add.sv).

Tensors are real activations: st_golden.Net.run on an image (default
/tmp/stgold/in2/c0.png, else a deterministic synthetic 320x240 image),
cached under --cache.  Each case writes into --out/NAME:

  args        plusargs for the testbench (geometry, factor)
  in.hex      unpack: DDR beats    "<32 hex> sof eol"
              pack:   group beats  "<10 hex> last eol sof"
  t.hex a.hex add: trunk and aux group beats
  out.hex     expected output, same formats

DDR beats are st_golden.ddr_image, so the layout is the one the golden
model and the generator agree on.  Only the first lines of each tensor are
used, to keep simulation short.

Usage: st_io_vectors.py --out DIR [--image PNG] [--cache DIR] [--lines N]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import Net, WIDE_POINTS, ddr_image, f32_parts  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "config/manifest/ink_dw_w8a8"


def image(path: Path) -> np.ndarray:
    if path.exists():
        return np.asarray(Image.open(path).convert("RGB"))
    yy, xx = np.mgrid[0:240, 0:320]
    rgb = np.stack([xx * 255 // 319, yy * 255 // 239, ((xx // 40 + yy // 30) % 2) * 200 + 20], -1)
    return rgb.astype(np.uint8)


def golden(img: Path, cache: Path) -> Path:
    """Run the golden model once; the pass dumps land in cache."""
    stamp = cache / "stamp.json"
    key = {"image": str(img), "exists": img.exists()}
    if stamp.exists() and json.loads(stamp.read_text()) == key:
        return cache
    cache.mkdir(parents=True, exist_ok=True)
    Net(str(MANIFEST), False).run(image(img), str(cache))
    stamp.write_text(json.dumps(key))
    return cache


# ------------------------------------------------------------------ formats
def groups(t: np.ndarray) -> list[str]:
    """CHW tensor -> group beats, raster order, lanes beyond C zero."""
    c, h, w = t.shape
    g_n = -(-c // 4)
    pad = np.zeros((g_n * 4, h, w), np.int64)
    pad[:c] = t
    rows = []
    for y in range(h):
        for x in range(w):
            for g in range(g_n):
                v = 0
                for j in range(4):
                    v |= (int(pad[4 * g + j, y, x]) & 0x3FF) << (10 * j)
                last = g == g_n - 1
                rows.append(f"{v:010x} {int(last)} {int(last and x == w - 1)} "
                            f"{int(y == 0 and x == 0 and g == 0)}")
    return rows


def beats(t: np.ndarray, pt: int, line_rep: int = 1) -> list[str]:
    """CHW tensor -> its DDR beats (st_golden.ddr_image), each image line
    repeated line_rep times as tile_dma_rd's line_shift delivers it."""
    c, h, w = t.shape
    raw = np.frombuffer(ddr_image(t, pt), np.uint8).reshape(h, -1, 16)
    rows = []
    first = True
    for y in range(h):
        for _ in range(line_rep):
            n = raw.shape[1]
            for b in range(n):
                v = int.from_bytes(raw[y, b].tobytes(), "little")
                rows.append(f"{v:032x} {int(first)} {int(b == n - 1)}")
                first = False
    return rows


def pb(c: int, pt: int) -> int:
    e = 2 if pt in WIDE_POINTS else 1
    return -(-c * e // 16) * 16


def write(d: Path, args: str, **files: list[str]) -> None:
    d.mkdir(parents=True, exist_ok=True)
    (d / "args").write_text(args + "\n")
    for k, rows in files.items():
        (d / f"{k}.hex").write_text("\n".join(rows) + "\n")


# -------------------------------------------------------------------- cases
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--image", type=Path, default=Path("/tmp/stgold/in2/c0.png"))
    ap.add_argument("--cache", type=Path, default=ROOT / "sim/obj/st_golden_c0")
    ap.add_argument("--lines", type=int, default=16)
    a = ap.parse_args()

    d = golden(a.image, a.cache)
    ld = lambda n: np.load(d / f"{n}.npy").astype(np.int64)  # noqa: E731
    net = Net(str(MANIFEST), False)
    n = a.lines
    m = json.loads((MANIFEST / "manifest.json").read_text())
    sc = m["point_scales"]

    # unpack: (case, tensor, point, hrep)
    p21 = ld("res3b_out")
    for name, t, pt, hrep in (("unpack_p1", ld("stem_out")[:, :n], 1, 0),
                              ("unpack_p9", ld("res0b_out")[:, :n], 9, 0),
                              ("unpack_p0", ld("stem_in")[:, :n], 0, 0),
                              ("unpack_p21_hrep", p21[:, :n // 2], 21, 1)):
        c, h, w = t.shape
        exp = t.repeat(2, axis=1).repeat(2, axis=2) if hrep else t
        write(a.out / name,
              f"+MODE=0 +C={c} +ELEM2={int(pt in WIDE_POINTS)} +PB={pb(c, pt)} "
              f"+W={w} +H={exp.shape[1]} +HREP={hrep}",
              **{"in": beats(t, pt, 2 if hrep else 1), "out": groups(exp)})

    for name, t, pt in (("pack_p3", ld("enc0_out")[:, :n], 3),
                        ("pack_p9", ld("res0b_out")[:, :n], 9),
                        ("pack_p27", ld("up1a_out")[:, :n], 27)):
        c, h, w = t.shape
        write(a.out / name,
              f"+MODE=1 +C={c} +ELEM2={int(pt in WIDE_POINTS)} +PB={pb(c, pt)} "
              f"+W={w} +H={h} +HREP=0",
              **{"in": groups(t), "out": beats(t, pt)})

    # add: trunk, aux, expected, factor (src -> dst)
    L = net.L
    tr = net.conv(L["res.0.s2.pw"], net.conv(L["res.0.s2.dw"], ld("res0b_in")))
    p21u = p21.repeat(2, axis=1).repeat(2, axis=2)
    for name, t, aux, exp, src, dst in (
            ("add_res0", tr[:, :n], ld("enc1_out")[:, :n], ld("res0b_out")[:, :n], 5, 9),
            ("add_skip", p21u[:, :n], ld("enc0_out")[:, :n], ld("up0_in")[:, :n], 3, 21)):
        f = np.float32(sc[src]) / np.float32(sc[dst])
        mant, e = f32_parts(f)
        # the vectors must be the golden add, not a re-derivation of it
        assert (net.add_requant(aux, src, dst) + t == exp).all(), name
        write(a.out / name, f"+MANT={mant:x} +K={24 - e}",
              t=groups(t), a=groups(aux), out=groups(exp))

    print(f"{a.out}: st_io vectors written", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
