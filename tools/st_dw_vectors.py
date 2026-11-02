#!/usr/bin/env python3
"""Test vectors for rtl/st_accel_new/engine/st_dw.sv.

One case per invocation, written into --out:

  cfg.txt    the configuration, one "name value" per line: mode w h g
             stride dw_base rq_base lo hi
  in.hex     one input beat per line: "data last eol sof", data 10 hex
             digits (lane j = bits [10j+9:10j]), flags 0 or 1
  out.hex    the expected output beats, the same flags but a 32-hex-digit
             data field: the 128-bit output word.  DW and BYPASS cases carry
             the 40-bit group beat in its low bits, IM2COL the 16 bytes
  dw.hex     depthwise weight ROM words (synthetic cases only)
  rq.hex     requant ROM words (synthetic cases only)

The expected output is the golden model's, never a second implementation:

  * DW cases use st_golden.Net.conv on the layer and the same integer
    requantisation, with the layer's own clamp.  The weights, bias and
    requant parameters are random but go through that same conv;
  * the im2col case is the stem's wide vector: byte k of beat b is element
    n = 16b + k of v[n] = xp[ic, y+ky, x+kx], n = ic*9 + ky*3 + kx, the low
    8 bits of the int8 element, zero from n = 27; xp is the input padded
    np.pad(..., mode="reflect");
  * the bypass case is the input itself.

The cases cover the shapes the guided net asks for: 80 channels (G = 20) at
W = 160, 16 and 24 channels at W = 320, 8 channels at W = 640, both strides,
and the 640x8 stem.

Usage: st_dw_vectors.py --case NAME --out DIR
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
from st_golden import Net  # noqa: E402
from st_gen_params import dw_word, hex_lines, rq_word  # noqa: E402

QMAX = 127

# the widest input grid the line store holds, one 40-bit group word per group
LINE_WORDS = 3200


# ------------------------------------------------------------------ beats
def pack(vals) -> int:
    """Four 10-bit lanes -> one 40-bit beat word."""
    w = 0
    for j, v in enumerate(vals):
        w |= (int(v) & 0x3FF) << (10 * j)
    return w


def pack_wide(elems) -> int:
    """Sixteen int8 elements -> one 128-bit output word, element 0 lowest."""
    w = 0
    for k, v in enumerate(elems):
        w |= (int(v) & 0xFF) << (8 * k)
    return w


def tensor_beats(t: np.ndarray):
    """CHW int tensor -> [(data, last, eol, sof)] in raster order."""
    c, h, w = t.shape
    g = -(-c // 4)
    out = []
    for y in range(h):
        for x in range(w):
            for gg in range(g):
                lanes = [t[4 * gg + j, y, x] if 4 * gg + j < c else 0
                         for j in range(4)]
                last = gg == g - 1
                out.append((pack(lanes), int(last),
                            int(last and x == w - 1), int(y == 0 and x == 0 and gg == 0)))
    return out


def hex_beats(beats, digits=10) -> str:
    return "".join(f"{d:0{digits}x} {la:d} {e:d} {s:d}\n" for d, la, e, s in beats)


# --------------------------------------------------------------- synthetic
class Synthetic(Net):
    """A st_golden.Net with one generated layer, so conv() and the integer
    requantisation are the golden model's, bit for bit."""

    def __init__(self, layer: dict, wts: np.ndarray):
        self.m = {}
        self.w = wts
        self.L = {"synth": layer}
        self.qmax = QMAX
        self.oqmax = QMAX
        self.use_float = False
        self.scales = {}


def random_rq(rng, cout):
    """Random but well-formed requant words: normalised mantissa, k 30..35
    (exp -11..-6, the manifest's range), int16 bias."""
    bias = rng.integers(-2**15, 2**15, cout)
    mant = rng.integers(2**23, 2**24, cout)
    k = rng.integers(30, 36, cout)
    return bias, mant, k


def rq_words(bias, mant, k):
    return [rq_word(int(bias[c]), int(mant[c]), int(k[c])) for c in range(len(bias))]


def synthetic_case(cout, w, h, stride, seed, xr=256):
    """A random int9 input (|x| < xr) and a random depthwise layer over it."""
    rng = np.random.default_rng(seed)
    x = rng.integers(-xr, xr + 1, (cout, h, w))
    wts = rng.integers(-127, 128, cout * 9)
    bias, mant, k = random_rq(rng, cout)
    layer = {
        "name": "synth", "kernel": [3, 3], "stride": [stride, stride],
        "reflect_pad": 1, "in_channels": cout, "out_channels": cout,
        "groups": cout, "weight_offset": 0, "bias_int32": [int(b) for b in bias],
        "requant": [float(int(m) * 2.0 ** (int(24 - kk) - 24))
                    for m, kk in zip(mant, k)],
        "out_relu": True, "out_unsigned": False,
    }
    net = Synthetic(layer, wts)
    y = net.conv(layer, x)
    return x, y, wts.reshape(cout, 9), bias, mant, k, [0, QMAX]


def synth_roms(cout, w2d, bias, mant, k):
    groups = -(-cout // 4)
    dww = [dw_word(w2d, g) for g in range(groups)]
    # pad to whole rq words: NB = 4, so group g starts at word 4g
    rqw = rq_words(bias, mant, k)
    rqw += [bytes(8)] * (-len(rqw) % 4)
    return hex_lines(dww), hex_lines(rqw)


# ------------------------------------------------------------ im2col, bypass
def im2col_case(w, h, seed):
    """The stem: a 3-channel input and the wide 27-element vector per pixel."""
    rng = np.random.default_rng(seed)
    x = rng.integers(-127, 128, (3, h, w))
    xp = np.pad(x, ((0, 0), (1, 1), (1, 1)), mode="reflect")
    out = []
    for y in range(h):
        for xx in range(w):
            v = [xp[ic, y + ky, xx + kx] for ic in range(3)
                 for ky in range(3) for kx in range(3)] + [0] * 5
            for b in range(2):
                out.append((pack_wide(v[16 * b: 16 * b + 16]), int(b == 1),
                            int(b == 1 and xx == w - 1),
                            int(y == 0 and xx == 0 and b == 0)))
    return x, out


def bypass_case(cout, w, h, seed):
    rng = np.random.default_rng(seed)
    x = rng.integers(-128, 128, (cout, h, w))
    return x, tensor_beats(x)


# -------------------------------------------------------------------- main
CASES = {
    "tiny":        dict(kind="synth",  cout=8,  w=6,   h=5,  stride=1, seed=1),
    "tiny_s2":     dict(kind="synth",  cout=8,  w=6,   h=4,  stride=2, seed=2),
    "tiny_w2":     dict(kind="synth",  cout=4,  w=2,   h=3,  stride=1, seed=3),
    "syn_g20":     dict(kind="synth",  cout=80, w=160, h=12, stride=1, seed=4),
    "syn_g20_s2":  dict(kind="synth",  cout=80, w=160, h=12, stride=2, seed=5),
    "syn_g4_s2":   dict(kind="synth",  cout=16, w=320, h=10, stride=2, seed=6),
    "syn_g6":      dict(kind="synth",  cout=24, w=320, h=8,  stride=1, seed=7, xr=254),
    "syn_g2_w640": dict(kind="synth",  cout=8,  w=640, h=6,  stride=1, seed=8),
    "im2col":      dict(kind="im2col", w=640, h=8, seed=9),
    "bypass":      dict(kind="bypass", cout=40, w=320, h=4, seed=10),
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True, choices=sorted(CASES))
    ap.add_argument("--out", type=Path, required=True, help="output directory")
    args = ap.parse_args()

    spec = CASES[args.case]
    args.out.mkdir(parents=True, exist_ok=True)
    rom_hex = None
    wide = True                      # every out.hex word is 128 bit

    if spec["kind"] == "synth":
        x, y, w2d, bias, mant, k, (lo, hi) = synthetic_case(
            spec["cout"], spec["w"], spec["h"], spec["stride"], spec["seed"],
            spec.get("xr", 256))
        cfg = {"mode": 0, "w": spec["w"], "h": spec["h"],
               "g": -(-spec["cout"] // 4), "stride": spec["stride"],
               "dw_base": 0, "rq_base": 0, "lo": lo, "hi": hi}
        rom_hex = synth_roms(spec["cout"], w2d, bias, mant, k)
        outs = tensor_beats(y)
    elif spec["kind"] == "im2col":
        x, outs = im2col_case(spec["w"], spec["h"], spec["seed"])
        cfg = {"mode": 1, "w": spec["w"], "h": spec["h"], "g": 1, "stride": 1,
               "dw_base": 0, "rq_base": 0, "lo": 0, "hi": QMAX}
    else:
        x, outs = bypass_case(spec["cout"], spec["w"], spec["h"], spec["seed"])
        cfg = {"mode": 2, "w": spec["w"], "h": spec["h"],
               "g": -(-spec["cout"] // 4), "stride": 1,
               "dw_base": 0, "rq_base": 0, "lo": 0, "hi": QMAX}

    ins = tensor_beats(x)
    cw, ch, cg, cst = cfg["w"], cfg["h"], cfg["g"], cfg["stride"]
    if cw * cg > LINE_WORDS:
        raise SystemExit(f"st_dw_vectors: {args.case}: w*g = {cw * cg} > {LINE_WORDS}")
    if cfg["g"] > 20:
        raise SystemExit(f"st_dw_vectors: {args.case}: G = {cg} > 20")
    if cst == 2 and (cw % 2 or ch % 2):
        raise SystemExit(f"st_dw_vectors: {args.case}: stride 2 needs even w/h")

    (args.out / "cfg.txt").write_text("".join(f"{k} {v}\n" for k, v in cfg.items()))
    (args.out / "in.hex").write_text(hex_beats(ins))
    (args.out / "out.hex").write_text(hex_beats(outs, 32 if wide else 10))
    if rom_hex is not None:
        (args.out / "dw.hex").write_text(rom_hex[0])
        (args.out / "rq.hex").write_text(rom_hex[1])

    print(f"{args.case}: {cw}x{ch} x {4 * cg} ch, mode {cfg['mode']}, stride {cst}, "
          f"{len(ins)} input beats, {len(outs)} output beats")
    return 0


if __name__ == "__main__":
    sys.exit(main())
