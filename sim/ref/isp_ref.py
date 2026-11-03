#!/usr/bin/env python3
"""Bit-exact reference model of the camera ISP (rtl/vid/isp).

This file is the specification of the ISP arithmetic; the RTL is checked
against it in simulation (sim/tb/tb_isp.sv) and, through frame signatures, on
the board.  All arithmetic is on integers exactly as the hardware does it.

Frame in:  raw[y][x], 10 bit, H x W, as the sensor delivers it.
Frame out: RGB565 words, H x W, as vdma_wr writes them to DDR.

Stages:
  blc_wb     d = max(v - blc_level, 0);  w = min((d * gain[c]) >> 8, 1023)
             gain[c] = (blc_gain * wb[c]) >> 8, c = colour of the site
  demosaic   bilinear.  Output line 0 is black; output line k >= 1 is centred
             on input row k - 1 (so the picture moves down one row and the
             last row is dropped; the hardware never has to emit a line on its
             own).  Missing neighbours are mirrored: row -1 -> row 1,
             column -1 -> 1, column W -> W - 2.
  gamma      ROM (rtl/gamma_conrrection/SRGB_ENC.mem, 1024 x 10 bit), top 8
             bits kept
  sat        Y = (77 R + 150 G + 29 B) >> 8, per channel
             u = C + 256 - Y, p = (sat * u) >> 8, C' = clamp(Y + p - sat, 0, 255)
  dither565  2x2 ordered, t = [[0, 2], [3, 1]][y & 1][x & 1];
             r5 = (31 R + 32 + 64t) >> 8, g6 = (63 G + 32 + 64t) >> 8, b5 like r5
  bypass_all gray = raw >> 2 into all three channels, plain truncation to 565

Signature (vdma_wr st_sig): over the frame's 32-bit words in raster order,
word = p[x] | p[x + 1] << 16 for even x, sig = rotl(sig, 1) ^ word from 0.

Usage:
  isp_ref.py gen-raw OUT.hex [--seed N]       random raw frame for the TB
  isp_ref.py check RAW.hex|pattern DUMP.hex   compare a TB slot dump
  isp_ref.py pattern-sig                      signatures of the capture test
                                              pattern (board check)
"""
import argparse
import os
import sys

import numpy as np

W, H = 1280, 720
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GAMMA_FILE = os.path.join(ROOT, "rtl", "gamma_conrrection", "SRGB_ENC.mem")

# Mirror of vid_pkg::ISP_CFG_DEFAULT.
CFG_DEFAULT = dict(bypass_all=0, bypass_gamma=0, bypass_sat=0, dither_en=1,
                   cfa_r=0b10, blc_level=64, blc_gain=273,
                   wb_r=256, wb_g=133, wb_b=256, sat=384)


def load_gamma():
    with open(GAMMA_FILE) as f:
        vals = [int(t, 16) for t in f.read().split()]
    assert len(vals) == 1024, len(vals)
    return np.array(vals, dtype=np.int64)


def colour_map(cfg, h=H, w=W):
    """0 = R, 1 = G, 2 = B for every site."""
    ry, rx = (cfg["cfa_r"] >> 1) & 1, cfg["cfa_r"] & 1
    yy, xx = np.mgrid[0:h, 0:w]
    py, px = yy & 1, xx & 1
    c = np.ones((h, w), dtype=np.int64)
    c[(py == ry) & (px == rx)] = 0
    c[(py != ry) & (px != rx)] = 2
    return c


def blc_wb(raw, cfg):
    gains = np.array([(cfg["blc_gain"] * cfg[k]) >> 8 for k in ("wb_r", "wb_g", "wb_b")],
                     dtype=np.int64)
    d = np.maximum(raw.astype(np.int64) - cfg["blc_level"], 0)
    g = gains[colour_map(cfg, *raw.shape)]
    return np.minimum((d * g) >> 8, 1023)


def demosaic(p, cfg):
    h, w = p.shape
    cmap = colour_map(cfg, h, w)
    out = np.zeros((h, w, 3), dtype=np.int64)
    # Row c of the input is output line c + 1.
    up = np.vstack([p[1:2], p[:-1]])        # row c - 1, mirrored at the top
    dn = np.vstack([p[1:], p[-2:-1]])       # row c + 1 (row h never used)

    def lr(a):
        left = np.hstack([a[:, 1:2], a[:, :-1]])
        right = np.hstack([a[:, 1:], a[:, -2:-1]])
        return left, right

    cl, cr = lr(p)
    ul, ur = lr(up)
    dl, dr = lr(dn)
    cross = (cl + cr + up + dn) >> 2
    diag = (ul + ur + dl + dr) >> 2
    hor = (cl + cr) >> 1
    ver = (up + dn) >> 1

    r = np.zeros_like(p)
    g = np.zeros_like(p)
    b = np.zeros_like(p)
    is_r, is_g, is_b = cmap == 0, cmap == 1, cmap == 2
    # A green site's row holds either red or blue as its other colour.
    row_has_r = np.zeros_like(p, dtype=bool)
    ry = (cfg["cfa_r"] >> 1) & 1
    row_has_r[ry::2, :] = True

    r[is_r], g[is_r], b[is_r] = p[is_r], cross[is_r], diag[is_r]
    b[is_b], g[is_b], r[is_b] = p[is_b], cross[is_b], diag[is_b]
    gr = is_g & row_has_r
    gb = is_g & ~row_has_r
    g[is_g] = p[is_g]
    r[gr], b[gr] = hor[gr], ver[gr]
    b[gb], r[gb] = hor[gb], ver[gb]

    out[1:, :, 0] = r[:-1]
    out[1:, :, 1] = g[:-1]
    out[1:, :, 2] = b[:-1]
    return out


def gamma8(rgb10, cfg, table):
    if cfg["bypass_gamma"]:
        return rgb10 >> 2
    return table[rgb10] >> 2


def saturate(rgb8, cfg):
    if cfg["bypass_sat"]:
        return rgb8
    r, g, b = rgb8[..., 0], rgb8[..., 1], rgb8[..., 2]
    y = (77 * r + 150 * g + 29 * b) >> 8
    out = np.empty_like(rgb8)
    s = cfg["sat"]
    for i in range(3):
        u = rgb8[..., i] + 256 - y
        p = (s * u) >> 8
        out[..., i] = np.clip(y + p - s, 0, 255)
    return out


def dither565(rgb8, cfg):
    h, w, _ = rgb8.shape
    if cfg["dither_en"]:
        tm = np.array([[0, 2], [3, 1]], dtype=np.int64)
        yy, xx = np.mgrid[0:h, 0:w]
        t = tm[yy & 1, xx & 1]
        r5 = (31 * rgb8[..., 0] + 32 + 64 * t) >> 8
        g6 = (63 * rgb8[..., 1] + 32 + 64 * t) >> 8
        b5 = (31 * rgb8[..., 2] + 32 + 64 * t) >> 8
    else:
        r5, g6, b5 = rgb8[..., 0] >> 3, rgb8[..., 1] >> 2, rgb8[..., 2] >> 3
    return (r5 << 11) | (g6 << 5) | b5


def isp(raw, cfg=CFG_DEFAULT, table=None):
    if cfg["bypass_all"]:
        v = raw.astype(np.int64) >> 2
        return ((v >> 3) << 11) | ((v >> 2) << 5) | (v >> 3)
    if table is None:
        table = load_gamma()
    w = blc_wb(raw, cfg)
    rgb10 = demosaic(w, cfg)
    rgb8 = saturate(gamma8(rgb10, cfg, table), cfg)
    return dither565(rgb8, cfg)


def gray_stats(rgb10):
    """isp_gray_stats: R, G, B (>> 2) sums of the near-gray pixels in the
    even columns of the demosaic output."""
    p = rgb10[:, 0::2].astype(np.int64)
    r, g, b = p[..., 0], p[..., 1], p[..., 2]
    tol = (g >> 3) + (g >> 4)
    q = ((g >= 64) & (r < 1000) & (g < 1000) & (b < 1000)
         & (np.abs(r - g) < tol) & (np.abs(b - g) < tol))
    return [int((r[q] >> 2).sum()), int((g[q] >> 2).sum()), int((b[q] >> 2).sum())]


def signature(frame565):
    words = (frame565[:, 0::2] | (frame565[:, 1::2] << 16)).astype(np.uint64).ravel()
    sig = 0
    for wd in words.tolist():
        sig = (((sig << 1) | (sig >> 31)) & 0xFFFFFFFF) ^ wd
    return sig


# -------------------------------------------------- capture test pattern
def capture_pattern(h=H, w=W):
    """csi_capture PATTERN = 1: raw = (x[9:0] ^ {y[6:0], 3'b000}) + y[9:0], 10 bit."""
    yy, xx = np.mgrid[0:h, 0:w]
    return ((((xx & 0x3FF) ^ ((yy & 0x7F) << 3)) + yy) & 0x3FF).astype(np.int64)


# ------------------------------------------------------------- file I/O
def write_raw_hex(path, raw):
    # One CSI beat per line: 4 pixels, p0 in the low 10 bits.
    with open(path, "w") as f:
        for row in raw:
            for x in range(0, len(row), 4):
                v = 0
                for i in range(4):
                    v |= int(row[x + i]) << (10 * i)
                f.write(f"{v:010x}\n")


def read_raw_hex(path):
    vals = [int(t, 16) for t in open(path).read().split()]
    raw = np.zeros((H, W), dtype=np.int64)
    flat = raw.reshape(-1)
    for i, v in enumerate(vals):
        for k in range(4):
            flat[4 * i + k] = (v >> (10 * k)) & 0x3FF
    return raw


def read_dump(path):
    """TB dump: '# sig X' per committed frame, '# slot N' headers, then one
    128-bit beat per line."""
    slots, sigs = {}, []
    cur = None
    read_dump.gray = None
    for line in open(path):
        line = line.strip()
        if line.startswith("# gray"):
            read_dump.gray = [int(t) for t in line.split()[2:]]
        elif line.startswith("# sig"):
            sigs.append(int(line.split()[-1], 16))
        elif line.startswith("# slot"):
            cur = int(line.split()[-1])
            slots[cur] = []
        elif line:
            slots[cur].append(int(line, 16))
    frames = {}
    for k, beats in slots.items():
        px = []
        for b in beats:
            for i in range(8):
                px.append((b >> (16 * i)) & 0xFFFF)
        frames[k] = np.array(px, dtype=np.int64).reshape(H, W)
    return frames, sigs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen-raw")
    g.add_argument("out")
    g.add_argument("--seed", type=int, default=1)
    c = sub.add_parser("check")
    c.add_argument("raw")
    c.add_argument("dump")
    c.add_argument("--bypass", action="store_true")
    sub.add_parser("pattern-sig")
    a = ap.parse_args()

    if a.cmd == "gen-raw":
        rng = np.random.default_rng(a.seed)
        # Smooth gradients with noise and a few saturated / black patches, so
        # every clamp in the pipeline is exercised.
        yy, xx = np.mgrid[0:H, 0:W]
        raw = (xx * 1023 // W + yy * 300 // H + rng.integers(0, 64, (H, W))) % 1024
        raw[100:140, 200:260] = 1023
        raw[300:330, 900:1000] = 0
        raw[500:520, :] = rng.integers(0, 1024, (20, W))
        write_raw_hex(a.out, raw)
        print(f"sig {signature(isp(raw)):#010x}")
        return 0

    if a.cmd == "check":
        cfg = dict(CFG_DEFAULT, bypass_all=1 if a.bypass else 0)
        raw = capture_pattern() if a.raw == "pattern" else read_raw_hex(a.raw)
        exp = isp(raw, cfg)
        esig = signature(exp)
        frames, sigs = read_dump(a.dump)
        best = None
        for k, fr in frames.items():
            bad = int(np.count_nonzero(fr != exp))
            if best is None or bad < best[1]:
                best = (k, bad, fr)
        k, bad, fr = best
        print(f"expected sig {esig:#010x}; RTL sigs {[hex(v) for v in sigs]}; "
              f"closest slot {k}: {bad} pixels differ")
        if bad:
            ys, xs = np.nonzero(fr != exp)
            for y, x in list(zip(ys, xs))[:10]:
                print(f"  ({x},{y}): got {fr[y, x]:04x} expected {exp[y, x]:04x}")
            return 1
        if not sigs or any(v != esig for v in sigs):
            print("FAIL: RTL signatures differ from the model")
            return 1
        if not a.bypass and read_dump.gray is not None:
            eg = gray_stats(demosaic(blc_wb(raw, cfg), cfg))
            print(f"gray stats: RTL {read_dump.gray} expected {eg}")
            if read_dump.gray != eg:
                print("FAIL: near-gray statistics differ from the model")
                return 1
        print("PASS isp_ref")
        return 0

    if a.cmd == "pattern-sig":
        raw = capture_pattern()
        print(f"bypass_all  {signature(isp(raw, dict(CFG_DEFAULT, bypass_all=1))):#010x}")
        print(f"default ISP {signature(isp(raw)):#010x}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
