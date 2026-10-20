#!/usr/bin/env bash
# Offline quality gate for the tiled style-transfer video path.
# No hardware programming is performed.  Efinity compile is opt-in with
# --synth (or QUALITY_GATE_EFINITY=1) because it is comparatively slow.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOG_DIR="${QUALITY_GATE_LOG_DIR:-/tmp/fpga-quality-gate}"
mkdir -p "$LOG_DIR"
trap 'rm -f "$ROOT/ram_init_file.mem"' EXIT

usage() { sed -n '2,8p' "$0"; }
stage_manifest() { python3 tools/verify_generated_consistency.py; }
stage_geometry() {
  python3 tools/verify_st_tile_geometry.py --width 1920 --height 1080
}
stage_rtl() {
  iverilog -g2012 -DST_PIPE_ASSERT -s st_vid_pipe -o "$LOG_DIR/st_vid_pipe_compile" \
    rtl/st_accel/st_vid_pipe.v rtl/debayer/true_dual_port_ram.v
  echo "PASS RTL compile"
}
stage_lint() {
  verilator --lint-only --Wno-fatal --top-module st_vid_pipe \
    rtl/st_accel/st_vid_pipe.v rtl/debayer/true_dual_port_ram.v >"$LOG_DIR/verilator_vid.log" 2>&1
  verilator --lint-only --Wno-fatal --top-module st_axi_mm rtl/st_accel/st_axi_mm.v \
    >"$LOG_DIR/verilator_axi.log" 2>&1
  echo "PASS Verilator lint (logs: $LOG_DIR)"
}
stage_sim() {
  iverilog -g2012 -DST_PIPE_ASSERT -s tb_st_vid_pipe -o "$LOG_DIR/st_vid_pipe_tb" \
    rtl/st_accel/tb_st_vid_pipe.sv rtl/st_accel/st_vid_pipe.v \
    rtl/debayer/true_dual_port_ram.v
  vvp "$LOG_DIR/st_vid_pipe_tb" | tee "$LOG_DIR/simulation.log"
}
stage_formal() {
  : > ram_init_file.mem
  yosys -q -p 'read_verilog -formal rtl/debayer/true_dual_port_ram.v rtl/st_accel/st_vid_pipe.v; prep -top st_vid_pipe -flatten; check' \
    >"$LOG_DIR/yosys_check.log" 2>&1
  echo "PASS Yosys structural/formal read (log: $LOG_DIR/yosys_check.log)"
}
stage_vid() {
  make -C sim all >"$LOG_DIR/vid_sim.log" 2>&1 || { tail -30 "$LOG_DIR/vid_sim.log"; exit 1; }
  grep -E "^(PASS|tb_.* PASS)" "$LOG_DIR/vid_sim.log"
  echo "PASS video subsystem lint + simulations (log: $LOG_DIR/vid_sim.log)"
}
stage_synth() {
  tools/build_all.sh --fpga-only | tee "$LOG_DIR/efinity.log"
  echo "PASS Efinity compile (log: $LOG_DIR/efinity.log)"
}

target="${1:-all}"
case "$target" in
  --help|-h) usage; exit 0 ;;
  manifest) stage_manifest ;;
  geometry) stage_geometry ;;
  rtl) stage_manifest; stage_geometry; stage_rtl; stage_lint ;;
  sim) stage_sim ;;
  vid) stage_vid ;;
  formal) stage_formal ;;
  synth) stage_manifest; stage_geometry; stage_rtl; stage_lint; stage_synth ;;
  all)
    stage_manifest
    stage_geometry
    stage_rtl
    stage_lint
    stage_sim
    stage_formal
    stage_vid
    if [[ "${QUALITY_GATE_EFINITY:-0}" == 1 ]]; then stage_synth; fi
    echo "QUALITY GATE: PASS"
    ;;
  *) echo "unknown quality-gate stage: $target" >&2; usage >&2; exit 2 ;;
esac
