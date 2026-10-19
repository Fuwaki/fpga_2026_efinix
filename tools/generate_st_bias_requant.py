#!/usr/bin/env python3
"""Generate the board bias/requant ROM images from the quantized layer metadata.

The board RTL uses one fixed 256-byte bias block and one 128-byte requant block
per selected layer:

    bias_mem[layer*256 + oc*4 + byte]  = int32(bias[oc])
    rq_mem  [layer*128 + oc*2 + byte]  = uint16(M[oc])

Remaining entries stay zero.  The sidecar metadata is produced by the training
export and is the source of truth for the per-layer quantization parameters.
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

BIAS_STRIDE = 256
RQ_STRIDE = 128


def encode(meta: list[dict]) -> tuple[bytearray, bytearray]:
    bias = bytearray(len(meta) * BIAS_STRIDE)
    rq = bytearray(len(meta) * RQ_STRIDE)
    for i, layer in enumerate(meta):
        b = struct.pack("<%di" % len(layer["bias"]), *layer["bias"])
        m = struct.pack("<%dH" % len(layer["M"]), *layer["M"])
        if len(b) > BIAS_STRIDE:
            raise SystemExit(f"{layer['name']}: bias exceeds {BIAS_STRIDE} bytes")
        if len(m) > RQ_STRIDE:
            raise SystemExit(f"{layer['name']}: requant exceeds {RQ_STRIDE} bytes")
        bias[i * BIAS_STRIDE:i * BIAS_STRIDE + len(b)] = b
        rq[i * RQ_STRIDE:i * RQ_STRIDE + len(m)] = m
    return bias, rq


def render(data: bytes) -> str:
    return "".join(f"{x:02x}\n" for x in data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--meta", type=Path, required=True)
    ap.add_argument("--bias", type=Path, required=True)
    ap.add_argument("--requant", type=Path, required=True)
    args = ap.parse_args()
    meta = json.loads(args.meta.read_text())
    bias, rq = encode(meta)
    args.bias.write_text(render(bias))
    args.requant.write_text(render(rq))
    print(f"PASS bias/requant: {len(meta)} layers, "
          f"bias={len(bias)} B, requant={len(rq)} B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
