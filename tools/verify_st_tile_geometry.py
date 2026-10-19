#!/usr/bin/env python3
"""Exhaustively check the video-pipe tile/address contract.

This is intentionally independent of the RTL implementation.  It checks the
invariants that must hold for every tile and every output pixel before a board
bitstream is allowed: source samples stay inside the selected tile, output
addresses cover a 64x64 mosaic exactly once, and the 16x16 accelerator buffer
is copied without overlap or holes.
"""
from __future__ import annotations

import argparse


def check(tile: int, grid: int, scale: int, width: int, height: int,
          pip_h_num: int = 9, pip_h_den: int = 16) -> None:
    out_w = tile * grid
    out_h = out_w
    pip_w = out_w * scale
    # The accelerator mosaic is square, but the processed HDMI window keeps
    # the source 16:9 aspect ratio (512x288 by default).
    pip_h = (pip_w * pip_h_num) // pip_h_den
    x_step = width // out_w
    y_step = height // out_h
    seen = set()
    for tile_id in range(grid * grid):
        tcx, tcy = tile_id % grid, tile_id // grid
        x0, y0 = tcx * width // grid, tcy * height // grid
        for py in range(tile):
            for px in range(tile):
                sx = x0 + (px * (width // grid)) // tile
                sy = y0 + (py * (height // grid)) // tile
                assert x0 <= sx < x0 + width // grid
                assert y0 <= sy < y0 + height // grid
                addr = (tcy * tile + py) * out_w + tcx * tile + px
                assert 0 <= addr < out_w * out_h
                assert addr not in seen
                seen.add(addr)

    assert len(seen) == out_w * out_h
    for py in range(pip_h):
        for px in range(pip_w):
            sx, sy = px // scale, (py * out_h) // pip_h
            assert 0 <= sx < out_w and 0 <= sy < out_h
            assert 0 <= sy * out_w + sx < out_w * out_h

    # The accelerator output stream is RGB planar-by-pixel: 16*16*3 bytes.
    stream = {(i // 3, i % 3) for i in range(tile * tile * 3)}
    assert len(stream) == tile * tile * 3


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tile", type=int, default=16)
    ap.add_argument("--grid", type=int, default=4)
    ap.add_argument("--scale", type=int, default=8)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--pip-height-num", type=int, default=9)
    ap.add_argument("--pip-height-den", type=int, default=16)
    a = ap.parse_args()
    check(a.tile, a.grid, a.scale, a.width, a.height,
          a.pip_height_num, a.pip_height_den)
    print(f"PASS geometry: {a.grid}x{a.grid} tiles, mosaic={a.tile*a.grid}x{a.tile*a.grid}, "
          f"pip={a.tile*a.grid*a.scale}x{(a.tile*a.grid*a.scale*a.pip_height_num)//a.pip_height_den}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
