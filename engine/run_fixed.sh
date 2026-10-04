#!/bin/sh
# E5c re-run on the FIXED conv_stream (whole-word weight write, src/conv_stream.veryl).
#
#   sh run_fixed.sh [family] [device] [timing_model] [tag]
#   sh run_fixed.sh Titanium Ti60F225 I3  ti60
#   sh run_fixed.sh Trion    T20F256  I3  trion
#
# Two things this script does differently from run.sh, both deliberate:
#   1. it snapshots the generated SV into ./sv_fixed and records sv_fixed/SHA256SUMS,
#      so the numbers are tied to an exact netlist instead of to whatever
#      ../../fpga_rtl_lab/target happens to hold later;
#   2. it pins the top level with --root, because efx_run --flist does NOT pin it
#      (with several uninstantiated modules it silently picks one of them and still
#      exits 0 - see README section 6 item 1).
set -x
FAM=${1:-Titanium}; DEV=${2:-Ti60F225}; TM=${3:-I3}; TAG=${4:-ti60}
cd "$(dirname "$0")" || exit 2
mkdir -p sv_fixed
for f in requant_unit sat_add conv_engine conv_stream tile_reader layer_desc layer_seq point_add engine_top; do
    cp -f ../../fpga_rtl_lab/target/$f.sv sv_fixed/$f.sv || exit 2
done
( cd sv_fixed && sha256sum *.sv > SHA256SUMS )
rm -rf out_$TAG work_$TAG; mkdir -p out_$TAG
/usr/bin/efx_map --project engine_top --family $FAM --device $DEV --root engine_top \
    --output-dir out_$TAG --work-dir work_$TAG \
    --v sv_fixed/requant_unit.sv --v sv_fixed/sat_add.sv --v sv_fixed/conv_engine.sv \
    --v sv_fixed/conv_stream.sv --v sv_fixed/tile_reader.sv --v sv_fixed/layer_desc.sv \
    --v sv_fixed/layer_seq.sv --v sv_fixed/point_add.sv --v sv_fixed/engine_top.sv \
    > map_$TAG.log 2>&1
echo "map exit=$? root=$(grep -m1 'Top-level Entity Name' out_$TAG/engine_top.map.rpt 2>/dev/null)"
/usr/bin/efx_run engine_top --family $FAM --device $DEV --timing_model $TM -f pnr \
    --flist synth_fixed.f --output_dir out_$TAG --work_dir work_$TAG > pnr_$TAG.log 2>&1
echo "pnr exit=$?"
echo '--- resources ---'; sed -n '/Resource Summary (begin)/,/Resource Summary (end)/p' out_$TAG/engine_top.map.rpt 2>/dev/null | grep -E 'EFX_|PORTS'
echo '--- fmax ---'; sed -n '/Maximum possible analyzed clocks frequency/,/Geomean/p' out_$TAG/engine_top.timing.rpt 2>/dev/null | head -5
