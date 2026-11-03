#!/usr/bin/env python3
"""FiLM parameter ROM for rtl/st_accel_new/engine/st_film.sv.

Writes into --out:

  st_film.hex   512 words of 40 bits per style (words 512k.. are style k),
                one 10-digit hex word per line, MSB first: the biases and
                multipliers of st_guided.film_consts and the three weight
                matrices of the layer, arranged as the RTL header documents
                (word offsets within a style's 512):

                  word   0 + o         [31:0] br_o, signed        (o < 10)
                  word  10 + o         [16:0] Mz_o, < 2**17       (o < 10)
                  word  20 + c         [31:0] bg_c, signed        (c < 40)
                  word  60 + c         [31:0] bb_c, signed        (c < 40)
                  word 100 + c         [16:0] Mg_c, [33:17] Mb_c  (c < 40)
                  word 140 + 8o + w    byte 5w + i = Wr[o][5w + i]
                  word 220 + 2c + w    byte 5w + i = Wg[c][5w + i]
                  word 300 + 2c + w    byte 5w + i = Wb[c][5w + i]

                Weights are int8 two's complement, one row per whole number of
                words, so a row is a run of words with consecutive bytes.
                SZ, SG, SB, C0 and KB are module parameters of st_film, not ROM
                words, one set for every style: the shifts are
                st_guided.film_shifts (the smallest any style needs), and C0
                and KB depend on the shared scales only.  --params prints the
                localparams st_net_pkg wants.

  st_film.json  style 0's constants in decimal, for the Python testbenches
                and for a quick check against st_guided.film_consts.

The values are st_guided.film_consts(spec, plane) -- the golden model, not a
second implementation.  Every value is asserted to fit its field, the decoded
image is read back and compared with the constants, and the film layer's
shapes are checked against the RTL's channel and hidden-unit counts.

Usage: st_gen_film.py --manifest DIR --plane 57600 --out DIR [--layer NAME]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_guided import film_consts, film_shifts, style_packets  # noqa: E402

NC, NO = 40, 10                 # channels and hidden units of the FiLM MLP
WORD_BITS = 40
DEPTH = 512

A_BR, A_MZ = 0, 10
A_BG, A_BB, A_MM = 20, 60, 100
A_WR, A_WG, A_WB = 140, 220, 300
USED = A_WB + 2 * NC             # 380 words


def _check(name, v, lo, hi):
    assert lo <= v <= hi, f"{name} = {v} outside {lo}..{hi}"
    return int(v)


def build(spec, plane, shifts=None):
    """The ROM words and the constants, from the golden film_consts."""
    c = film_consts(spec, plane, shifts)
    h = c["heads"]
    wr, bg = h["reduce"]["w"], h["reduce"]["b"]
    wg, gg = h["gamma"]["w"], h["gamma"]["b"]
    wb, bb = h["beta"]["w"], h["beta"]["b"]
    assert wr.shape == (NO, NC) and bg.shape == (NO,), f"reduce {wr.shape} {bg.shape}"
    assert wg.shape == (NC, NO) and gg.shape == (NC,), f"gamma {wg.shape} {gg.shape}"
    assert wb.shape == (NC, NO) and bb.shape == (NC,), f"beta {wb.shape} {bb.shape}"

    words = [0] * DEPTH
    for o in range(NO):
        words[A_BR + o] = _check(f"br{o}", bg[o], -(1 << 31), (1 << 31) - 1) & 0xFFFF_FFFF
        words[A_MZ + o] = _check(f"mz{o}", c["mz"][o], 0, (1 << 17) - 1)
    for ch in range(NC):
        words[A_BG + ch] = _check(f"bg{ch}", gg[ch], -(1 << 31), (1 << 31) - 1) & 0xFFFF_FFFF
        words[A_BB + ch] = _check(f"bb{ch}", bb[ch], -(1 << 31), (1 << 31) - 1) & 0xFFFF_FFFF
        words[A_MM + ch] = (_check(f"mg{ch}", c["mg"][ch], 0, (1 << 17) - 1)
                            | _check(f"mb{ch}", c["mb"][ch], 0, (1 << 17) - 1) << 17)

    def put(base, wrow, nwords):
        """int8 row -> nwords words, byte 5w + i of the row at word w."""
        for w in range(nwords):
            v = 0
            for i in range(5):
                k = 5 * w + i
                if k < len(wrow):
                    b = _check(f"weight {base}+{w} byte {k}", wrow[k], -128, 127)
                    v |= (b & 0xFF) << (8 * i)
            words[base + w] = v

    for o in range(NO):
        put(A_WR + 8 * o, wr[o], 8)
    for ch in range(NC):
        put(A_WG + 2 * ch, wg[ch], 2)
        put(A_WB + 2 * ch, wb[ch], 2)

    consts = dict(
        sz=_check("sz", c["sz"], 1, 55), sg=_check("sg", c["sg"], 1, 55),
        sb=_check("sb", c["sb"], 1, 55),
        c0=_check("c0", c["c0"], -(1 << 18), (1 << 18) - 1),
        kb=_check("kb", c["kb"], -(1 << 17), (1 << 17) - 1),
        plane=int(plane), nc=NC, no=NO,
        mz=[int(v) for v in c["mz"]], mg=[int(v) for v in c["mg"]],
        mb=[int(v) for v in c["mb"]],
        br=[int(v) for v in bg], bg=[int(v) for v in gg], bb=[int(v) for v in bb],
        wr=[[int(v) for v in r] for r in wr],
        wg=[[int(v) for v in r] for r in wg],
        wb=[[int(v) for v in r] for r in wb],
        layer=spec["name"], in_point=spec["in_point"], out_point=spec["out_point"],
        in_scale=spec["in_scale"], out_scale=spec["out_scale"],
    )
    return words, consts


def decode(words):
    """Read the image back the way the RTL does, for the self-check."""
    def s(v, bits):
        return v - (1 << bits) if v >> (bits - 1) else v

    out = dict(
        mz=[words[A_MZ + o] for o in range(NO)],
               mg=[words[A_MM + ch] & 0x1FFFF for ch in range(NC)],
               mb=[(words[A_MM + ch] >> 17) & 0x1FFFF for ch in range(NC)],
               br=[s(words[A_BR + o], 32) for o in range(NO)],
               bg=[s(words[A_BG + ch], 32) for ch in range(NC)],
               bb=[s(words[A_BB + ch], 32) for ch in range(NC)])
    out["wr"] = [[s((words[A_WR + 8 * o + (k // 5)] >> (8 * (k % 5))) & 0xFF, 8)
                  for k in range(NC)] for o in range(NO)]
    out["wg"] = [[s((words[A_WG + 2 * ch + (k // 5)] >> (8 * (k % 5))) & 0xFF, 8)
                  for k in range(NO)] for ch in range(NC)]
    out["wb"] = [[s((words[A_WB + 2 * ch + (k // 5)] >> (8 * (k % 5))) & 0xFF, 8)
                  for k in range(NO)] for ch in range(NC)]
    return out


def check_range(consts):
    """Bound the sequencer's widest intermediate from the layer's own values.

    st_film keeps A in 36-bit signed and zq in 24 bits.  The GAP sums are
    bounded by the plane and the int9 codes; |Sg| <= (plane*254 + 32) >> 6.
    """
    sg_max = (consts["plane"] * 254 + 32) >> 6
    a_max = abs(consts["kb"]) * max(abs(v) for v in consts["br"]) \
        + 40 * 127 * sg_max
    assert a_max < (1 << 35), f"|A| {a_max} does not fit st_film's 36 bits"
    zq_max = (a_max * max(consts["mz"])) >> consts["sz"]
    assert zq_max < (1 << 24), f"zq {zq_max} does not fit st_film's 24 bits"
    return a_max, zq_max


def check(words, consts):
    d = decode(words)
    for k in ("mz", "mg", "mb", "br", "bg", "bb", "wr", "wg", "wb"):
        assert d[k] == consts[k], f"decode {k} differs"
    assert max(len(words), USED) <= DEPTH


def build_styles(m, plane, layer=None):
    """Every style's ROM words, concatenated at DEPTH words per style, and the
    per-style constants.  The shared constants are asserted equal."""
    packets = style_packets(m)

    def pick(films):
        return films[0] if layer is None else next(f for f in films if f["name"] == layer)

    specs = [pick(p["film_layers"]) for p in packets]
    shifts = film_shifts(specs, plane)
    words, consts = [], []
    for k, spec in enumerate(specs):
        w, c = build(spec, plane, shifts)
        check(w, c)
        check_range(c)
        for key in ("sz", "sg", "sb", "c0", "kb"):
            if consts:
                assert c[key] == consts[0][key], \
                    f"style {k}: {key} {c[key]} differs from style 0's {consts[0][key]}"
        words += w
        consts.append(c)
    return words, consts


def params_text(consts):
    """The st_net_pkg localparams st_film's parameters are fed from."""
    return "\n".join([
        f"  localparam int ST_FILM_SZ = {consts['sz']};   // zq  = (A*Mz + 2**(SZ-1)) >>> SZ",
        f"  localparam int ST_FILM_SG = {consts['sg']};   // mul = C0 + (Gb*Mg + 2**(SG-1)) >>> SG",
        f"  localparam int ST_FILM_SB = {consts['sb']};   // off = (Bb*Mb + 2**(SB-1)) >>> SB",
        f"  localparam int ST_FILM_C0 = {consts['c0']};   // affine offset, 19-bit signed",
        f"  localparam int ST_FILM_KB = {consts['kb']};   // reduce bias scale, br_o * KB",
    ])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--plane", type=int, default=57600)
    ap.add_argument("--out", default=None,
                    help="output directory (not needed with --params)")
    ap.add_argument("--layer", default=None, help="film layer name (default: the first)")
    ap.add_argument("--params", action="store_true",
                    help="print the st_net_pkg localparams and write nothing")
    a = ap.parse_args()
    if not a.params and a.out is None:
        ap.error("--out is required unless --params is given")

    m = json.loads((Path(a.manifest) / "manifest.json").read_text())
    words, styles = build_styles(m, a.plane, a.layer)
    consts = styles[0]
    a_max, zq_max = max(check_range(c) for c in styles)
    if a.params:
        print(params_text(consts))
        return

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "st_film.hex", "w") as fh:
        for w in words:
            fh.write(f"{w:010x}\n")
    (out / "st_film.json").write_text(json.dumps(consts, indent=1) + "\n")
    print(f"st_gen_film: {out}/st_film.hex, {len(styles)} styles x {USED} of {DEPTH} words, "
          f"layer {consts['layer']} "
          f"(sz {consts['sz']} sg {consts['sg']} sb {consts['sb']} c0 {consts['c0']} "
          f"kb {consts['kb']})")
    print(f"st_gen_film: |A| <= {a_max} < 2**36, zq <= {zq_max} < 2**24")
    print(params_text(consts))


if __name__ == "__main__":
    main()
