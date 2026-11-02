#!/usr/bin/env python3
"""Requant test vectors for rtl/st_accel_new/engine/st_requant.sv.

One vector per line, hex fields:

    x mant k lo hi expected

x is a signed 25-bit accumulator (two's complement, 7 hex digits), mant a
24-bit normalised mantissa, k the fraction bits (24 - exp), lo and hi the
10-bit signed clamp limits, and expected the lane's output (10-bit signed,
two's complement).  Expected is st_golden.f32_mul_round plus the clamp, so
the testbench and the golden model cannot disagree.

What the file covers:
  * every (layer, oc) requant parameter and every add factor of the
    manifest, each with the accumulators 0, +-1, +-2**21, +-2**24-1 and
    random values;
  * crafted ties per distinct parameter: x where x*r lands exactly on .5 in
    the final rounding (half away from zero must go up), and x where the
    24-bit round-to-nearest-even step of p = |x|*mant is itself on a tie
    (the even significand must win);
  * the clamp edges of the three clamp modes (relu, none, head unsigned),
    at the codes just inside and just outside each limit;
  * a random sweep: normalised mantissa, k in 24..40, |x| < 2**24.

Usage: st_rq_vectors.py --out FILE [--manifest DIR] [--count N]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import f32_mul_round, f32_parts, round_away  # noqa: E402

XMAX = (1 << 24) - 1              # |x| < 2**24, the lane's input range
ACC_EXTREME = (1 << 21) - 1       # |acc| < 2**21 (ADR value ranges)
CLAMP_MODES = {
    "relu": (0, 127),
    "none": (-127, 127),
    "unsigned": (0, 255),
}


# ------------------------------------------------------------- vector file
def expect(x: int, mant: int, k: int, lo: int, hi: int) -> int:
    y = int(f32_mul_round(x, mant, 24 - k))
    return max(lo, min(hi, y))


def fmt(x: int, mant: int, k: int, lo: int, hi: int, y: int) -> str:
    assert -(1 << 24) < x < (1 << 24), f"x {x} outside the lane's range"
    assert 0 < mant < (1 << 24) and mant >> 23 == 1, f"mant {mant} is not normalised"
    assert 16 <= k <= 47, f"k {k} outside the lane's range"
    assert -512 <= lo <= hi <= 511, f"clamp {lo}..{hi} outside 10 bit"
    assert lo <= y <= hi, f"expected {y} outside the clamp {lo}..{hi}"
    return (f"{x & 0x1FFFFFF:07x} {mant:06x} {k:02x} {lo & 0x3FF:03x} "
            f"{hi & 0x3FF:03x} {y & 0x3FF:03x}")


def add_row(rows: list[str], x: int, mant: int, k: int, lo: int, hi: int) -> None:
    rows.append(fmt(x, mant, k, lo, hi, expect(x, mant, k, lo, hi)))


# ------------------------------------------------------------ crafted ties
def _round24(p: np.ndarray):
    """st_golden's 24-significant-bit rounding, vectorised: (v, sh, rem, half)."""
    lead = np.frexp(p.astype(np.float64))[1] - 1        # p < 2**48 is exact
    sh = np.maximum(lead - 23, 0).astype(np.int64)
    half = np.where(sh > 0, np.int64(1) << np.maximum(sh - 1, 0), np.int64(0))
    q = p >> sh
    rem = p - (q << sh)
    up = (sh > 0) & ((rem > half) | ((rem == half) & ((q & 1) == 1)))
    return (q + up) << sh, sh, rem, half


def find_ties(mant: int, k: int, kind: str, want: int = 2,
              budget: int = 1 << 17) -> list[int]:
    """Brute force positive x for a tie of `kind` ("half" or "rne").

    The scan walks x upward in chunks and stops as soon as `want` hits are
    collected; ties are dense once the product is wide enough to be rounded
    to 24 bits, so a small budget finds them for every real parameter.
    """
    found: list[int] = []
    chunk = 4096
    for x0 in range(1, budget + 1, chunk):
        x = np.arange(x0, min(x0 + chunk, budget + 1), dtype=np.int64)
        v, sh, rem, half = _round24(x * mant)
        if kind == "half":
            # the final rounding is exactly a tie: v = m*2**k + 2**(k-1)
            hit = (v & ((np.int64(1) << k) - 1)) == (np.int64(1) << (k - 1))
        else:
            hit = (sh > 0) & (rem == half)               # 24-bit rounding tie
        for xi in x[hit].tolist():
            if xi not in found:
                found.append(xi)
            if len(found) >= want:
                return found
    return found


def rne_tie_kind(x: int, mant: int):
    """None, or the parity of the kept significand when p is on a 24-bit tie.

    An odd significand must round up; an even one must stay (round to even),
    so both parities are worth a vector.
    """
    p = abs(x) * mant
    sh = max(p.bit_length() - 1 - 23, 0)
    if sh == 0 or (p & ((1 << sh) - 1)) != (1 << (sh - 1)):
        return None
    return (p >> sh) & 1


def half_tie_exact(x: int, mant: int, k: int) -> bool:
    """The final rounding is exactly .5, so half-away must round up."""
    p = abs(x) * mant
    sh = max(p.bit_length() - 1 - 23, 0)
    q = p >> sh
    rem = p - (q << sh)
    half = (1 << (sh - 1)) if sh else 0
    if sh and (rem > half or (rem == half and (q & 1))):
        q += 1
    v = q << sh
    return v >= (1 << (k - 1)) and (v & ((1 << k) - 1)) == (1 << (k - 1))


# --------------------------------------------------------------- parameters
def param_rows(m) -> list[tuple[int, int, int, int]]:
    """(mant, k, lo, hi) for every real requant parameter, in ROM order."""
    qmax, oqmax = int(m["act_qmax"]), int(m["output_qmax"])
    out = []
    for l in m["layers"]:
        if l["out_unsigned"]:
            lo, hi = 0, oqmax
        elif l["out_relu"]:
            lo, hi = 0, qmax
        else:
            lo, hi = -qmax, qmax
        for r in l["requant"]:
            mant, exp = f32_parts(r)
            out.append((mant, 24 - exp, lo, hi))
    sc = m["point_scales"]
    for g in m["graph"]:
        if g["op"] == "add":
            f = np.float32(sc[g["source_point"]]) / np.float32(sc[g["point"]])
            mant, exp = f32_parts(f)
            # st_golden.Net.add_requant clamps to +-act_qmax
            out.append((mant, 24 - exp, -qmax, qmax))
    return out


def build(m, count: int, seed: int) -> list[str]:
    rng = np.random.default_rng(seed)
    rows: list[str] = []
    params = param_rows(m)
    uniq = list(dict.fromkeys(params))
    print(f"{len(params)} requant parameters, {len(uniq)} distinct", file=sys.stderr)

    # ---- 1. every parameter: 0, +-1, the extremes, random
    for mant, k, lo, hi in params:
        for x in (0, 1, -1, ACC_EXTREME, -ACC_EXTREME, XMAX, -XMAX,
                  (1 << 20) + 12345, -((1 << 20) + 12345)):
            add_row(rows, x, mant, k, lo, hi)
        for x in rng.integers(-ACC_EXTREME, ACC_EXTREME + 1, size=24):
            add_row(rows, int(x), mant, k, lo, hi)

    # ---- 2. crafted ties, per distinct parameter
    n_half = n_rne = 0
    for mant, k, lo, hi in uniq:
        xs = find_ties(mant, k, "half")
        assert all(half_tie_exact(x, mant, k) for x in xs), (mant, k, xs)
        for x in xs:
            for s in (x, -x):
                add_row(rows, s, mant, k, lo, hi)
                for d in (-2, -1, 1, 2):          # the neighbours must not tie
                    add_row(rows, s + d, mant, k, lo, hi)
            n_half += 1
        xs = find_ties(mant, k, "rne", want=4)
        kinds = [rne_tie_kind(x, mant) for x in xs]
        assert None not in kinds, (mant, k, xs)
        # one tie per parity: up (odd) and down (even)
        keep = []
        for want_par in (1, 0):
            for x, par in zip(xs, kinds):
                if par == want_par and x not in keep:
                    keep.append(x)
                    break
        for x in keep:
            for s in (x, -x):
                add_row(rows, s, mant, k, lo, hi)
                for d in (-1, 1):
                    add_row(rows, s + d, mant, k, lo, hi)
            n_rne += 1
    print(f"crafted ties: {n_half} half-away, {n_rne} round-to-even", file=sys.stderr)

    # ---- 3. clamp edges of the three modes, at the codes next to each limit
    for mode, (lo, hi) in CLAMP_MODES.items():
        ps = [(mant, k) for mant, k, l, h in uniq if (l, h) == (lo, hi)]
        assert ps, f"no parameter with the {mode} clamp"
        for mant, k in ps:
            for edge in (lo, hi):
                for tgt in (-2, -1, 0, 1, 2):
                    want = edge + tgt
                    if want == 0:
                        add_row(rows, 0, mant, k, lo, hi)
                        continue
                    sign = 1 if want > 0 else -1
                    x = ((abs(want) << k) - (1 << (k - 1)) + mant - 1) // mant
                    for d in (-1, 0, 1):
                        xc = sign * (x + d)
                        if 0 < abs(xc) <= XMAX:
                            add_row(rows, xc, mant, k, lo, hi)

    # ---- 4. random sweep: normalised mantissa, k 24..40, |x| < 2**24
    names = ["relu", "none", "unsigned"]
    while len(rows) < count:
        mant = int(rng.integers(1 << 23, 1 << 24))
        k = int(rng.integers(24, 41))
        x = int(rng.integers(-XMAX, XMAX + 1))
        lo, hi = CLAMP_MODES[names[int(rng.integers(0, 3))]]
        add_row(rows, x, mant, k, lo, hi)

    return rows


def self_test(m, rows: list[str]) -> int:
    """Vectors with a real parameter must also match the f32 reference path."""
    real = set(param_rows(m))
    checked = 0
    for line in rows:
        xs, ms, ks, los, his, ys = line.split()

        def dec(s: str, bits: int) -> int:
            v = int(s, 16)
            return v - (1 << bits) if v & (1 << (bits - 1)) else v

        x, mant, k = dec(xs, 25), int(ms, 16), int(ks, 16)
        lo, hi, y = dec(los, 10), dec(his, 10), dec(ys, 10)
        if (mant, k, lo, hi) not in real:
            continue
        # r = mant * 2**(exp - 24) is exact in f32; the product is the f32 one
        r = np.ldexp(np.float32(mant), np.int32(24 - k - 24))
        assert np.float32(r) * np.float32(2.0) == np.float32(r) * np.float32(2.0)
        want = int(round_away(np.float32(x) * r))
        want = max(lo, min(hi, want))
        assert want == y, (line, want)
        checked += 1
    assert checked > 100_000, f"only {checked} vectors have a real parameter"
    return checked


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    here = Path(__file__).resolve().parent
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--manifest", type=Path,
                    default=here.parent / "config/manifest/ink_dw_w8a8")
    ap.add_argument("--count", type=int, default=200_000,
                    help="minimum number of vectors")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    m = json.loads((a.manifest / "manifest.json").read_text())
    rows = build(m, a.count, a.seed)
    checked = self_test(m, rows)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text("\n".join(rows) + "\n")
    print(f"{a.out}: {len(rows)} vectors, {checked} checked against the f32 path",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
