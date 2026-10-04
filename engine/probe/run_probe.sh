#!/bin/sh
# E5c/E5d probe driver: minimal standalone shapes, both families, map only.
# Purpose: decide where the engine's multipliers actually land (hard DSP or logic).
W=${1:-/tmp/e5c_probe}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W"
for fam in Titanium:Ti60F225 Trion:T20F256; do
  f=${fam%%:*}; dev=${fam##*:}
  echo "================ $f / $dev ================"
  for src in "$HERE"/*.sv; do
    n=$(basename "$src" .sv)
    # async_read_ram_big.sv (1 Mbit, async read) did not finish in 15 min on
    # Ti60F225 - it is kept for reference but skipped here on purpose.
    case "$n" in async_read_ram_big) continue ;; esac
    d="$W/${f}_$n"
    rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 2
    /usr/bin/efx_map --project "$n" --family "$f" --device "$dev" \
        --output-dir outflow --work-dir work_syn --v "$src" > map.stdout 2>&1
    rc=$?
    dsp=$(grep -m1 -c 'EFX_DSP24' "outflow/$n.map.rpt" 2>/dev/null)
    echo "--- $n exit=$rc"
    sed -n '/Resource Summary (begin)/,/Resource Summary (end)/p' "outflow/$n.map.rpt" 2>/dev/null | grep -E 'EFX_|INPUT|OUTPUT'
  done
done
echo done
