#!/usr/bin/env python3
"""Joint calibration of the one-style models of a packed guided net.

The styles share every conv and its requant, so they must share every point
scale.  The joint calibration takes, point by point, the largest scale and
absmax over the styles: no style clips more than in its own calibration.

Usage:
  st_merge_calib.py --out JOINT.json STYLE0/calibration.json STYLE1/calibration.json [...]
"""
import argparse
import json


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()

    cs = [json.load(open(f)) for f in a.files]
    out = dict(cs[0])
    for k, c in enumerate(cs):
        for key in ("arch", "points", "bits", "safety"):
            assert c[key] == cs[0][key], f"{a.files[k]}: {key} differs"
    for key in ("scales", "absmax"):
        out[key] = [max(v) for v in zip(*(c[key] for c in cs))]
    json.dump(out, open(a.out, "w"), indent=1)
    worst = max(out["scales"][i] / min(c["scales"][i] for c in cs) for i in range(len(out["scales"])))
    print(f"wrote {a.out}: {len(out['points'])} points, largest scale growth x{worst:.3f}")


if __name__ == "__main__":
    main()
