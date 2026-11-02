#!/usr/bin/env python3
"""Test vectors for st_unpack, st_pack and st_add (sim/tb/tb_st_io.sv,
sim/tb/tb_st_add.sv) on the guided net at 640x360 (docs/st-guided-adr.md).

The activations are the real ones: st_guided.Guided -- the normative golden
model -- runs the whole network once on a 640x360 input, and net.ddr holds
every point exactly as its producer pass writes it to DDR.  Each case writes
into --out/NAME:

  args        plusargs for the testbench (geometry, factor)
  in.hex      unpack: DDR beats    "<32 hex> sof eol"
              pack:   group beats  "<10 hex> last eol sof"
  t.hex a.hex add: trunk and aux group beats
  out.hex     expected output, same formats

DDR beats are net.ddr_image(t, p): HWC, a pixel is roundup16(C * elem)
bytes, int16 for the points an add writes (the wide points), padding zero.
Whole tensors are used, so the stream stays the size the engine sees.

Cases:

  unpack_p10        p10  80 ch int16 (PB 160)  160x90
  unpack_p17        p17  40 ch int16 (PB  80)  320x180
  unpack_p13_hrep   p13  24 ch int8  (PB  32)  160x90, hrep (2x2 output)
  unpack_p1         p1    3 ch int8  (PB  16)  320x180
  pack_p2           p2   16 ch int8            320x180
  pack_p16          p16  40 ch int8  (PB  48)  320x180
  pack_p10          p10  80 ch int16
  pack_p17          p17  40 ch int16

  add_res   trunk = res0.s2.pw on ddr[9],  aux = ddr[6],  exp = ddr[10]
  add_h2    trunk = dec_h2.pw on dec_h2.dw on 2x ddr[13],
            aux = ddr[16], exp = ddr[17]
  add_head  trunk = 2x ddr[19], aux = ddr[20],
            exp = add_requant(ddr[20], 20, 19) + trunk

st_add is y = t + clamp(f32_mul_round(a, mant * 2**-k), -127, 127); the
factor is scale[src] / scale[dst] as st_golden.Net.add_requant derives it.

Usage: st_io_vectors.py --out DIR [--image PNG] [--manifest DIR]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import f32_parts  # noqa: E402
from st_guided import Guided  # noqa: E402

# The board work tree: the p90_ln_w8a8 export and the 640x360 test images
# (docs/st-guided-adr.md).  --manifest / --image override either.
ST_WORK = Path("/data/competition/2026fpga/st_work")
MANIFEST = ST_WORK / "p90_ln_w8a8"
IMAGE = ST_WORK / "g360/in/cat.png"


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


def beats(net: Guided, t: np.ndarray, pt: int, line_rep: int = 1) -> list[str]:
    """CHW tensor -> its DDR beats (net.ddr_image), each image line
    repeated line_rep times as tile_dma_rd's line_shift delivers it."""
    c, h, w = t.shape
    raw = np.frombuffer(net.ddr_image(t, pt), np.uint8).reshape(h, -1, 16)
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


def pb(c: int, pt: int, net: Guided) -> int:
    e = 2 if pt in net.wide else 1
    return -(-c * e // 16) * 16


def write(d: Path, args: str, **files: list[str]) -> None:
    d.mkdir(parents=True, exist_ok=True)
    (d / "args").write_text(args + "\n")
    for k, rows in files.items():
        (d / f"{k}.hex").write_text("\n".join(rows) + "\n")


# -------------------------------------------------------------------- cases
def add_case(net: Guided, d: Path, name: str, t: np.ndarray, aux: np.ndarray,
             exp: np.ndarray, src: int, dst: int) -> None:
    """t + requant(aux) must be the golden add, never a re-derivation of it."""
    assert t.shape == aux.shape == exp.shape, (name, t.shape, aux.shape, exp.shape)
    assert (net.add_requant(aux, src, dst) + t == exp).all(), name
    f = np.float32(net.scales[src]) / np.float32(net.scales[dst])
    mant, e = f32_parts(f)
    write(d / name, f"+MANT={mant:x} +K={24 - e}",
          t=groups(t), a=groups(aux), out=groups(exp))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--image", type=Path, default=IMAGE)
    ap.add_argument("--manifest", type=Path, default=MANIFEST)
    a = ap.parse_args()

    net = Guided(str(a.manifest))
    net.run(np.asarray(Image.open(a.image).convert("RGB")))
    D = net.ddr

    # ------------------------------------------------------------- unpack
    for name, pt, hrep in (("unpack_p10", 10, 0),
                           ("unpack_p17", 17, 0),
                           ("unpack_p13_hrep", 13, 1),
                           ("unpack_p1", 1, 0)):
        t = D[pt]
        c, h, w = t.shape
        exp = t.repeat(2, axis=1).repeat(2, axis=2) if hrep else t
        write(a.out / name,
              f"+MODE=0 +C={c} +ELEM2={int(pt in net.wide)} +PB={pb(c, pt, net)} "
              f"+W={w} +H={exp.shape[1]} +HREP={hrep}",
              **{"in": beats(net, t, pt, 2 if hrep else 1), "out": groups(exp)})

    # --------------------------------------------------------------- pack
    for name, pt in (("pack_p2", 2), ("pack_p16", 16),
                     ("pack_p10", 10), ("pack_p17", 17)):
        t = D[pt]
        c, h, w = t.shape
        write(a.out / name,
              f"+MODE=1 +C={c} +ELEM2={int(pt in net.wide)} +PB={pb(c, pt, net)} "
              f"+W={w} +H={h} +HREP=0",
              **{"in": groups(t), "out": beats(net, t, pt)})

    # ---------------------------------------------------------------- add
    L = net.L
    # pass 7: res0.s2.pw on ddr[9] (the s2 DW output); the add folds ddr[6] in.
    tr = net.conv(L["res0.s2.pw"], D[9])
    add_case(net, a.out, "add_res", tr, D[6], D[10], 6, 10)

    # pass 9: dec_h2.dw/pw on the 2x ddr[13], then the skip from ddr[16].
    up13 = D[13].repeat(2, axis=1).repeat(2, axis=2)
    tr = net.conv(L["dec_h2.pw"], net.conv(L["dec_h2.dw"], up13))
    add_case(net, a.out, "add_h2", tr, D[16], D[17], 16, 17)

    # pass 11: the head's add, guide branch ddr[20] onto 2x ddr[19].
    tr = D[19].repeat(2, axis=1).repeat(2, axis=2)
    exp = net.add_requant(D[20], 20, 19) + tr
    add_case(net, a.out, "add_head", tr, D[20], exp, 20, 19)

    print(f"{a.out}: st_io vectors written", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
