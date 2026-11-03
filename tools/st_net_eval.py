#!/usr/bin/env python3
"""Image quality (PSNR / SSIM against the teacher) and CPU latency of the
guided net, the White-box teacher and the CycleGAN generators.

Quality: every directory of --set holds the same file names; the first is the
reference.  An image twice the reference size (the board's PROC slot) is
2x2-averaged first.  SSIM is Wang et al. 2004 (Gaussian window 11, sigma 1.5,
K1 0.01, K2 0.03, on 0..255), the mean over R, G and B.

Latency: ONNX Runtime on the CPU, median of --runs after two warm-up runs.

Usage:
  st_net_eval.py --teacher-out DIR --teacher-in DIR       (run the teacher)
  st_net_eval.py --set NAME REF DIR [DIR ...] [--set ...]
  st_net_eval.py --latency a.onnx [b.onnx ...] --width 640 --height 360
  st_net_eval.py --teacher-macs --width 640 --height 360
"""
import argparse
import os
import statistics
import sys
import time

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

HERE = os.path.dirname(os.path.abspath(__file__))
TEACHER = os.path.join(HERE, "../../teachers/whitebox/cartoonizer.onnx")


def load(path, shape=None):
    a = np.asarray(Image.open(path).convert("RGB"), np.float64)
    if shape is not None and a.shape[:2] == (2 * shape[0], 2 * shape[1]):
        a = a.reshape(shape[0], 2, shape[1], 2, 3).mean((1, 3))
    return a


def psnr(a, b):
    mse = np.mean((a - b) ** 2)
    return 10 * np.log10(255.0 ** 2 / mse)


def ssim(a, b):
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    vals = []
    for ch in range(3):
        x, y = a[..., ch], b[..., ch]
        # truncate=3.5 gives the 11-tap window of the reference implementation
        f = lambda v: gaussian_filter(v, 1.5, truncate=3.5)
        mx, my = f(x), f(y)
        sxx, syy, sxy = f(x * x) - mx * mx, f(y * y) - my * my, f(x * y) - mx * my
        m = ((2 * mx * my + c1) * (2 * sxy + c2)) / ((mx * mx + my * my + c1) * (sxx + syy + c2))
        vals.append(m[5:-5, 5:-5].mean())
    return float(np.mean(vals))


def quality(name, ref, dirs):
    files = sorted(f for f in os.listdir(ref) if f.endswith(".png"))
    print(f"\n## {name}  (reference {ref}, {len(files)} images)")
    print(f"{'dir':40s} {'PSNR dB':>8s} {'SSIM':>7s}   per image PSNR")
    for d in dirs:
        ps, ss = [], []
        for f in files:
            r = load(os.path.join(ref, f))
            x = load(os.path.join(d, f), r.shape[:2])
            assert x.shape == r.shape, (d, f, x.shape, r.shape)
            ps.append(psnr(x, r))
            ss.append(ssim(x, r))
        per = " ".join(f"{os.path.splitext(f)[0]}={p:.2f}" for f, p in zip(files, ps))
        print(f"{d:40s} {np.mean(ps):8.2f} {np.mean(ss):7.4f}   {per}")


def session(path, threads):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.log_severity_level = 3
    so.intra_op_num_threads = threads
    return ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])


def run_teacher(in_dir, out_dir):
    sess = session(TEACHER, os.cpu_count())
    os.makedirs(out_dir, exist_ok=True)
    for f in sorted(os.listdir(in_dir)):
        img = np.asarray(Image.open(os.path.join(in_dir, f)).convert("RGB"), np.float32)
        h, w = img.shape[:2]
        assert h % 4 == 0 and w % 4 == 0, f"{f}: teacher needs multiples of 4"
        x = (img[:, :, ::-1] / 127.5 - 1.0)[None]
        y = sess.run(None, {sess.get_inputs()[0].name: x})[0][0]
        y = np.clip((y + 1.0) * 127.5, 0, 255).astype(np.uint8)[:, :, ::-1]
        Image.fromarray(np.ascontiguousarray(y)).save(os.path.join(out_dir, os.path.splitext(f)[0] + ".png"))


def latency(paths, w, h, runs, threads_list):
    print(f"\n## CPU latency, {w}x{h}, ONNX Runtime, median of {runs}")
    print(f"{'model':28s} " + " ".join(f"{f'{t} thr ms':>10s}" for t in threads_list))
    for p in paths:
        row = []
        for t in threads_list:
            sess = session(p, t)
            inp = sess.get_inputs()[0]
            # the teacher is NHWC, the exports NCHW
            shape = (1, h, w, 3) if inp.shape[-1] == 3 else (1, 3, h, w)
            x = np.random.default_rng(0).uniform(-1, 1, shape).astype(np.float32)
            for _ in range(2):
                sess.run(None, {inp.name: x})
            ts = []
            for _ in range(runs):
                t0 = time.perf_counter()
                sess.run(None, {inp.name: x})
                ts.append((time.perf_counter() - t0) * 1e3)
            row.append(statistics.median(ts))
        print(f"{os.path.basename(p):28s} " + " ".join(f"{v:10.1f}" for v in row))
        sys.stdout.flush()


def teacher_macs(w, h):
    """Conv MACs and parameters of the teacher at a fixed input size: every
    Conv output becomes a graph output, one run gives their shapes."""
    import onnx
    import onnxruntime as ort
    m = onnx.load(TEACHER)
    inits = {t.name: list(t.dims) for t in m.graph.initializer}
    params = sum(int(np.prod(d)) for d in inits.values())
    convs = [n for n in m.graph.node if n.op_type == "Conv"]
    have = {o.name for o in m.graph.output}
    for n in convs:
        if n.output[0] not in have:
            m.graph.output.append(onnx.ValueInfoProto(name=n.output[0]))
    so = ort.SessionOptions()
    so.log_severity_level = 3
    sess = ort.InferenceSession(m.SerializeToString(), so, providers=["CPUExecutionProvider"])
    names = [n.output[0] for n in convs]
    outs = sess.run(names, {sess.get_inputs()[0].name: np.zeros((1, h, w, 3), np.float32)})
    macs = sum(int(np.prod(o.shape[1:])) * int(np.prod(inits[n.input[1]][1:]))
               for n, o in zip(convs, outs))
    print(f"teacher {w}x{h}: params {params}  fp32 {params * 4 / 1e6:.2f} MB  {macs / 1e9:.2f} GMAC (Conv only)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", nargs="+", action="append", metavar="NAME REF DIR")
    ap.add_argument("--teacher-in")
    ap.add_argument("--teacher-out")
    ap.add_argument("--latency", nargs="+")
    ap.add_argument("--teacher-macs", action="store_true")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--threads", type=int, nargs="+", default=[1, os.cpu_count()])
    a = ap.parse_args()
    if a.teacher_in:
        run_teacher(a.teacher_in, a.teacher_out)
    for s in a.set or []:
        quality(s[0], s[1], s[2:])
    if a.teacher_macs:
        teacher_macs(a.width, a.height)
    if a.latency:
        latency(a.latency, a.width, a.height, a.runs, a.threads)


if __name__ == "__main__":
    main()
