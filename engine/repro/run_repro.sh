#!/bin/sh
# E5c reproducer driver: runs every rb_*.sv through efx_map on both families.
# Expected outcome is in ../../docs/engine/e5_resources.md section 5.
# Usage: sh run_repro.sh [workdir]   (default /tmp/e5c_repro)
W=${1:-/tmp/e5c_repro}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W"
for fam in Titanium:Ti60F225 Trion:T20F256; do
  f=${fam%%:*}; dev=${fam##*:}
  echo "================ $f / $dev ================"
  for src in "$HERE"/*.sv; do
    n=$(basename "$src" .sv)
    d="$W/${f}_$n"
    rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 2
    /usr/bin/efx_map --project "$n" --family "$f" --device "$dev" \
        --output-dir outflow --work-dir work_syn --v "$src" > map.stdout 2>&1
    rc=$?
    printf '%-28s exit=%-3s  %s\n' "$n" "$rc" "$(grep -m1 -E 'ERROR|ASSERT INFO' map.stdout | cut -c1-70)"
  done
done
echo "done: logs under $W/<family>_<module>/map.stdout"
