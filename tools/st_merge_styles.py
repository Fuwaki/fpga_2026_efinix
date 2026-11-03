#!/usr/bin/env python3
"""Merge one-style W8A8 exports of a packed guided net into one multi-style
manifest directory.

The exports must come from one-style splits of the same packed checkpoint
(st_split_styles.py, or the training side's split) and share one
calibration, so everything but the style packet is the same: weights.bin,
the graph and every point scale.  The script checks that and fails otherwise.

A layer may still differ in its per-channel numbers: a per-style affine
folded into a conv (the guide affine, W*g and bias*g + b with g > 0) keeps
the int8 codes of W, so weights.bin is shared, and changes only
LAYER_KEYS.  Such a layer goes into every packet as an override.

The merged manifest.json is style 0's, plus

  "style_packets": [{"norm_layers": [...], "film_layers": [...],
                     "layer_overrides": {"guide": {"requant": [...], ...}}}, ...]

with one entry per style, style 0 included.  st_guided.Guided(mdir, style=k)
takes packet k; tools that know nothing of styles see style 0.

Usage:
  st_merge_styles.py --out DIR STYLE0_DIR STYLE1_DIR [...]
"""
import argparse
import json
import os
import shutil

PACKET_KEYS = ("norm_layers", "film_layers")
# per-channel layer fields a folded per-style affine may change
LAYER_KEYS = ("weight_scale", "bias", "bias_int32", "requant")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    assert len(a.dirs) >= 2, "give at least two style exports"

    ms = [json.load(open(os.path.join(d, "manifest.json"))) for d in a.dirs]
    wb = [open(os.path.join(d, "weights.bin"), "rb").read() for d in a.dirs]
    for k, (m, w) in enumerate(zip(ms, wb)):
        assert w == wb[0], f"style {k}: weights.bin differs from style 0"
        for key in m:
            if key not in PACKET_KEYS + ("layers",):
                assert m[key] == ms[0][key], f"style {k}: manifest field {key} differs from style 0"
        assert set(m) == set(ms[0]), f"style {k}: manifest fields differ"
        assert len(m["layers"]) == len(ms[0]["layers"]), f"style {k}: layer count differs"

    styled = []                 # layers whose per-channel numbers differ
    for i, l0 in enumerate(ms[0]["layers"]):
        diff = set()
        for k, m in enumerate(ms):
            l = m["layers"][i]
            assert set(l) == set(l0), f"style {k}: layer {l0['name']} fields differ"
            for key in l:
                if l[key] != l0[key]:
                    assert key in LAYER_KEYS, \
                        f"style {k}: layer {l0['name']} field {key} differs (only {LAYER_KEYS} may)"
                    diff.add(key)
        if diff:
            styled.append(l0["name"])
    for name in styled:
        print(f"layer {name}: per-style {', '.join(LAYER_KEYS)}")

    out = dict(ms[0])
    out["style_packets"] = []
    for m in ms:
        pk = {key: m[key] for key in PACKET_KEYS}
        by = {l["name"]: l for l in m["layers"]}
        pk["layer_overrides"] = {n: {key: by[n][key] for key in LAYER_KEYS} for n in styled}
        out["style_packets"].append(pk)
    out.setdefault("notes", []).append(
        f"style_packets: {len(ms)} styles; packet k replaces norm_layers and film_layers "
        f"and the {', '.join(LAYER_KEYS)} of {styled or 'no layer'}; everything else is shared")
    os.makedirs(a.out, exist_ok=True)
    json.dump(out, open(os.path.join(a.out, "manifest.json"), "w"), indent=1)
    for f in ("weights.bin", "model.json", "calibration.json"):
        if os.path.exists(os.path.join(a.dirs[0], f)):
            shutil.copy(os.path.join(a.dirs[0], f), os.path.join(a.out, f))
    print(f"wrote {a.out}: {len(ms)} styles, {len(wb[0])} weight bytes shared")


if __name__ == "__main__":
    main()
