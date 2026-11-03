#!/usr/bin/env python3
"""Split a multi-style guided checkpoint into one-style model directories.

A packed tiny_dw_guided model (options.styles = N) keeps style 0's trunk norm
and H/2 FiLM in the ordinary fields and styles 1..N-1 in `style_packets`.
Style k's directory gets packet k-1 copied into those fields (the parameter
ids stay the base ones), an empty `style_packets`, and styles = 1, so the
one-style calibrate / export-int8 path takes it unchanged.

Usage:
  st_split_styles.py --from TRIAL_DIR --out DIR      (writes DIR/style0 .. styleN-1)
"""
import argparse
import copy
import json
import os

import msgpack


def copy_params(dst, src):
    """Copy every param payload of src into dst, keeping dst's ids."""
    if isinstance(dst, dict):
        if "param" in dst and "id" in dst:
            dst["param"] = copy.deepcopy(src["param"])
            return
        for k in dst:
            copy_params(dst[k], src[k])
    elif isinstance(dst, list):
        for a, b in zip(dst, src):
            copy_params(a, b)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    card = json.load(open(os.path.join(a.src, "model.json")))
    styles = card["options"].get("styles", 1)
    assert styles > 1, "the model has one style"
    raw = open(os.path.join(a.src, "model.mpk"), "rb").read()
    rec = msgpack.unpackb(raw, raw=False, strict_map_key=False)
    packets = rec["item"]["style_packets"]
    assert len(packets) == styles - 1, (len(packets), styles)

    for k in range(styles):
        r = copy.deepcopy(rec)
        item = r["item"]
        if k > 0:
            copy_params(item["trunk_norm"], packets[k - 1]["trunk_norm"])
            copy_params(item["film_h2"], packets[k - 1]["film_h2"])
        item["style_packets"] = []
        out = os.path.join(a.out, f"style{k}")
        os.makedirs(out, exist_ok=True)
        open(os.path.join(out, "model.mpk"), "wb").write(msgpack.packb(r, use_bin_type=True))
        c = copy.deepcopy(card)
        c["options"]["styles"] = 1
        c.setdefault("meta", {})["split_from"] = f"{os.path.abspath(a.src)} style {k}"
        json.dump(c, open(os.path.join(out, "model.json"), "w"), indent=2)
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
