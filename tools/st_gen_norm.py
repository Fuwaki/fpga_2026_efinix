#!/usr/bin/env python3
"""Generate the LayerNorm coefficient ROM and the R LUT of st_norm.sv.

Writes into --out (all read with $readmemh):

  st_ln.hex      256 x 180-bit words, MSB first, one per line: word a is the
                 group of channels 4a..4a+3, lane j of the word (bits
                 45j+44:45j) being {B_c[27:1], G_c[17:0]} of channel 4a + j,
                 both 27/18-bit two's complement (B_c is even, ln_consts, and
                 st_norm shifts the field left by LN_BSH = 1 in LN mode).  Words 20k..20k+19 are the
                 LN image of style k (one style packet each, st_merge_styles.py;
                 a one-style manifest is style 0); the rest is zero -- st_norm
                 keeps its FiLM coefficients at 128..147 of the same array, so
                 the file must cover the whole array.  One whole-group file is what lets
                 st_norm's single 256 x 180 array be initialised by one
                 $readmemh straight into the RAM, the only form Efinity infers
                 RAM contents from.
  st_ln_lut.hex  LN_LUT, one 17-bit value per line (5 hex digits), addressed
                 by m - 256 with m the normalised D in [256, 1024).

Both tables are tools/st_guided.py's own: ln_consts (E, G_c, B_c) and
LN_LUT.  The generator checks that the model's E equals LN_E = 1 of the RTL
and fails loudly otherwise -- a different E would change every statistic.
It also checks the field widths the RTL assumes: |G_c| < 2^17 and
|B_c| < 2^27 for the coefficient word, and R < 2^17 for the LUT.

Usage: st_gen_norm.py --manifest DIR --out DIR
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import st_guided as G  # noqa: E402

LN_E_RTL = 1                # st_norm.sv: D = N*Q - S^2 + LN_E
MAX_CH = 80                 # channels the coefficient store holds
LANES = 4                   # lanes (channels) per group word
LN_WORDS = 20               # words of one style's LN image (st_norm: style * 20)
FILM_BASE = 128             # st_norm's FiLM region
WORDS = 256                 # words in st_norm's coefficient array
LANE_BITS = 45              # {B_c[26:0], G_c[17:0]}
MUL_MAX = (1 << 17) - 1     # |G_c| < 2^17, 18-bit signed
OFF_MAX = (1 << 26) - 1     # |B_c >> LN_BSH| < 2^26, 27-bit signed
LUT_MAX = (1 << 17) - 1


def coeff_lane(g: int, b: int) -> int:
    """{B_c[27:1], G_c[17:0]}, one lane of a group word of st_norm."""
    assert b % (1 << G.LN_BSH) == 0, f"B_c {b} is not a multiple of 2^LN_BSH"
    return (((b >> G.LN_BSH) & ((1 << 27) - 1)) << 18) | (g & ((1 << 18) - 1))


def group_word(g, b, base: int) -> int:
    """The 180-bit word of channels base..base+3 of a whole group."""
    w = 0
    for j in range(LANES):
        c = base + j
        gg = int(g[c]) if c < len(g) else 0
        bb = int(b[c]) if c < len(b) else 0
        w |= coeff_lane(gg, bb) << (LANE_BITS * j)
    return w


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()

    import json
    m = json.loads((a.manifest / "manifest.json").read_text())
    packets = G.style_packets(m)
    if len(packets) * LN_WORDS > FILM_BASE:
        sys.exit(f"st_gen_norm: {len(packets)} styles do not fit below the FiLM region")
    image = [0] * WORDS
    g_max = b_max = 0
    for k, pk in enumerate(packets):
        norm = pk["norm_layers"]
        if len(norm) != 1:
            sys.exit(f"st_gen_norm: style {k}: expected one norm layer, found {len(norm)}")
        spec = norm[0]
        if spec["channels"] > MAX_CH:
            sys.exit(f"st_gen_norm: {spec['channels']} channels > {MAX_CH}")

        e_add, g, b = G.ln_consts(spec)
        if int(e_add) != LN_E_RTL:
            sys.exit(f"st_gen_norm: FAIL style {k}: E = {int(e_add)} but st_norm has LN_E = {LN_E_RTL}")

        if int(np.max(np.abs(g))) > MUL_MAX:
            sys.exit(f"st_gen_norm: FAIL style {k}: |G_c| = {int(np.max(np.abs(g)))} exceeds 2^17 - 1")
        if int(np.max(np.abs(b >> G.LN_BSH))) > OFF_MAX:
            sys.exit(f"st_gen_norm: FAIL style {k}: |B_c| = {int(np.max(np.abs(b)))} exceeds 2^27 - 2")
        for a_i in range(LN_WORDS):
            image[LN_WORDS * k + a_i] = group_word(g, b, LANES * a_i)
        g_max = max(g_max, int(np.max(np.abs(g))))
        b_max = max(b_max, int(np.max(np.abs(b))))

    lut = np.asarray(G.LN_LUT, np.int64)
    lut_n = (1 << G.LN_L) - G.LN_M0
    if len(lut) != lut_n or int(lut.min()) < 0 or int(lut.max()) > LUT_MAX:
        sys.exit(f"st_gen_norm: FAIL LUT is not {lut_n} values in [0, 2^17)")

    a.out.mkdir(parents=True, exist_ok=True)
    ln_path = a.out / "st_ln.hex"
    with ln_path.open("w") as fh:
        fh.write("// st_ln.hex -- LayerNorm coefficients, one group of four\n")
        fh.write(f"// channels per word: {WORDS} x 180 bit, word a = channels "
                 f"{LANES}a..{LANES}a+{LANES-1}.\n")
        fh.write(f"// Generated by tools/st_gen_norm.py from {a.manifest.name}; "
                 "do not edit.\n")
        fh.write("// Lane j (bits 45j+44:45j) = [44:18] B_c >> 1 (27-bit signed),\n")
        fh.write(f"// [17:0] G_c (18-bit signed); words 20k..20k+19 are style k\n")
        fh.write(f"// ({len(packets)} styles), the rest zero (st_norm's FiLM region is 128..147).\n")
        for w in image:
            fh.write(f"{w:045x}\n")

    lut_path = a.out / "st_ln_lut.hex"
    with lut_path.open("w") as fh:
        fh.write("// st_ln_lut.hex -- R = round(2^20 / sqrt(m + 0.5)), m = 256..1023.\n")
        fh.write(f"// Generated by tools/st_gen_norm.py from {a.manifest.name}; do not edit.\n")
        for v in lut:
            fh.write(f"{int(v):05x}\n")

    print(f"PASS st_gen_norm: {ln_path.name} "
          f"({len(packets)} styles, {MAX_CH} channels, E = {LN_E_RTL}), "
          f"{lut_path} ({len(lut)} entries), "
          f"|G| <= {g_max}, |B| <= {b_max}, "
          f"R in [{int(lut.min())}, {int(lut.max())}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
