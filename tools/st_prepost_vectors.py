#!/usr/bin/env python3
"""Vectors for rtl/st_accel_new/engine/st_pre.sv and st_post.sv (guided net).

Writes into --out, from tools/st_guided.py (the normative model) and a 1280x720
camera frame:

  pre_full:  in  = the ISP slot as tile_dma_rd delivers it (160 beats per
                 line, 720 lines, 128-bit beats, RGB565 little-endian, 8 px
                 per beat, pixel 0 in bits [15:0]);
             exp = 640x360 group beats of quantize_input(pre(frame));
  pre_pool:  in  = the same ISP beats;
             exp = 320x180 group beats of pool_int(p0);
  post:      in  = group beats of Guided.run(pre(frame)) (the RGB8 output,
                 lanes 0..2 = R, G, B, 0..255);
             exp = the 1280x720 PROC slot from st_guided.post(): 160 beats per
                 line, 720 lines, every pixel 2x2.
  post43:    the same input through st_guided.post_rep(4, 3) (the tiny_dw replication,
             REP_X = 4, REP_Y = 3): 320 beats per line, 1080 lines, every
             pixel 4x3.  st_post is parameterised for it.

Files per case, in a subdirectory named after the case:

  in.hex    the input beats, "%032h <sof> <eol>" (pre) or
            "%010h <last> <sof> <eol>" (post) per line;
  exp.hex   the expected output beats, same two formats (the group stream's
            flags are last, sof, eol; the DDR stream's are sof, eol).

Every expected beat comes from the golden model itself, so the RTL is compared
with the model rather than with a second implementation of it.

Usage: st_prepost_vectors.py --out DIR [--frame cam.png] [--manifest DIR]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import CAM_H, CAM_W  # noqa: E402
from st_guided import NET_H, NET_W, Guided, isp565, pool_int, post, post_rep, pre  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = Path("/data/competition/2026fpga/st_work/p90_ln_w8a8")
DEFAULT_FRAME = Path("/data/competition/2026fpga/st_work/g360/cam/cat.png")
BEAT_PIX = 8
PROC_BPL = CAM_W // BEAT_PIX           # 160 DDR beats per PROC/ISP line


# ------------------------------------------------------------------ writers
def ddr_lines(beats: bytes, bpl: int) -> list[str]:
    """DDR bytes -> one 128-bit beat per line, with sof/eol per line."""
    out = []
    for i in range(len(beats) // 16):
        v = int.from_bytes(beats[i * 16:(i + 1) * 16], "little")
        out.append(f"{v:032x} {1 if i == 0 else 0} {1 if (i + 1) % bpl == 0 else 0}")
    return out


def group_lines(codes: np.ndarray) -> list[str]:
    """CHW code tensor (3, H, W) -> one 40-bit group beat per pixel, last on
    every beat, lanes 0..2 = R, G, B in a 10-bit lane, lane 3 zero."""
    c, h, w = codes.shape
    assert c == 3, codes.shape
    out = []
    for yy in range(h):
        row = codes[:, yy, :].astype(np.int64)
        for xx in range(w):
            v = (int(row[0, xx]) & 0x3FF) | (int(row[1, xx]) & 0x3FF) << 10 \
                | (int(row[2, xx]) & 0x3FF) << 20
            out.append(f"{v:010x} 1 {1 if (yy == 0 and xx == 0) else 0} "
                       f"{1 if xx == w - 1 else 0}")
    return out


def write(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--frame", default=str(DEFAULT_FRAME),
                    help="1280x720 RGB PNG; default: the guided test frame")
    ap.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    a = ap.parse_args()

    from PIL import Image

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    frame = np.asarray(Image.open(a.frame).convert("RGB"))
    assert frame.shape[:2] == (CAM_H, CAM_W), \
        f"--frame must be {CAM_W}x{CAM_H}, got {frame.shape[1]}x{frame.shape[0]}"

    f565 = isp565(frame)                                # 720x1280
    rgb = pre(f565)                                     # 360x640x3, net input
    assert rgb.shape == (NET_H, NET_W, 3), rgb.shape

    net = Guided(a.manifest, False)
    p0 = net.quantize_input(rgb)                        # the point-0 codes
    p1 = pool_int(p0)                                   # pass 0 in POOL mode
    assert p0.shape == (3, NET_H, NET_W), p0.shape
    assert p1.shape == (3, NET_H // 2, NET_W // 2), p1.shape

    # -------- pre: the ISP slot beats in, once per mode
    isp = ddr_lines(f565.astype("<u2").tobytes(), PROC_BPL)
    for name, codes in (("pre_full", p0), ("pre_pool", p1)):
        d = out / name
        d.mkdir(exist_ok=True)
        write(d / "in.hex", isp)
        write(d / "exp.hex", group_lines(codes))

    # -------- post: the network's RGB8 output in, the PROC slot out
    head = net.run(rgb)                                 # 360x640x3 RGB8 HWC
    assert head.shape == (NET_H, NET_W, 3), head.shape
    proc = post(head)                                   # 720x1280 RGB565
    assert proc.shape == (CAM_H, CAM_W), proc.shape
    d = out / "post"
    d.mkdir(exist_ok=True)
    write(d / "in.hex", group_lines(head.transpose(2, 0, 1).astype(np.int64)))
    write(d / "exp.hex", ddr_lines(proc.astype("<u2").tobytes(), PROC_BPL))

    # -------- post43: the same input through post_rep(4, 3), the tiny_dw
    # 4x3 replication (BOX_W = 4, BOX_H = 3 in st_golden.py)
    proc43 = post_rep(head, 4, 3)
    assert proc43.shape == (3 * NET_H, 4 * NET_W), proc43.shape
    assert proc43.shape == (3 * NET_H, 4 * NET_W), proc43.shape
    d = out / "post43"
    d.mkdir(exist_ok=True)
    write(d / "in.hex", group_lines(head.transpose(2, 0, 1).astype(np.int64)))
    write(d / "exp.hex", ddr_lines(proc43.astype("<u2").tobytes(),
                                   4 * NET_W // BEAT_PIX))

    print(f"PASS st_prepost_vectors: {out}: "
          f"pre {len(isp)} in beats, full {p0.shape[2]}x{p0.shape[1]} out, "
          f"pool {p1.shape[2]}x{p1.shape[1]} out, "
          f"post {NET_W * NET_H} in / {len(proc.tobytes()) // 16} out beats, "
          f"post43 {len(proc43.tobytes()) // 16} out beats "
          f"({Path(a.frame).name}, {Path(a.manifest).name})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
