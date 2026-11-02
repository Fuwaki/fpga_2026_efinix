#!/usr/bin/env python3
"""Bit-exact golden model of the ST block engine (tiny_dw, W8A8).

Runs the network the way the hardware does -- one pass per DDR round trip,
see PASSES -- with the integer semantics of fpga_st_train::intref:
reflect pad, int32 accumulate, requant, clamp; the residual source is
requantised onto the trunk grid before the add; upsample is a wire.

Requant is integer only (f32_mul_round): it reproduces intref's f32
multiply exactly -- 24-bit mantissa product, round to 24 significant bits,
round half away from zero.  --float computes it in numpy f32 instead; the
two must agree code for code.

Usage:
  st_golden.py --manifest DIR --image in.png --out out.png [--float]
               [--ref ref.png] [--dump DIR]
--dump writes every pass's input and output tensors (int8, CHW, .npy) for
the RTL testbenches.
"""
import argparse
import json
import os

import numpy as np
from PIL import Image

# One pass: (name, layers, upsample input, add source point or None).
# Layers in a pass run back to back on chip; the pass reads its input point
# from DDR and writes its output point to DDR.
PASSES = [
    ("stem",  ["stem"], False, None),
    ("enc0",  ["enc.0.dw", "enc.0.pw"], False, None),
    ("enc1",  ["enc.1.dw", "enc.1.pw"], False, None),
] + [
    p for k in range(4) for p in (
        (f"res{k}a", [f"res.{k}.s1.dw", f"res.{k}.s1.pw"], False, None),
        (f"res{k}b", [f"res.{k}.s2.dw", f"res.{k}.s2.pw"], False, "res"),
    )
] + [
    ("up0",   ["up3.0.dw", "up3.0.pw", "up1.0"], True, "skip"),
    ("up1",   ["up3.1.dw", "up3.1.pw", "up1.1", "head.dw", "head.pw"], True, None),
]

def round_away(v):
    """f32 round half away from zero, as Rust f32::round."""
    v = np.asarray(v, np.float32)
    return (np.sign(v) * np.floor(np.abs(v) + np.float32(0.5))).astype(np.int64)


def f32_parts(r):
    """f32 r > 0 -> (mant, exp) with r == mant * 2**(exp - 24), mant 24 bit."""
    m, e = np.frexp(np.float32(r))
    return int(m * (1 << 24)), int(e)


def f32_mul_round(x, mant, exp):
    """Integer emulation of round_away(f32(x) * f32(r)) for |x| < 2**24:
    p = x * mant exact, round p to 24 significant bits (RNE, what the f32
    multiply does), scale by 2**(exp - 24), round half away from zero.
    This is the requant datapath in hardware."""
    x = np.asarray(x, np.int64)
    sgn = np.where(x < 0, -1, 1)
    p = np.abs(x) * mant                                   # < 2**48
    lead = np.frexp(p.astype(np.float64))[1] - 1           # leading one, p < 2**53
    sh = np.maximum(lead - 23, 0)
    q = p >> sh
    rem = p - (q << sh)
    half = np.where(sh > 0, np.int64(1) << np.maximum(sh - 1, 0), 0)
    up = (sh > 0) & ((rem > half) | ((rem == half) & (q & 1 == 1)))
    v = (q + up) << sh                                     # f32 product, scaled by 2**(24 - exp)
    k = 24 - exp                                           # fraction bits
    if k <= 0:
        out = v << (-k)
    else:
        out = (v + (np.int64(1) << (k - 1))) >> k
    return sgn * out


class Net:
    def __init__(self, mdir, use_float):
        m = json.load(open(os.path.join(mdir, "manifest.json")))
        self.m = m
        self.w = np.fromfile(os.path.join(mdir, m["weight_file"]), dtype=np.int8).astype(np.int64)
        self.L = {l["name"]: l for l in m["layers"]}
        self.qmax = int(m["act_qmax"])
        self.oqmax = int(m["output_qmax"])
        self.use_float = use_float
        self.scales = m["point_scales"]

    def requant(self, acc, l, oc):
        r = l["requant"][oc]
        if self.use_float:
            return round_away(acc.astype(np.float32) * np.float32(r))
        return f32_mul_round(acc, *f32_parts(r))

    def conv(self, l, x):
        c, h, w = x.shape
        k = l["kernel"][0]
        st = l["stride"][0]
        p = l["reflect_pad"]
        xp = np.pad(x, ((0, 0), (p, p), (p, p)), mode="reflect") if p else x
        oh = (xp.shape[1] - k) // st + 1
        ow = (xp.shape[2] - k) // st + 1
        ic, oc = l["in_channels"], l["out_channels"]
        dw = l["groups"] > 1
        base = l["weight_offset"]
        if dw:
            wt = self.w[base: base + oc * k * k].reshape(oc, k, k)
        else:
            wt = self.w[base: base + oc * ic * k * k].reshape(oc, ic, k, k)
        acc = np.zeros((oc, oh, ow), np.int64)
        for ky in range(k):
            for kx in range(k):
                win = xp[:, ky: ky + st * (oh - 1) + 1: st, kx: kx + st * (ow - 1) + 1: st]
                if dw:
                    acc += win * wt[:, ky, kx][:, None, None]
                else:
                    acc += np.einsum("ihw,oi->ohw", win, wt[:, :, ky, kx])
        acc += np.array(l["bias_int32"], np.int64)[:, None, None]
        out = np.stack([self.requant(acc[o], l, o) for o in range(oc)])
        if l["out_unsigned"]:
            lo, hi = 0, self.oqmax
        elif l["out_relu"]:
            lo, hi = 0, self.qmax
        else:
            lo, hi = -self.qmax, self.qmax
        return np.clip(out, lo, hi)

    def add_requant(self, src, src_point, dst_point):
        """The residual operand onto the trunk grid (intref: f32 factor)."""
        f = np.float32(self.scales[src_point]) / np.float32(self.scales[dst_point])
        if self.use_float:
            v = round_away(src.astype(np.float32) * f)
        else:
            v = f32_mul_round(src, *f32_parts(f))
        return np.clip(v, -self.qmax, self.qmax)

    def quantize_input(self, rgb):
        """RGB8 HWC -> point 0 codes CHW, via the 256-entry LUT the hardware uses."""
        s0 = self.scales[0]
        # The LUT holds what intref computes in f32: round(p / 255 / s0).
        lut = np.clip(round_away((np.arange(256, dtype=np.float32) / np.float32(255)) / np.float32(s0)),
                      -self.qmax, self.qmax).astype(np.int64)
        return lut[rgb].transpose(2, 0, 1)

    def run(self, rgb, dump=None):
        x = self.quantize_input(rgb)
        pts = {0: x}
        res_src = None          # source point of the next residual add
        for name, layers, ups, add in PASSES:
            l0 = self.L[layers[0]]
            pt = l0["in_point"]
            y = pts[pt]
            if name == "res0a":
                res_src = pt
            if ups:
                y = y.repeat(2, axis=1).repeat(2, axis=2)
            if add == "skip":
                # graph: upsample point 21, then point 21 += requant(point 3).
                # The sum is not clamped (intref), so it can be 9 bit.
                y = self.add_requant(pts[3], 3, pt) + y
            if dump is not None:
                np.save(os.path.join(dump, f"{name}_in.npy"), y.astype(np.int16))
            for ln in layers:
                y = self.conv(self.L[ln], y)
            out_pt = self.L[layers[-1]]["out_point"]
            if add == "res":
                y = self.add_requant(pts[res_src], res_src, out_pt) + y
                res_src = out_pt
            pts[out_pt] = y
            if dump is not None:
                np.save(os.path.join(dump, f"{name}_out.npy"), y.astype(np.int16))
        return y


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ref")
    ap.add_argument("--float", action="store_true")
    ap.add_argument("--dump")
    a = ap.parse_args()
    net = Net(a.manifest, a.float)
    rgb = np.asarray(Image.open(a.image).convert("RGB"))
    if a.dump:
        os.makedirs(a.dump, exist_ok=True)
    y = net.run(rgb, a.dump)
    img = y.transpose(1, 2, 0).astype(np.uint8)
    Image.fromarray(img).save(a.out)
    if a.ref:
        ref = np.asarray(Image.open(a.ref).convert("RGB")).astype(int)
        d = np.abs(ref - img.astype(int))
        print(f"vs ref: {int((d != 0).sum())} of {d.size} codes differ, max |d| {int(d.max())}, "
              f"mean |d| {d.mean():.4f}")


if __name__ == "__main__":
    main()
