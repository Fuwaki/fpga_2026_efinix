#!/usr/bin/env python3
"""Group-stream vectors for rtl/st_accel_new/engine/st_pw.sv (guided net).

One case per invocation, written into --out:

  cfg.txt   "<npix> <nin> <nout> <nlay> <wide>", then one line per layer
            "<cin> <cout> <pw_base> <rq_base> <lo> <hi>", decimal
  in.hex    one input beat per line: "<128-bit hex> <last> <eol> <sof>".  A
            wide case (cfg_wide = 1) carries 16 int8 values per beat, byte k =
            element 16b + k; a narrow case carries four 10-bit lanes in the
            low 40 bits (lane j = bits [10j+9:10j], the int8 code in the low
            byte of each)
  out.hex   the expected output beats, "<40-bit hex> <last> <eol> <sof>"
            (four 10-bit lanes per beat)
  pw.hex    the case's PW weight ROM words (st_gen_params.pw_word layout)
  rq.hex    the case's requant ROM words (st_gen_params.rq_word layout)

Every case is synthetic but not arbitrary: the weights are random int8, the
bias is a random int32 below 2**15 in magnitude, and the requant factors are
drawn with replacement from the guided manifest's own per-layer requant
lists, so they have the real network's magnitude and mantissa/exponent
shape.  The expected output is st_golden.Net.conv over those layer dicts --
the normative integer requantisation (f32_mul_round) -- never a second
implementation.

Inputs are random int8 codes in the range the layer really sees: 0..127 for
a tensor that comes out of a relu (every case but n24_24), -127..127 where
the producer has no clamp (n24_24's first layer), so the collector, the
vector bank and the requant lanes are exercised with negative codes too.

Cases (--case), named after the guided net's layers (docs/st-guided-adr.md):
  c80_80      80 -> 80, relu            (res block)
  c80_24      80 -> 24, relu            (dec_h4)
  c16_80      16 -> 80, relu            (enc0)
  c24_40      24 -> 40, relu            (dec_h2)
  c40_8       40 -> 8, relu             (to_guide)
  c8_3u       8 -> 3, unsigned 0..255   (head)
  w27_8       wide, 27 -> 8, relu       (guide)
  w27_16      wide, 27 -> 16, relu      (stem)
  w27_10_40   wide, 27 -> 10 relu -> 10 -> 40 no relu (h2g, two layers)
  n24_24      24 -> 24 no relu -> 24 relu: signed codes through the layer-2
              bank (an extra case, the guided net's res0.s2.pw -> dec_h4 path)

Usage: st_pw_vectors.py --case NAME --out DIR [--pixels N] [--seed N]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import Net, f32_parts  # noqa: E402
from st_gen_params import hex_lines, pw_word, rq_word  # noqa: E402

MANIFEST = Path("/data/competition/2026fpga/st_work/p90_ln_w8a8")
IMG_W, IMG_H = 50, 40           # 2000 pixels per case
GROUP = 4                       # lanes per group beat
WIDE_BYTES = 16                 # int8 values per wide input beat

# name -> (input channels, [(output channels, clamp)], wide, input code range)
#
# clamp: "relu" 0..act_qmax, "u8" 0..output_qmax, "none" -act_qmax..act_qmax.
CASES = {
    "c80_80":    (80, [(80, "relu")],                 False, (0, 127)),
    "c80_24":    (80, [(24, "relu")],                 False, (0, 127)),
    "c16_80":    (16, [(80, "relu")],                 False, (0, 127)),
    "c24_40":    (24, [(40, "relu")],                 False, (0, 127)),
    "c40_8":     (40, [(8, "relu")],                  False, (0, 127)),
    "c8_3u":     (8, [(3, "u8")],                     False, (0, 127)),
    "w27_8":     (27, [(8, "relu")],                  True,  (0, 127)),
    "w27_16":    (27, [(16, "relu")],                 True,  (0, 127)),
    "w27_10_40": (27, [(10, "relu"), (40, "none")],   True,  (0, 127)),
    "n24_24":    (24, [(24, "none"), (24, "relu")],   False, (-127, 127)),
}


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def align_up(n: int, a: int) -> int:
    return ceil_div(n, a) * a


def requant_pool(mdir: Path) -> np.ndarray:
    """Every requant factor of the guided manifest, one flat list."""
    m = json.loads((mdir / "manifest.json").read_text())
    return np.array([r for l in m["layers"] for r in l["requant"]], np.float64)


class Case(Net):
    """A st_golden.Net over generated layers, so conv() and the integer
    requantisation are the golden model's, bit for bit."""

    def __init__(self, layers: list[dict], wts: np.ndarray):
        self.m = {"act_qmax": 127, "output_qmax": 255}
        self.w = wts
        self.L = {l["name"]: l for l in layers}
        self.qmax = 127
        self.oqmax = 255
        self.use_float = False
        self.scales = {}


def build(name: str, seed: int, mdir: Path):
    """The case's layers, its weight image, and the golden's output."""
    cin0, spec, wide, (lo_in, hi_in) = CASES[name]
    rng = np.random.default_rng(seed)
    pool = requant_pool(mdir)

    layers, words_pw, words_rq = [], [], []
    wts = []
    cin = cin0
    pw_base = rq_base = 0
    for k, (cout, clamp) in enumerate(spec):
        w2d = rng.integers(-127, 128, (cout, cin)).astype(np.int64)
        bias = rng.integers(-(2**15 - 1), 2**15, cout).astype(np.int64)
        rq = rng.choice(pool, size=cout, replace=True)
        clamp_lo, clamp_hi = {"relu": (0, 127), "u8": (0, 255),
                              "none": (-127, 127)}[clamp]
        n_pw = ceil_div(cout, 8) * ceil_div(cin, 16)
        layers.append(dict(
            name=f"l{k}", op="conv2d", in_channels=cin, out_channels=cout,
            groups=1, kernel=[1, 1], stride=[1, 1], reflect_pad=0,
            in_point=0, out_point=0,
            out_relu=(clamp == "relu"), out_unsigned=(clamp == "u8"),
            bias_int32=[int(b) for b in bias],
            requant=[float(r) for r in rq],
            weight_offset=sum(w.size for w in wts),
        ))
        wts.append(w2d.reshape(-1))
        for ot in range(ceil_div(cout, 8)):
            for it in range(ceil_div(cin, 16)):
                words_pw.append(pw_word(w2d, ot, it, cout))
        # The drain reads four requant words per cycle from four banks, so a
        # layer's first word must sit on a 4-word boundary (the same rule
        # st_dw checks); the pad words between layers are zero.
        while len(words_rq) < rq_base:
            words_rq.append(rq_word(0, 1 << 23, 24))
        for c in range(cout):
            mant, exp = f32_parts(rq[c])
            kk = 24 - exp
            assert 16 <= kk <= 47, f"{name}[{c}]: requant k {kk} outside 16..47"
            words_rq.append(rq_word(int(bias[c]), mant, kk))
        # the clamp is the layer's; the ROM bases are per case
        layers[-1]["pw_base"] = pw_base
        layers[-1]["rq_base"] = rq_base
        layers[-1]["lo"] = clamp_lo
        layers[-1]["hi"] = clamp_hi
        pw_base += n_pw
        rq_base = align_up(rq_base + cout, 4)
        cin = cout

    net = Case(layers, np.concatenate(wts))
    x = rng.integers(lo_in, hi_in + 1, (cin0, IMG_H, IMG_W)).astype(np.int64)
    y = x
    for l in layers:
        y = net.conv(l, y)

    assert pw_base <= 256, f"{name}: {pw_base} weight words exceed PW_DEPTH"
    assert rq_base <= 4 * 512, f"{name}: requant words exceed the rq ROM"
    for l in layers:
        assert l["rq_base"] % 4 == 0, f"{name}: rq base is not 4-aligned"
        assert l["rq_base"] + 8 * ceil_div(l["out_channels"], 8) <= 4 * 512
    return layers, hex_lines(words_pw), hex_lines(words_rq), x, y, wide


def flags(p: int, x: int, w: int, nbeat: int, b: int) -> tuple[bool, bool, bool]:
    """(last, eol, sof) of beat b of pixel p at column x."""
    last = b == nbeat - 1
    return last, last and x == w - 1, p == 0 and b == 0


def input_beats(x: np.ndarray, wide: bool) -> list[str]:
    """CHW int tensor -> input beat lines.  Wide: 16 int8 per beat; narrow:
    four 10-bit lanes, the int8 code zero-extended into each."""
    c, h, w = x.shape
    per = WIDE_BYTES if wide else GROUP
    nb = ceil_div(c, per)
    out = []
    for p in range(h * w):
        yy, xx = divmod(p, w)
        for b in range(nb):
            v = 0
            for j in range(per):
                ch = per * b + j
                code = int(x[ch, yy, xx]) & 0xFF if ch < c else 0
                v |= (code if wide else code) << (8 * j if wide else 10 * j)
            la, eo, so = flags(p, xx, w, nb, b)
            out.append(f"{v:032x} {int(la)} {int(eo)} {int(so)}")
    return out


def output_beats(y: np.ndarray) -> list[str]:
    """CHW int tensor -> expected group beats (four 10-bit lanes)."""
    c, h, w = y.shape
    nb = ceil_div(c, GROUP)
    out = []
    for p in range(h * w):
        yy, xx = divmod(p, w)
        for b in range(nb):
            v = 0
            for j in range(GROUP):
                ch = GROUP * b + j
                v |= (int(y[ch, yy, xx]) & 0x3FF if ch < c else 0) << (10 * j)
            la, eo, so = flags(p, xx, w, nb, b)
            out.append(f"{v:010x} {int(la)} {int(eo)} {int(so)}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True, choices=sorted(CASES))
    ap.add_argument("--out", required=True)
    ap.add_argument("--pixels", type=int, default=0,
                    help="pixels per case (default: the whole 50x40 grid)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--manifest", default=str(MANIFEST))
    a = ap.parse_args()

    layers, pw_hex, rq_hex, x, y, wide = build(a.case, a.seed, Path(a.manifest))
    if 0 < a.pixels < IMG_W * IMG_H:
        rows = ceil_div(a.pixels, IMG_W)
        x, y = x[:, :rows], y[:, :rows]

    inb = input_beats(x, wide)
    outb = output_beats(y)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    hdr = [f"{x.shape[1] * x.shape[2]} {len(inb)} {len(outb)} {len(layers)} {int(wide)}"]
    for k in range(2):
        if k < len(layers):
            l = layers[k]
            hdr.append(f"{l['in_channels']} {l['out_channels']} {l['pw_base']} "
                       f"{l['rq_base']} {l['lo']} {l['hi']}")
        else:
            hdr.append("0 0 0 0 0 0")
    (out / "cfg.txt").write_text("\n".join(hdr) + "\n")
    (out / "in.hex").write_text("\n".join(inb) + "\n")
    (out / "out.hex").write_text("\n".join(outb) + "\n")
    (out / "pw.hex").write_text(pw_hex)
    (out / "rq.hex").write_text(rq_hex)
    shape = " -> ".join(f"{l['in_channels']}->{l['out_channels']}" for l in layers)
    print(f"st_pw_vectors: {a.case}: {x.shape[2]}x{x.shape[1]}x{x.shape[0]} "
          f"{'wide' if wide else 'narrow'} {shape}, "
          f"{len(inb)} in beats, {len(outb)} out beats")
    return 0


if __name__ == "__main__":
    sys.exit(main())
