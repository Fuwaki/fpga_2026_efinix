#!/usr/bin/env python3
"""Split a trained multi-style packet table (torch params.pt from the astra
trainer) into single-style tiny_dw_guided checkpoints for export-int8.

Style k gets its LN and FiLM under the plain names, and its per-style affines
`x * exp(log_gain) + bias` folded into the conv in front of them:

    guide_affine -> guide.conv          (before the ReLU)
    head_affine  -> head_sep.dw.conv    (before the ReLU)
    out_affine   -> head_sep.pw.conv    (the RGB output)

W' = W * g per output channel, b' = b * g + bias.  With g > 0 and per-channel
int8 weights the weight codes do not depend on g, so the styles still share
weights.bin (st_merge_styles.py checks it).

    ~/.venvs/astra/bin/python tools/st_split_packets.py \\
        --params ../fpga_st_train/runs/astra2/train/s3e/params.pt \\
        --template ../fpga_st_train/runs/astra2/split/bright --out ../st_work/s3e

The template is any single-style checkpoint of the same structure; only its
parameter values are replaced.  Writes OUT/style0..N-1 and checks each against
the trainer's torch forward (fp32, through the Rust `infer`).
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
TRAIN = ROOT / "fpga_st_train"
sys.path.insert(0, str(TRAIN / "tools/astra/torchnet"))
sys.path.insert(0, str(TRAIN / "tools/astra"))
from net import forward, load_params, read  # noqa: E402
from weights import Checkpoint  # noqa: E402

FOLD = {"guide_affine": "guide.conv", "head_affine": "head_sep.dw.conv",
        "out_affine": "head_sep.pw.conv"}
PACKET = ("trunk_norm.", "film_h2.")


def n_styles(p):
    return 1 + len({k.split(".")[1] for k in p if k.startswith("style_packets.")})


def single(p, k):
    """Plain parameter table of style k, affines folded."""
    pre = "" if k == 0 else f"style_packets.{k-1}."
    q = {n: v.detach().clone() for n, v in p.items()
         if not n.startswith("style_packets.") and not n.split(".")[0] in FOLD}
    for n in list(q):
        if n.startswith(PACKET) and k:
            q[n] = p[pre + n].detach().clone()
    for what, conv in FOLD.items():
        lg = pre + what + ".log_gain"
        if lg not in p:
            continue
        g = torch.exp(p[lg].detach())
        w, b = q[conv + ".weight"], q[conv + ".bias"]
        q[conv + ".weight"] = w * g.view(-1, *([1] * (w.dim() - 1)))
        q[conv + ".bias"] = b * g + p[pre + what + ".bias"].detach()
    return q


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--params", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--binary", default=str(TRAIN / "target/release/fpga_st_train"))
    ap.add_argument("--image", default=str(TRAIN / "experiments/tiny_dw_whitebox_sky_480p/trials/packets/content_cat.png"))
    a = ap.parse_args()

    p = torch.load(a.params)
    out = Path(a.out)
    report = {}
    for k in range(n_styles(p)):
        q = single(p, k)
        ck = Checkpoint.open(a.template)
        names = set(load_params(ck))
        assert names == set(q), f"style {k}: names differ: {sorted(names ^ set(q))}"
        for n in sorted(names):
            v = q[n].numpy().astype("<f4")
            assert v.shape == ck.shape(n), (n, v.shape, ck.shape(n))
            ck.set(n, v)
        d = out / f"style{k}"
        d.mkdir(parents=True, exist_ok=True)
        ck.save(d)
        card = json.loads((Path(a.template) / "model.json").read_text())
        card.setdefault("meta", {}).update(split_from=str(a.params), split_style=k)
        (d / "model.json").write_text(json.dumps(card, indent=2) + "\n")

        # fp32 parity: Rust on the folded checkpoint vs torch on the packet table
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([a.binary, "--device", "cpu", "infer", "--model", str(d), "--content", a.image,
                            "--out", tmp, "--mode", "fp32"], check=True, capture_output=True)
            rust = read(next(Path(tmp).glob("*.png")))
        ref = forward(p, read(a.image), k).clamp(0, 1)
        diff = (ref - rust).abs()[..., :-2, :]          # reflect-pad bottom rows differ
        report[k] = dict(mae=float(diff.mean()), max=float(diff.max()))
        print(f"style {k}: {d}  fp32 vs packet table: mae {diff.mean():.5f} max {diff.max():.4f}")
        assert diff.mean() < 2e-3, "folded checkpoint does not match the packet table"
    (out / "split_report.json").write_text(json.dumps(report, indent=1) + "\n")


if __name__ == "__main__":
    main()
