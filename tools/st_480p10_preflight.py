#!/usr/bin/env python3
"""Preflight the ST model before putting RTL into the Ti60 project.

This deliberately generates NNgen/st_stream RTL in a temporary directory and
only consumes its plan.json.  It never copies generated RTL into fpga_src:
the current generator emits a dedicated per-layer streaming accelerator,
which is useful for budgeting but is not the shared DDR tile engine used by
the board design.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
NNGEN = ROOT / "nngen"
DEFAULT_QUANT = ROOT / "st_work/fst/runs/ink_dw/quant/w8a8"
DEFAULT_CONFIG = NNGEN / "examples/st_stream/configs/ink_dw_480p10.json"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--quant", type=Path, default=DEFAULT_QUANT)
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--fps", type=float, default=10.0)
    ap.add_argument("--clock-mhz", type=float, default=100.0)
    ap.add_argument("--dsp", type=int, default=160)
    ap.add_argument("--ram-blocks", type=int, default=256)
    ap.add_argument("--ram-used", type=int, default=168,
                    help="RAM10 blocks retained after replacing st_accel/video pipe")
    ap.add_argument("--json", type=Path, help="also write the report here")
    args = ap.parse_args()

    quant = args.quant if args.quant.is_absolute() else ROOT / args.quant
    config = args.config if args.config.is_absolute() else ROOT / args.config
    if not (quant / "manifest.json").is_file():
        ap.error(f"manifest not found: {quant / 'manifest.json'}")
    if not config.is_file():
        ap.error(f"config not found: {config}")

    # Keep generated Verilog out of the board checkout.  The planner itself
    # is the artifact this check is intended to review.
    with tempfile.TemporaryDirectory(prefix="st480p10-") as td:
        out = Path(td) / "stream"
        cmd = [sys.executable, str(NNGEN / "examples/st_stream/gen_stream.py"),
               str(quant), "--res", f"{args.width}x{args.height}",
               "--cycles", str(max(1, int(args.clock_mhz * 1e6 / args.fps))),
               "--config", str(config), "--out", str(out)]
        proc = subprocess.run(cmd, cwd=NNGEN, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode:
            print(proc.stdout, file=sys.stderr)
            return proc.returncode
        plan = json.loads((out / "plan.json").read_text())

    target_cycles = max(1, int(args.clock_mhz * 1e6 / args.fps))
    cycles = int(plan.get("cycles_max", 0))
    dsp = int(plan.get("dsp48_mac", 0)) + int(plan.get("rq_lanes", 0))
    mem = plan.get("mem_bytes", {})
    mem_total = int(sum(float(v) for v in mem.values()))
    ram_est = (mem_total + 10239) // 10240
    free_ram = max(0, args.ram_blocks - args.ram_used)
    report = {
        "model": str(quant),
        "resolution": [args.width, args.height],
        "fps_target": args.fps,
        "clock_mhz": args.clock_mhz,
        "target_cycles": target_cycles,
        "layers": len(plan.get("layers", [])),
        "cycles_max": cycles,
        "estimated_fps": args.clock_mhz * 1e6 / cycles if cycles else 0.0,
        "bottleneck": plan.get("bottleneck"),
        "dsp48_estimate": dsp,
        "dsp_budget": args.dsp,
        "memory_bytes": mem,
        "memory_total_bytes": mem_total,
        "ram10_estimate": ram_est,
        "ram10_budget": args.ram_blocks,
        "ram10_free_in_fpga_src": free_ram,
        "dedicated_stream_rtl": True,
        "board_integration_allowed": False,
        "reason": "Use a shared DDR tile engine for fpga_src; this plan is budgeting only.",
        "layer_plan": [
            {k: layer[k] for k in ("name", "kind", "C", "OC", "simd", "pe", "tp", "cycles")
             if k in layer}
            for layer in plan.get("layers", [])
        ],
    }
    print(json.dumps(report, indent=2))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2) + "\n")

    ok = cycles <= target_cycles and dsp <= args.dsp and ram_est <= free_ram
    if not ok:
        print("PREFLIGHT: BLOCKED (dedicated stream plan exceeds the board budget)", file=sys.stderr)
        return 2
    print("PREFLIGHT: budget check passed; shared-tile integration is still required")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
