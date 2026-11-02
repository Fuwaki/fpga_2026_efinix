#!/usr/bin/env python3
"""Test vectors for rtl/st_accel_new/engine/st_dw.sv.

One case per invocation, written into --out:

  cfg.txt    the configuration, one "name value" per line: mode w h g
             stride dw_base rq_base lo hi
  in.hex     one input beat per line: "data last eol sof", data 10 hex
             digits (lane j = bits [10j+9:10j]), flags 0 or 1
  out.hex    the expected output beats, the same format
  dw.hex     depthwise weight ROM words (synthetic cases only)
  rq.hex     requant ROM words (synthetic cases only)

The expected output is the golden model's, never a second implementation:

  * DW cases use st_golden.Net.conv on the layer and the same integer
    requantisation, with the layer's own clamp;
  * the synthetic DW cases build a Net whose weights, bias and requant
    parameters are random but go through that same conv;
  * the im2col case is the stem's 27-element vector, built from
    np.pad(..., mode="reflect") in the PW ROM lane order
    (n = ic*9 + ky*3 + kx);
  * the bypass case is the input itself.

The real cases read the pass dumps of a full st_golden.Net.run, so the
input is the tensor the pass would have read from DDR.  Without
/tmp/stgold/in2/c0.png the image is a deterministic synthetic 320x240
picture (gradients and hard edges); the testbench compares with the golden
model either way, so the vectors stay exact.

Usage: st_dw_vectors.py --case NAME --out DIR [--dump DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
from st_golden import Net, f32_parts  # noqa: E402
from st_gen_params import dw_word, hex_lines, rq_word  # noqa: E402

MANIFEST = ROOT / "config/manifest/ink_dw_w8a8"
GEN = ROOT / "rtl/st_accel_new/gen/tiny_dw"
IMAGE = Path("/tmp/stgold/in2/c0.png")
IMG_W, IMG_H = 320, 240
QMAX = 127

KIND_DW, KIND_IM2COL = "dw", "im2col"


# ------------------------------------------------------------------ beats
def pack(vals) -> int:
    """Four 10-bit lanes -> one 40-bit beat word."""
    w = 0
    for j, v in enumerate(vals):
        w |= (int(v) & 0x3FF) << (10 * j)
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


def hex_beats(beats) -> str:
    return "".join(f"{d:010x} {la:d} {e:d} {s:d}\n" for d, la, e, s in beats)


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


def synthetic_case(cout, w, h, stride, seed):
    """A random int9 input and a random depthwise layer over it."""
    rng = np.random.default_rng(seed)
    x = rng.integers(-256, 256, (cout, h, w))
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


# ------------------------------------------------------------------- real
def load_image():
    from PIL import Image
    if IMAGE.exists():
        return np.asarray(Image.open(IMAGE).convert("RGB"))
    y, x = np.mgrid[0:IMG_H, 0:IMG_W]
    r = (x * 255 // (IMG_W - 1)).astype(np.uint8)
    g = (y * 255 // (IMG_H - 1)).astype(np.uint8)
    b = ((x // 40 + y // 40) % 2 * 255).astype(np.uint8)
    rgb = np.stack([r, g, b], axis=-1)
    rgb[100:140, 20:300] = 0                 # hard edges
    rgb[160:200, 60:260] = np.array([255, 255, 255], np.uint8)
    return rgb


def dumps(dumpdir: Path):
    """The full network's pass dumps, computed once and cached."""
    if not (dumpdir / "up1b_out.npy").exists():
        dumpdir.mkdir(parents=True, exist_ok=True)
        Net(str(MANIFEST), use_float=False).run(load_image(), str(dumpdir))
    return dumpdir


PASS_OF_LAYER = {
    "enc.0.dw": "enc0", "res.1.s1.dw": "res1a", "head.dw": "up1b",
    "stem": "stem", "head.pw": "up1b",
}


def real_case(layer_name, dumpdir: Path, mode):
    net = Net(str(MANIFEST), use_float=False)
    l = net.L[layer_name]
    # the generated table carries the ROM bases and the clamp code (st_net.json
    # is the same table st_net_pkg.sv encodes)
    g = layer_cfg_from_json(layer_name)
    pname = PASS_OF_LAYER[layer_name]
    x = np.load(dumpdir / f"{pname}_in.npy").astype(np.int64)
    cfg = {
        "mode": mode,
        "w": x.shape[2], "h": x.shape[1], "g": -(-x.shape[0] // 4),
        "stride": l["stride"][0] if mode == 0 else 1,
        "dw_base": g["dw_base"], "rq_base": g["rq_base"],
        "lo": g["lo"], "hi": g["hi"],
    }
    if mode == 0:
        y = net.conv(l, x)
    elif mode == 1:
        assert x.shape[0] == 3 and cfg["g"] == 1
        y = None                      # built straight from the padded input
    else:
        y = x
    return x, y, cfg


def im2col_expected(x: np.ndarray):
    """The stem's 27-element vector per output pixel: v[n] = xp[ic, y+ky, x+kx]."""
    c, h, w = x.shape
    assert c == 3
    xp = np.pad(x, ((0, 0), (1, 1), (1, 1)), mode="reflect")
    out = []
    g = 1
    for y in range(h):
        for xx in range(w):
            v = [xp[ic, y + ky, xx + kx] for ic in range(c)
                 for ky in range(3) for kx in range(3)] + [0]
            for b in range(7):
                lanes = v[4 * b: 4 * b + 4]
                last = b == 6
                out.append((pack(lanes), int(last), int(last and xx == w - 1),
                            int(y == 0 and xx == 0 and b == 0)))
            assert g == 1
    return out


def layer_cfg_from_json(layer_name):
    """dw_base / rq_base / clamp from the generated st_net.json."""
    net = json.loads((GEN / "st_net.json").read_text())
    for l in net["layers"]:
        if l["name"] == layer_name:
            return l
    raise SystemExit(f"st_dw_vectors: {layer_name} not in st_net.json")


# -------------------------------------------------------------------- main
CASES = {
    "tiny":     dict(kind="synth", cout=8, w=6,  h=5, stride=1, seed=1),
    "tiny_s2":  dict(kind="synth", cout=8, w=6,  h=4, stride=2, seed=2),
    "tiny_w2":  dict(kind="synth", cout=4, w=2,  h=3, stride=1, seed=3),
    "dw_enc0":  dict(kind="real",  layer="enc.0.dw",     mode=0),
    "dw_res1":  dict(kind="real",  layer="res.1.s1.dw",  mode=0),
    "dw_head":  dict(kind="real",  layer="head.dw",      mode=0),
    "im2col":   dict(kind="real",  layer="stem",         mode=1),
    "bypass":   dict(kind="real",  layer="head.pw",      mode=2),
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True, choices=sorted(CASES))
    ap.add_argument("--out", type=Path, required=True, help="output directory")
    ap.add_argument("--dump", type=Path, default=ROOT / "sim/obj/st_dw_dump",
                    help="pass dump directory of the golden run")
    args = ap.parse_args()

    spec = CASES[args.case]
    args.out.mkdir(parents=True, exist_ok=True)
    rom_hex = None

    if spec["kind"] == "synth":
        x, y, w2d, bias, mant, k, (lo, hi) = synthetic_case(
            spec["cout"], spec["w"], spec["h"], spec["stride"], spec["seed"])
        cfg = {"mode": 0, "w": spec["w"], "h": spec["h"],
               "g": -(-spec["cout"] // 4), "stride": spec["stride"],
               "dw_base": 0, "rq_base": 0, "lo": lo, "hi": hi}
        rom_hex = synth_roms(spec["cout"], w2d, bias, mant, k)
        outs = tensor_beats(y)
    else:
        dd = dumps(args.dump)
        x, y, cfg = real_case(spec["layer"], dd, spec["mode"])
        outs = tensor_beats(y) if y is not None else im2col_expected(x)

    ins = tensor_beats(x)
    cw, ch, cg, cst = cfg["w"], cfg["h"], cfg["g"], cfg["stride"]
    if cw * cg > 2560:
        raise SystemExit(f"st_dw_vectors: {args.case}: w*g = {cw * cg} > 2560")
    if cst == 2 and (cw % 2 or ch % 2):
        raise SystemExit(f"st_dw_vectors: {args.case}: stride 2 needs even w/h")

    (args.out / "cfg.txt").write_text("".join(f"{k} {v}\n" for k, v in cfg.items()))
    (args.out / "in.hex").write_text(hex_beats(ins))
    (args.out / "out.hex").write_text(hex_beats(outs))
    if rom_hex is not None:
        (args.out / "dw.hex").write_text(rom_hex[0])
        (args.out / "rq.hex").write_text(rom_hex[1])

    print(f"{args.case}: {cw}x{ch} x {4 * cg} ch, mode {cfg['mode']}, stride {cst}, "
          f"{len(ins)} input beats, {len(outs)} output beats")
    return 0


if __name__ == "__main__":
    sys.exit(main())
