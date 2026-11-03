#!/usr/bin/env python3
"""Parameter and MAC counts of the guided net and the CycleGAN generators,
plus ONNX exports for the CPU latency comparison (st_net_eval.py).

The guided net is counted from its manifest (the deployed W8A8 network).  The
ONNX export is a shape replica with random weights: latency does not depend on
the values.  CycleGAN is the ResNet generator of Zhu et al. (ICCV17,
pytorch-CycleGAN-and-pix2pix `resnet_9blocks` / `resnet_6blocks`, ngf 64,
InstanceNorm, reflect padding), untrained.

Usage:
  st_net_baselines.py --manifest DIR [--onnx-dir DIR] [--width 640 --height 360]
"""
import argparse
import json
import os

import torch
import torch.nn as nn
import torch.nn.functional as F


# --------------------------------------------------------------- guided net

def manifest_counts(mdir, w, h):
    """Per-layer (name, op, shape, params, macs) at a w x h network input."""
    m = json.load(open(os.path.join(mdir, "manifest.json")))
    # Resolution of each point: image H, pool H2, the trunk H4 (enc0 is stride 2).
    # Point resolutions follow the layer chain; a layer whose output point is
    # upsampled in the graph (p13, p19) writes the 2x grid.
    res = {0: (w, h), 1: (w // 2, h // 2)}
    rows = []
    ups = {g["point"] for g in m["graph"] if g["op"] == "upsample_nearest2x"}
    for l in m["layers"]:
        # the layer norm (p11) and FiLM (p18) keep their source point's grid
        for dst, src in ((11, 10), (18, 17)):
            if src in res:
                res[dst] = res[src]
        iw, ih = res[l["in_point"]]
        sw, sh = l["stride"]
        ow, oh = iw // sw, ih // sh
        if l["out_point"] in ups:
            ow, oh = ow * 2, oh * 2
        res[l["out_point"]] = (ow, oh)
        kh, kw = l["kernel"]
        cin, cout, g = l["in_channels"], l["out_channels"], l["groups"]
        wts = cout * (cin // g) * kh * kw
        params = wts + cout
        # MACs at the conv's own output grid (before any upsample)
        macs = (iw // sw) * (ih // sh) * cout * (cin // g) * kh * kw
        rows.append(dict(name=l["name"], op=l["op"], cin=cin, cout=cout, k=f"{kh}x{kw}",
                         stride=sw, groups=g, out=f"{iw // sw}x{ih // sh}",
                         weights=wts, bias=cout, params=params, macs=macs))
    for n in m["norm_layers"]:
        p = 2 * n["channels"]
        hw = (w // 4) * (h // 4)
        rows.append(dict(name=n["name"], op="layer_norm", cin=n["channels"], cout=n["channels"],
                         k="-", stride=1, groups=1, out=f"{w // 4}x{h // 4}", weights=0, bias=0, params=p,
                         macs=hw * n["channels"]))
    for f in m["film_layers"]:
        p = 0
        for k in ("reduce", "gamma", "beta"):
            p += f[k]["in_channels"] * f[k]["out_channels"] + f[k]["out_channels"]
        hw = (w // 2) * (h // 2)
        rows.append(dict(name=f["name"], op="film (GAP+MLP)", cin=f["channels"], cout=f["channels"],
                         k="-", stride=1, groups=1, out=f"{w // 2}x{h // 2}", weights=p - f["hidden"] - 2 * f["channels"],
                         bias=f["hidden"] + 2 * f["channels"], params=p,
                         macs=p - f["hidden"] - 2 * f["channels"] + hw * f["channels"]))
    return m, rows


class GuidedReplica(nn.Module):
    """Same layer shapes and dataflow as the manifest graph, random weights."""

    def __init__(self, m):
        super().__init__()
        self.m = m
        self.convs = nn.ModuleDict()
        for l in m["layers"]:
            kh, kw = l["kernel"]
            self.convs[l["name"].replace(".", "_")] = nn.Conv2d(
                l["in_channels"], l["out_channels"], (kh, kw), l["stride"],
                padding=(kh // 2, kw // 2), padding_mode="reflect" if kh > 1 else "zeros",
                groups=l["groups"])
        n = m["norm_layers"][0]
        self.n_ln = n["channels"]
        self.ln_g = nn.Parameter(torch.ones(n["channels"]))
        self.ln_b = nn.Parameter(torch.zeros(n["channels"]))
        f = m["film_layers"][0]
        self.f_red = nn.Linear(f["channels"], f["hidden"])
        self.f_g = nn.Linear(f["hidden"], f["channels"])
        self.f_b = nn.Linear(f["hidden"], f["channels"])

    def c(self, name, x, relu=True):
        y = self.convs[name.replace(".", "_")](x)
        return F.relu(y) if relu else y

    def forward(self, img):
        p1 = F.avg_pool2d(img, 2)
        x = self.c("stem", p1)
        x = self.c("enc0.dw", x)
        x = self.c("enc0.pw", x)
        x = self.c("enc1.dw", x)
        p6 = self.c("enc1.pw", x)
        x = self.c("res0.s1.dw", p6)
        x = self.c("res0.s1.pw", x)
        x = self.c("res0.s2.dw", x)
        x = self.c("res0.s2.pw", x, relu=False) + p6
        x = F.layer_norm(x.permute(0, 2, 3, 1), (self.n_ln,), self.ln_g, self.ln_b).permute(0, 3, 1, 2)
        x = self.c("dec_h4.dw", x)
        x = self.c("dec_h4.pw", x)
        x = F.interpolate(x, scale_factor=2, mode="nearest")
        x = self.c("dec_h2.dw", x)
        x = self.c("dec_h2.pw", x)
        x = x + self.c("h2_proj", self.c("h2_guide", p1), relu=False)
        z = F.relu(self.f_red(x.mean((2, 3))))
        x = x * self.f_g(z)[:, :, None, None] + self.f_b(z)[:, :, None, None]
        x = self.c("to_guide", x)
        x = F.interpolate(x, scale_factor=2, mode="nearest")
        x = x + self.c("guide", img)
        x = self.c("head.dw", x)
        return torch.sigmoid(self.c("head.pw", x, relu=False))


# --------------------------------------------------------------- CycleGAN

class ResBlock(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.b = nn.Sequential(
            nn.ReflectionPad2d(1), nn.Conv2d(c, c, 3), nn.InstanceNorm2d(c), nn.ReLU(True),
            nn.ReflectionPad2d(1), nn.Conv2d(c, c, 3), nn.InstanceNorm2d(c))

    def forward(self, x):
        return x + self.b(x)


def resnet_generator(n_blocks, ngf=64):
    layers = [nn.ReflectionPad2d(3), nn.Conv2d(3, ngf, 7), nn.InstanceNorm2d(ngf), nn.ReLU(True)]
    c = ngf
    for _ in range(2):
        layers += [nn.Conv2d(c, 2 * c, 3, 2, 1), nn.InstanceNorm2d(2 * c), nn.ReLU(True)]
        c *= 2
    layers += [ResBlock(c) for _ in range(n_blocks)]
    for _ in range(2):
        layers += [nn.ConvTranspose2d(c, c // 2, 3, 2, 1, output_padding=1),
                   nn.InstanceNorm2d(c // 2), nn.ReLU(True)]
        c //= 2
    layers += [nn.ReflectionPad2d(3), nn.Conv2d(c, 3, 7), nn.Tanh()]
    return nn.Sequential(*layers)


def conv_macs(model, x):
    """MACs of every Conv2d / ConvTranspose2d / Linear, by forward hooks."""
    total = [0]

    def hook(mod, inp, out):
        if isinstance(mod, nn.Conv2d):
            k = mod.kernel_size[0] * mod.kernel_size[1] * mod.in_channels // mod.groups
            total[0] += out.numel() // out.shape[0] * k
        elif isinstance(mod, nn.ConvTranspose2d):
            k = mod.kernel_size[0] * mod.kernel_size[1] * mod.out_channels
            total[0] += inp[0].numel() // inp[0].shape[0] * k
        elif isinstance(mod, nn.Linear):
            total[0] += mod.in_features * mod.out_features

    hs = [mm.register_forward_hook(hook) for mm in model.modules()
          if isinstance(mm, (nn.Conv2d, nn.ConvTranspose2d, nn.Linear))]
    with torch.no_grad():
        model(x)
    for hh in hs:
        hh.remove()
    return total[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--onnx-dir")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--json")
    a = ap.parse_args()
    w, h = a.width, a.height

    m, rows = manifest_counts(a.manifest, w, h)
    print(f"guided net, {w}x{h} input")
    print(f"{'layer':12s} {'op':24s} {'cin':>4s} {'cout':>4s} {'k':>4s} {'s':>2s} {'out':>8s} {'params':>7s} {'MMAC':>8s}")
    for r in rows:
        print(f"{r['name']:12s} {r['op']:24s} {r['cin']:4d} {r['cout']:4d} {r['k']:>4s} {r['stride']:2d} "
              f"{r['out']:>8s} {r['params']:7d} {r['macs'] / 1e6:8.2f}")
    gp = sum(r["params"] for r in rows)
    gm = sum(r["macs"] for r in rows)
    print(f"{'total':12s} {'':24s} {'':4s} {'':4s} {'':4s} {'':2s} {'':8s} {gp:7d} {gm / 1e6:8.2f}")
    print(f"weight bytes (manifest, int8 conv weights) {m['weight_bytes']}")

    x = torch.zeros(1, 3, h, w)
    nets = {"guided": GuidedReplica(m).eval(),
            "cyclegan_r6": resnet_generator(6).eval(),
            "cyclegan_r9": resnet_generator(9).eval()}
    out = {"guided_rows": rows, "nets": {}}
    for name, net in nets.items():
        p = sum(t.numel() for t in net.parameters())
        mac = conv_macs(net, x)
        out["nets"][name] = dict(params=p, macs=mac)
        print(f"{name:12s} params {p:9d}  fp32 {p * 4 / 1e6:6.2f} MB  int8 {p / 1e6:6.2f} MB  {mac / 1e9:7.2f} GMAC")
        if a.onnx_dir:
            os.makedirs(a.onnx_dir, exist_ok=True)
            path = os.path.join(a.onnx_dir, f"{name}.onnx")
            torch.onnx.export(net, x, path, input_names=["x"], output_names=["y"], dynamo=False)
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
