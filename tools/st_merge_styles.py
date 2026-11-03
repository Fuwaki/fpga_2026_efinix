#!/usr/bin/env python3
"""Merge one-style W8A8 exports of a packed guided net into one multi-style
manifest directory.

The exports must come from st_split_styles.py and share one calibration, so
everything but the style packet is the same: weights.bin, the layers, the
graph and every point scale.  The script checks that and fails otherwise.

The merged manifest.json is style 0's, plus

  "style_packets": [{"norm_layers": [...], "film_layers": [...]}, ...]

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
            if key not in PACKET_KEYS:
                assert m[key] == ms[0][key], f"style {k}: manifest field {key} differs from style 0"
        assert set(m) == set(ms[0]), f"style {k}: manifest fields differ"

    out = dict(ms[0])
    out["style_packets"] = [{key: m[key] for key in PACKET_KEYS} for m in ms]
    out.setdefault("notes", []).append(
        f"style_packets: {len(ms)} styles; packet k replaces norm_layers and film_layers, "
        "everything else is shared")
    os.makedirs(a.out, exist_ok=True)
    json.dump(out, open(os.path.join(a.out, "manifest.json"), "w"), indent=1)
    for f in ("weights.bin", "model.json", "calibration.json"):
        if os.path.exists(os.path.join(a.dirs[0], f)):
            shutil.copy(os.path.join(a.dirs[0], f), os.path.join(a.out, f))
    print(f"wrote {a.out}: {len(ms)} styles, {len(wb[0])} weight bytes shared")


if __name__ == "__main__":
    main()
