#!/usr/bin/env python3
"""Bit-exact golden model of the guided network (tiny_dw_guided) on the ST
block engine at 640x360 (docs/st-guided-adr.md).

The network follows the manifest graph.  conv, requant, add and upsample are
intref's integer semantics, computed as in st_golden.py (f32_mul_round).  The
ops intref computes in f32 have integer definitions here, the ones the
hardware implements:

* pre: 2x2 box of the camera frame, avg = (sum + 2) >> 2, then LUT0[avg];
* avg_pool2x: (sum of 4 codes + 2) >> 2 (codes are >= 0);
* layer_norm: integer statistics, rsqrt from a LUT, one affine (ln_int);
* film: integer GAP, an integer MLP, one affine per channel (film_int).

--ref uses intref's f32 definitions of those three ops instead, to measure
what the integer definitions cost.

Usage:
  st_guided.py --manifest DIR --image in.png --out out.png [--ref] [--dump DIR]
  st_guided.py --manifest DIR --frame cam.png --out proc.png [--dump DIR]
  st_guided.py --manifest DIR --compare IN_DIR INT_DIR FP32_DIR
--image takes the 640x360 network input.  --frame takes a 1280x720 camera
frame and runs the board path (RGB565, pre, network, 2x2 post); --out is
then the PROC slot.  --dump writes every point as its producer writes it to DDR (int16 CHW
p{N}.npy, before any upsample) and its DDR image p{N}.bin; out.npy (the RGB8
output, HWC); with --frame also frame.bin / proc.bin.  --compare runs every
IN_DIR image both ways and prints PSNR against intref (INT_DIR) and fp32.
"""
import argparse
import glob
import json
import os

import numpy as np
from PIL import Image

from st_golden import from565, to565, round_away, f32_parts, f32_mul_round, Net

CAM_W, CAM_H = 1280, 720
BOX = 2
NET_W, NET_H = CAM_W // BOX, CAM_H // BOX

# ------------------------------------------------------------------ LayerNorm
# D = N*Q - S^2 + E is N^2 * var in code units; 1/sqrt(D) = LUT[m] * 2^(-15-e)
# with D = m * 2^(2e - LN_L), m in [2^(LN_L-2), 2^LN_L).
LN_L = 10
LN_M0 = 1 << (LN_L - 2)
LN_LUT = np.round(2.0 ** (LN_L / 2 + 15) / np.sqrt(np.arange(LN_M0, 1 << LN_L) + 0.5)).astype(np.int64)
LN_T = 12           # t = u / sqrt(D) in Q12
LN_S = 22           # affine shift


def bitlen(v):
    return np.frexp(v.astype(np.float64))[1].astype(np.int64)     # exact for v < 2^53


def ln_consts(spec):
    n = spec["channels"]
    s_in, s_out = spec["in_scale"], spec["out_scale"]
    e_add = max(1, int(round(spec["eps"] * n * n / (s_in * s_in))))
    g = np.round(np.array(spec["gamma"], np.float64) / s_out * 2 ** (LN_S - LN_T)).astype(np.int64)
    b = np.round(np.array(spec["beta"], np.float64) / s_out * 2 ** LN_S).astype(np.int64)
    return e_add, g, b


def ln_int(x, spec, qmax):
    """x: CHW int codes.  Per pixel: S, Q over channels; D; e, m; R = LUT[m];
    u = N*x - S; t = (u*R + 2^(e+2)) >> (e+3); y = (t*G + B + 2^21) >> 22."""
    n = spec["channels"]
    e_add, g, b = ln_consts(spec)
    x = x.astype(np.int64)
    s = x.sum(0)
    q = (x * x).sum(0)
    d = n * q - s * s + e_add
    e = (bitlen(d) + 1) // 2
    sh = LN_L - 2 * e
    m = np.where(sh >= 0, d << np.maximum(sh, 0), d >> np.maximum(-sh, 0))
    assert ((m >= LN_M0) & (m < 1 << LN_L)).all()
    r = LN_LUT[m - LN_M0]
    u = n * x - s
    t = (u * r + (np.int64(1) << (e + 2))) >> (e + 3)
    y = (t * g[:, None, None] + b[:, None, None] + (1 << (LN_S - 1))) >> LN_S
    return np.clip(y, -qmax, qmax)


def ln_ref(x, spec, qmax):
    """intref layer_norm in f32."""
    s_in, s_out = np.float32(spec["in_scale"]), np.float32(spec["out_scale"])
    v = x.astype(np.float32) * s_in
    mean = v.sum(0, dtype=np.float32) / np.float32(v.shape[0])
    var = ((v - mean) ** 2).sum(0, dtype=np.float32) / np.float32(v.shape[0])
    inv = np.float32(1) / np.sqrt(var + np.float32(spec["eps"]))
    gm = np.array(spec["gamma"], np.float32)[:, None, None]
    bt = np.array(spec["beta"], np.float32)[:, None, None]
    return np.clip(round_away((gm * (v - mean) * inv + bt) / s_out), -qmax, qmax)


# ----------------------------------------------------------------------- FiLM
# All constants are 18-bit signed multipliers with a per-layer shift.
FILM_F = 8          # zq = z * 2^F / in_scale
FILM_P = 15         # affine: y = (x*mul + off + 2^(P-1)) >> P
FILM_GS = 6         # GAP sum pre-shift: Sg = (S + 32) >> 6
MBITS = 17          # |multiplier| < 2^17
MUL_MAX = (1 << 17) - 1
OFF_MAX = (1 << 23) - 1


def _fit(vals):
    """Largest shift s with round(|vals| * 2^s) < 2^MBITS."""
    top = float(np.max(np.abs(vals)))
    s = 0
    while round(top * 2 ** (s + 1)) < 2 ** MBITS:
        s += 1
    return s, np.round(np.asarray(vals, np.float64) * 2 ** s).astype(np.int64)


def film_consts(spec, plane):
    """Integer MLP constants of a film layer for a plane of `plane` pixels."""
    s_in, s_out = spec["in_scale"], spec["out_scale"]
    hd = {}
    for k in ("reduce", "gamma", "beta"):
        h = spec[k]
        hd[k] = dict(w=np.array(h["weight_codes"], np.int64).reshape(h["out_channels"], h["in_channels"]),
                     b=np.array(h["bias_int32"], np.int64),
                     ws=np.array(h["weight_scale"], np.float64))
    c = dict(heads=hd, kb=int(round(plane / 2 ** FILM_GS)))
    c["sz"], c["mz"] = _fit(hd["reduce"]["ws"] * 2 ** (FILM_F + FILM_GS) / plane)
    c["sg"], c["mg"] = _fit(hd["gamma"]["ws"] * s_in * s_in / s_out * 2 ** (FILM_P - FILM_F))
    c["sb"], c["mb"] = _fit(hd["beta"]["ws"] * s_in / s_out * 2 ** (FILM_P - FILM_F))
    c["c0"] = int(round(2 ** FILM_P * s_in / s_out))
    return c


def rshift_round(v, s):
    return (v + (np.int64(1) << (s - 1))) >> s if s > 0 else v << (-s)


def film_coeffs(spec, gap_sum, plane):
    """Per-channel (mul, off) from the per-channel code sums of the input.
    This is the sequencer between the producer pass and the FiLM pass."""
    c = film_consts(spec, plane)
    h = c["heads"]
    sg = (gap_sum.astype(np.int64) + (1 << (FILM_GS - 1))) >> FILM_GS
    a = h["reduce"]["b"] * c["kb"] + h["reduce"]["w"] @ sg
    zq = np.maximum(0, rshift_round(a * c["mz"], c["sz"]))
    big_g = h["gamma"]["b"] * 2 ** FILM_F + h["gamma"]["w"] @ zq
    big_b = h["beta"]["b"] * 2 ** FILM_F + h["beta"]["w"] @ zq
    # Saturated to the affine unit's operands: mul 18 bit, off 24 bit signed.
    mul = np.clip(c["c0"] + rshift_round(big_g * c["mg"], c["sg"]), -MUL_MAX, MUL_MAX)
    off = np.clip(rshift_round(big_b * c["mb"], c["sb"]), -OFF_MAX, OFF_MAX)
    return mul, off, dict(sg=sg, a=a, zq=zq, g=big_g, b=big_b)


def film_int(x, spec, qmax):
    plane = x.shape[1] * x.shape[2]
    mul, off, _ = film_coeffs(spec, x.astype(np.int64).sum((1, 2)), plane)
    y = (x.astype(np.int64) * mul[:, None, None] + off[:, None, None] + (1 << (FILM_P - 1))) >> FILM_P
    return np.clip(y, -qmax, qmax)


def film_ref(x, spec, qmax):
    """intref film_forward in f32."""
    s_in, s_out = np.float32(spec["in_scale"]), np.float32(spec["out_scale"])
    v = x.astype(np.float32) * s_in
    gap = v.sum((1, 2), dtype=np.float32) / np.float32(x.shape[1] * x.shape[2])

    def mv(h, inp):
        ws = np.array(h["weight_scale"], np.float32)
        w = np.array(h["weight_codes"], np.float32).reshape(h["out_channels"], h["in_channels"]) * ws[:, None]
        return np.array(h["bias_int32"], np.float32) * ws * s_in + w @ inp

    z = np.maximum(mv(spec["reduce"], gap), 0)
    g = mv(spec["gamma"], z) + np.float32(1)
    b = mv(spec["beta"], z)
    return np.clip(round_away((v * g[:, None, None] + b[:, None, None]) / s_out), -qmax, qmax)


# ------------------------------------------------------------- pre / pool / post
def pool_int(x):
    c, h, w = x.shape
    s = x.astype(np.int64).reshape(c, h // 2, 2, w // 2, 2).sum((2, 4))
    assert (s >= 0).all()
    return (s + 2) >> 2


def pool_ref(x, s_in, s_out, qmax):
    c, h, w = x.shape
    v = x.astype(np.float32) * np.float32(s_in)
    s = v.reshape(c, h // 2, 2, w // 2, 2).sum((2, 4), dtype=np.float32)
    return np.clip(round_away(s / np.float32(4) / np.float32(s_out)), -qmax, qmax)


def pre(frame565):
    """ISP slot (720x1280 RGB565) -> 360x640 RGB8: 2x2 box, (sum + 2) >> 2."""
    s = from565(frame565).reshape(NET_H, BOX, NET_W, BOX, 3).sum(axis=(1, 3))
    return ((s + 2) >> 2).astype(np.uint8)


def post(rgb):
    """360x640 RGB8 -> the 720x1280 PROC slot, every pixel 2x2."""
    return to565(rgb.repeat(BOX, axis=0).repeat(BOX, axis=1))


# ------------------------------------------------------------------- network
class Guided(Net):
    def __init__(self, mdir, ref=False):
        super().__init__(mdir, False)
        self.ref = ref
        self.norm = {n["name"]: n for n in self.m.get("norm_layers", [])}
        self.film = {f["name"]: f for f in self.m.get("film_layers", [])}
        # DDR element width: points written by an add are int16.
        self.wide = {op["point"] for op in self.m["graph"] if op["op"] == "add"}

    def run(self, rgb, dump=None):
        """RGB8 HWC -> RGB8 HWC.  self.ddr[p] is point p as its producer pass
        writes it to DDR: the value before the point is upsampled (an
        upsample, and anything after it, happens in the consuming pass)."""
        pts = {0: self.quantize_input(rgb)}
        self.ddr = {}
        img = None
        for op in self.m["graph"]:
            k = op["op"]
            if k == "conv":
                l = self.L[op["layer"]]
                y = self.conv(l, pts[l["in_point"]])
                if l["out_unsigned"]:
                    img = y
                else:
                    pts[l["out_point"]] = y
            elif k == "relu":
                pass
            elif k == "add":
                p, s = op["point"], op["source_point"]
                pts[p] = self.add_requant(pts[s], s, p) + pts[p]
            elif k == "upsample_nearest2x":
                p = op["point"]
                self.ddr.setdefault(p, pts[p])
                pts[p] = pts[p].repeat(2, axis=1).repeat(2, axis=2)
            elif k == "avg_pool2x":
                s, p = op["source_point"], op["point"]
                pts[p] = (pool_ref(pts[s], self.scales[s], op["scale"], self.qmax) if self.ref
                          else pool_int(pts[s]))
            elif k == "layer_norm":
                spec = self.norm[op["layer"]]
                f = ln_ref if self.ref else ln_int
                pts[op["point"]] = f(pts[op["source_point"]], spec, self.qmax)
            elif k == "film":
                spec = self.film[op["layer"]]
                f = film_ref if self.ref else film_int
                pts[spec["out_point"]] = f(pts[spec["in_point"]], spec, self.qmax)
            elif k == "quantize_u8_output":
                break
            else:
                raise ValueError(f"unknown op {k}")
        for p, t in pts.items():
            self.ddr.setdefault(p, t)
        out = img.transpose(1, 2, 0).astype(np.uint8)
        if dump is not None:
            for p, t in self.ddr.items():
                np.save(os.path.join(dump, f"p{p}.npy"), t.astype(np.int16))
                with open(os.path.join(dump, f"p{p}.bin"), "wb") as fh:
                    fh.write(self.ddr_image(t, p))
            np.save(os.path.join(dump, "out.npy"), out)
        return out

    def ddr_image(self, t, pt):
        """CHW int tensor -> DDR bytes: HWC, pixel = roundup16(C * elem) bytes."""
        c, h, w = t.shape
        e = 2 if pt in self.wide else 1
        pb = -(-(c * e) // 16) * 16
        hwc = np.ascontiguousarray(t.transpose(1, 2, 0).astype("<i2" if e == 2 else "i1"))
        buf = np.zeros((h, w, pb), np.uint8)
        buf[:, :, :c * e] = hwc.view(np.uint8).reshape(h, w, c * e)
        return buf.tobytes()


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(255 ** 2 / mse)


def compare(mdir, in_dir, int_dir, fp_dir):
    hw, rf = Guided(mdir, False), Guided(mdir, True)
    for f in sorted(glob.glob(os.path.join(in_dir, "*.png"))):
        n = os.path.basename(f)
        rgb = np.asarray(Image.open(f).convert("RGB"))
        yh, yr = hw.run(rgb), rf.run(rgb)
        ri = np.asarray(Image.open(os.path.join(int_dir, n)).convert("RGB"))
        rf32 = np.asarray(Image.open(os.path.join(fp_dir, n)).convert("RGB"))
        print(f"{n:16s} ref==intref {int((yr != ri).sum()):7d} diff | "
              f"hw vs intref {psnr(yh, ri):5.2f} dB  hw vs fp32 {psnr(yh, rf32):5.2f} dB  "
              f"intref vs fp32 {psnr(ri, rf32):5.2f} dB")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--image")
    src.add_argument("--frame")
    src.add_argument("--compare", nargs=3)
    ap.add_argument("--out")
    ap.add_argument("--ref", action="store_true")
    ap.add_argument("--dump")
    a = ap.parse_args()
    if a.compare:
        compare(a.manifest, *a.compare)
        return
    net = Guided(a.manifest, a.ref)
    if a.dump:
        os.makedirs(a.dump, exist_ok=True)
    if a.frame:
        cam = np.asarray(Image.open(a.frame).convert("RGB"))
        assert cam.shape[:2] == (CAM_H, CAM_W), f"--frame must be {CAM_W}x{CAM_H}"
        f565 = to565(cam)
        rgb = pre(f565)
    else:
        rgb = np.asarray(Image.open(a.image).convert("RGB"))
    img = net.run(rgb, a.dump)
    if a.frame:
        proc = post(img)
        Image.fromarray(from565(proc).astype(np.uint8)).save(a.out)
        if a.dump:
            f565.astype("<u2").tofile(os.path.join(a.dump, "frame.bin"))
            proc.astype("<u2").tofile(os.path.join(a.dump, "proc.bin"))
    else:
        Image.fromarray(img).save(a.out)


if __name__ == "__main__":
    main()
