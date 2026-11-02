#!/usr/bin/env bash
# Efinity map of one ST engine module on its own, with its resource tree.
#   tools/st_probe/run.sh [ROOT]     ROOT defaults to st_accel_wrapper (the
#                                    whole engine); st_pw, st_dw, ... work too
#   -> $ST_PROBE_OUT (default /tmp/st_probe_<ROOT>)/{outflow,work,map.log}
# The resource tree is the "Module Resource Usage Distribution" table of the
# map report: FFs, SRLs, ADDs, LUTs, COMB4s, RAMs (RAM10), DSP/MULTs; the
# number in parentheses is the module's own share.  DSP counts are before the
# placer pairs int8 products into DUAL blocks (see docs/st-accel-engine-adr.md).
# A module whose ports are unconnected here keeps its logic: the tool does not
# prune top-level ports, so the numbers are what the full build sees.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOP="${1:-st_accel_wrapper}"
OUT="${ST_PROBE_OUT:-/tmp/st_probe_$TOP}"
mkdir -p "$OUT"; rm -rf "$OUT/outflow" "$OUT/work"
cd "$ROOT"
sed "s|^|$ROOT/|" tools/st_probe/files.f > "$OUT/files.f"
efx_run "$TOP" --flow map --family Titanium --device Ti60F225 \
  --flist "$OUT/files.f" --output_dir "$OUT/outflow" --work_dir "$OUT/work" \
  --map_opts "veri_options=verilog_mode=sv_09" "root=$TOP" > "$OUT/map.log" 2>&1 || {
    echo "map FAILED; see $OUT/map.log"; grep -hE "ERROR" "$OUT"/outflow/*.map.out "$OUT"/outflow/*.err.log "$OUT/map.log" 2>/dev/null | head -20; exit 1; }
echo "map PASS ($TOP)"
sed -n '/Module Resource Usage Distribution Estimates (begin)/,/Module Resource Usage Distribution Estimates (end)/p' \
  "$OUT/outflow/$TOP.map.rpt" | sed -n '5,$p' | grep -v "Distribution Estimates (end)" | cut -c1-150 | head -${ST_PROBE_LINES:-60}
