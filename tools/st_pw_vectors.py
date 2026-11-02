#!/usr/bin/env python3
"""Group-stream vectors for rtl/st_accel_new/engine/st_pw.sv.

Writes into --out:

  cfg.txt   configuration:  "<npix> <nin> <nout> <nlay>" then one line per
            layer "<cin> <cout> <pw_base> <rq_base> <lo> <hi>", decimal.
  in.hex    one group beat per line: "<data:10 hex> <last> <eol> <sof>"
  out.hex   the expected output beats, same format

The activations are the real ones: the golden model runs on the image, and a
case's input is that pass's DW layer applied to the pass input -- the tensor
the engine's DW stage really hands the PW stage (it is not a DDR point).  The
expected outputs come from st_golden.Net.conv of the case's PW layers, so the
RTL and the model cannot disagree; every case also checks that the chain
reproduces the model's own pass output.  Everything is bit exact: st_golden is
the reference (docs/st-accel-engine-adr.md).

Cases (--case), all with the engine part of the pass they belong to:

  enc0   enc.0.pw             32 -> 64
  res    res.1.s1.pw          64 -> 64   (the residual chain, clamp -127..127)
  up0    up3.0.pw + up1.0     64 -> 32 -> 32
  up1a   up3.1.pw + up1.1     32 -> 16 -> 16
  head   head.pw              16 -> 3    (unsigned clamp 0..255)
  stem   the stem over im2col 27 -> 32

The stem's input is not a tensor: the 27-value im2col vector of every pixel,
element n = ic*9 + ky*3 + kx of the reflect-padded p0 window (n = 27 is 0),
seven group beats per pixel.

Usage: st_pw_vectors.py --case NAME --out DIR [--lines N] [--image PNG]

Only the first --lines rows of the activation are used (40 by default): the
whole image makes the simulation slower than a minute per case.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import Net  # noqa: E402

MANIFEST = Path("config/manifest/ink_dw_w8a8")
DEFAULT_IMAGE = "/tmp/stgold/in2/c0.png"
IMG_W, IMG_H = 320, 240
GROUP = 4                       # lanes per group beat

# case -> (PW layers, DW layer of the same pass, pass)
#
# The PW layers of a pass read the pass's DW output, which is not in DDR: the
# case input is that DW layer applied to the pass input (its "in" tensor in
# the dump), so the vector file holds what the DW stage really hands over.
# "im2col" is the stem's DW stage in im2col mode.
CASES = {
    "enc0": (["enc.0.pw"],          "enc.0.dw",  "enc0"),
    "res":  (["res.1.s1.pw"],       "res.1.s1.dw", "res1a"),
    "up0":  (["up3.0.pw", "up1.0"], "up3.0.dw",  "up0"),
    "up1a": (["up3.1.pw", "up1.1"], "up3.1.dw",  "up1a"),
    "head": (["head.pw"],           "head.dw",   "up1b"),
    "stem": (["stem"],              "im2col",    "stem"),
}


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def load_params(mdir: Path):
    """The manifest plus the generated ROM table of the same network.

    The manifest describes the layers; the ROM bases (pw_base, rq_base) come
    from st_net.json, which tools/st_gen_params.py writes next to the images.
    """
    m = json.loads((mdir / "manifest.json").read_text())
    tab = Path("rtl/st_accel_new/gen") / m["arch"] / "st_net.json"
    if not tab.exists():
        sys.exit(f"st_pw_vectors: {tab} is missing, run tools/st_gen_params.py")
    t = json.loads(tab.read_text())
    sha = hashlib.sha256((mdir / "manifest.json").read_bytes()).hexdigest()
    if t["manifest_sha256"] != sha:
        sys.exit(f"st_pw_vectors: {tab} was generated from another manifest")
    rom = {l["name"]: l for l in t["layers"]}
    L = {}
    for l in m["layers"]:
        r = rom[l["name"]]
        L[l["name"]] = dict(l, pw_base=r["pw_base"], rq_base=r["rq_base"],
                            n_pw_words=r["n_pw_words"], n_rq_words=r["n_rq_words"])
    return m, L


def synthetic_rgb(w: int = IMG_W, h: int = IMG_H) -> np.ndarray:
    """Deterministic image for when the golden dump is not available."""
    yy, xx = np.mgrid[0:h, 0:w]
    r = (xx * 255 // max(w - 1, 1))
    g = (yy * 255 // max(h - 1, 1))
    b = ((xx + yy) * 255 // max(w + h - 2, 1))
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def activation(net: Net, image: str):
    """p0 of the golden network run, or the synthetic one if it is missing."""
    if Path(image).exists():
        rgb = np.asarray(Image.open(image).convert("RGB"))
    else:
        print(f"st_pw_vectors: {image} missing, using a synthetic image")
        rgb = synthetic_rgb()
    return net.quantize_input(rgb)


def im2col(x: np.ndarray) -> np.ndarray:
    """CHW 3-channel padded image -> [27][h][w] im2col vectors, reflect pad 1.

    Element n = ic*9 + ky*3 + kx, matching the PW ROM lane layout of the stem
    (tools/st_gen_params.py:rom_inputs).
    """
    c, h, w = x.shape
    xp = np.pad(x, ((0, 0), (1, 1), (1, 1)), mode="reflect")
    out = np.zeros((27, h, w), np.int64)
    for ic in range(c):
        for ky in range(3):
            for kx in range(3):
                out[ic * 9 + ky * 3 + kx] = xp[ic, ky:ky + h, kx:kx + w]
    return out


def beats(t: np.ndarray, eol_rows: int):
    """CHW tensor -> [(data, last, eol, sof)] group beats, raster order."""
    c, h, w = t.shape
    g = ceil_div(c, GROUP)
    pad = np.zeros((g * GROUP, h, w), np.int64)
    pad[:c] = t
    flat = pad.transpose(1, 2, 0).reshape(h * w, g * GROUP)
    out = []
    for p in range(h * w):
        y, x = divmod(p, w)
        for b in range(g):
            data = 0
            for j in range(GROUP):
                v = int(flat[p, b * GROUP + j]) & 0x3FF
                data |= v << (10 * j)
            last = b == g - 1
            eol = last and (x == w - 1)
            sof = (p == 0) and (b == 0)
            out.append((data, last, eol, sof))
    return out


def fmt(bs) -> str:
    return "".join(f"{d:010x} {int(l)} {int(e)} {int(s)}\n" for d, l, e, s in bs)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True, choices=sorted(CASES))
    ap.add_argument("--out", required=True)
    ap.add_argument("--lines", type=int, default=40, help="activation rows to use")
    ap.add_argument("--image", default=DEFAULT_IMAGE)
    ap.add_argument("--manifest", default=str(MANIFEST))
    a = ap.parse_args()

    mdir = Path(a.manifest)
    net = Net(mdir, use_float=False)
    _, L = load_params(mdir)

    layers, dw, passname = CASES[a.case]

    with tempfile.TemporaryDirectory() as td:
        rgb = (np.asarray(Image.open(a.image).convert("RGB"))
               if Path(a.image).exists() else synthetic_rgb())
        net.run(rgb, td)
        dump = Path(td)

        def dumped(nm: str) -> np.ndarray:
            return np.load(dump / f"{nm}_in.npy").astype(np.int64)

        # Rows are cut after the pass's DW layer, never before: the DW window
        # of the rows kept must see the same pixels as on the full image.
        # The PW layers are 1x1, so a cut after them is exact too.
        x0 = net.quantize_input(rgb)
        if dw == "im2col":
            # The stem's DW stage is the im2col; its PW layer is the model's
            # own 3x3 conv over point 0 (a 1x1 conv over the im2col vectors).
            x = im2col(x0)[:, :a.lines]
            y = net.conv(L[layers[0]], x0)[:, :a.lines]
            rest = layers[1:]
        else:
            x = net.conv(L[dw], dumped(passname))[:, :a.lines]
            y = x
            rest = layers

        for nm in rest:
            y = net.conv(L[nm], y)

        # the chain is the model's own pass up to its PW layers: it must
        # reproduce the pass output, or the vectors would encode a typo
        want = np.load(dump / f"{passname}_out.npy").astype(np.int64)[:, :a.lines]
        if not np.array_equal(y, want):
            sys.exit(f"st_pw_vectors: {a.case}: chain differs from {passname}_out")

    cfg_layers = [L[layers[0]]] + ([L[layers[1]]] if len(layers) > 1 else [])

    def clamp(l):
        if l["out_unsigned"]:
            return 0, int(net.m["output_qmax"])
        if l["out_relu"]:
            return 0, int(net.m["act_qmax"])
        return -int(net.m["act_qmax"]), int(net.m["act_qmax"])

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    inb = beats(x, x.shape[1])
    outb = beats(y.astype(np.int64), y.shape[1])

    lines = [f"{x.shape[2] * x.shape[1]} {len(inb)} {len(outb)} {len(cfg_layers)}"]
    for k in range(2):
        if k < len(cfg_layers):
            l = cfg_layers[k]
            cin = 27 if layers[k] == "stem" else l["in_channels"]
            lo, hi = clamp(l)
            lines.append(f"{cin} {l['out_channels']} {l['pw_base']} "
                         f"{l['rq_base']} {lo} {hi}")
        else:
            lines.append("0 0 0 0 0 0")

    (out / "cfg.txt").write_text("\n".join(lines) + "\n")
    (out / "in.hex").write_text(fmt(inb))
    (out / "out.hex").write_text(fmt(outb))
    print(f"st_pw_vectors: {a.case}: {x.shape[2]*x.shape[1]} pixels "
          f"{x.shape[2]}x{x.shape[1]}x{x.shape[0]}, layers "
          f"{' -> '.join(n for n in layers)}, {len(inb)} in beats, "
          f"{len(outb)} out beats")


if __name__ == "__main__":
    main()
