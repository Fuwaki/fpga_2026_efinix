#!/usr/bin/env bash
# Synthesise the SV capability probe on its own (Efinity map only).
#   tools/sv_probe/run.sh      -> /tmp/sv_probe/{outflow,work}/
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${SV_PROBE_OUT:-/tmp/sv_probe}"
rm -rf "$OUT"; mkdir -p "$OUT"
cd "$ROOT"
sed "s|^|$ROOT/|" tools/sv_probe/files.f > "$OUT/files.f"
efx_run sv_probe_top --flow map --family Titanium --device Ti60F225 \
  --flist "$OUT/files.f" --output_dir "$OUT/outflow" --work_dir "$OUT/work" \
  --map_opts "veri_options=verilog_mode=sv_09" "root=sv_probe_top" > "$OUT/map.log" 2>&1 || {
    echo "map FAILED; see $OUT/map.log"; grep -E "ERROR" "$OUT"/outflow/*.map.out "$OUT/map.log" | head -20; exit 1; }
grep -hE "ERROR|VERI-2170|VERI-1329" "$OUT"/outflow/*.map.out && { echo "probe rejected"; exit 1; } || true
echo "map PASS"
grep -A12 "Resource Summary\|Mapping Summary" "$OUT"/outflow/*.map.rpt 2>/dev/null | head -30 || true
