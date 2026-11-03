#!/usr/bin/env bash
# =============================================================================
# build_all.sh - fpga_src 一键构建
#
#   1) 编译 RISC-V 固件 (cameraI2c: SC431HAI 摄像头 I2C 初始化)
#   2) 把固件 hex 嵌进 SoC IP 的片上 RAM 初始化 (重新生成 ip/riscv_soc0)
#   3) 跑完整 FPGA 流程 efx_run -f compile -> outflow/fpga_src.bit|.hex
#
# 用法:
#   tools/build_all.sh              # 全流程
#   (没有 --no-ip: 固件只能通过重新生成 SoC IP 进 bitstream, 见下面的检查)
#   tools/build_all.sh --fpga-only  # 只重跑 FPGA 流程 (改 RTL 时最快)
#   tools/build_all.sh --fpga-only --program  # 编译后通过 JTAG 临时下载
#   tools/build_all.sh --no-fpga --flash      # 把现有 outflow/fpga_src.hex 写入 SPI Flash
#
# 环境:
#   RISCV_TOOLCHAIN  工具链 bin 目录，默认 /opt/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin
#   EFINITY_HOME     默认 /opt/efinity/2026.1 (由 /usr/bin/efx_run 包装脚本自动处理)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RISCV_TOOLCHAIN="${RISCV_TOOLCHAIN:-/opt/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin}"
FW_DIR="embedded_sw/riscv_soc0/software/standalone/camera/cameraI2c"
FW_HEX_STABLE="embedded_sw/riscv_soc0/camera_i2c.hex"
BSP="efinix/EfxSapphireSoc"
SOC_VLNV="soc/efx_soc:3.4.0"
SOC_GEN_NAME="riscv_soc0"
SOC_SETTINGS="$ROOT/config/riscv_soc0_settings.json"
SOC_V="$ROOT/ip/$SOC_GEN_NAME/riscv_soc0.v"
BSP_LD="$ROOT/embedded_sw/riscv_soc0/bsp/efinix/EfxSapphireSoc/linker/default.ld"
BSP_SOC_H="$ROOT/embedded_sw/riscv_soc0/bsp/efinix/EfxSapphireSoc/include/soc.h"

# SoC 配置 (与 ip/riscv_soc0 当前设置保持一致；改这里必须重跑 IP 生成)
SOC_PARAMS=(
  "SOC_MODE=0"            # Standard
  "Frequency=125"         # sys_clk (i_mipi_tx_pclk)
  "DDR=1'b0"              # 不用外部 DDR，代码/数据全在片上 RAM
  "OCRSize=16384"         # 16KB 片上 RAM
  "Cache=1'b0"            # 代码在片上 RAM，缓存不省访问
  "ICache_EN=1'b0"
  "DCache_EN=1'b0"
  "I2C0=1'b1"             # 摄像头配置
  "UART0=1'b1"            # 预留（本设计未引出引脚）
  "GPIO0=1'b1"            # 预留按键 + 状态灯
  "SPI0=1'b0" "SPI1=1'b0" "SPI2=1'b0"
  "AXISlave=1'b0"         # 不接 AXI master
  "DEBUG=1'b0"            # 不带 JTAG 调试核
)

DO_FW=1
DO_IP=1
DO_FPGA=1
DO_PROGRAM=0
DO_FLASH=0

for a in "$@"; do
  case "$a" in
    --fpga-only|--rtl-only) DO_FW=0; DO_IP=0 ;;
    --no-ip)
      # The firmware reaches the bitstream only as the SoC IP's RAM init
      # (ip/riscv_soc0/*ram_symbol*.bin, written by gen_ip.py).  Rebuilding the
      # firmware without regenerating the IP silently ships the old firmware;
      # three board builds on 2026-11-03 did exactly that.
      echo "--no-ip 已取消：改了固件必须跑全流程 tools/build_all.sh；只改 RTL 用 --fpga-only" >&2
      exit 2 ;;
    --no-fpga)   DO_FPGA=0 ;;
    --program)   DO_PROGRAM=1 ;;
    --flash)     DO_FLASH=1; DO_FW=0; DO_IP=0 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

if [ "$DO_PROGRAM" = 1 ] && [ "$DO_FPGA" != 1 ]; then
  echo "--program 需要本次执行 FPGA 编译；请勿隐式下载可能过期的 bitstream" >&2
  exit 2
fi

if [ "$DO_IP" = 0 ] && [ "$DO_FPGA" = 1 ] && [ ! -f "$SOC_V" ]; then
  echo "缺少生成的 SoC IP: $SOC_V" >&2
  echo "先运行一次 tools/build_all.sh --no-fpga 生成 IP/固件" >&2
  exit 1
fi

# ---------------------------------------------------------------- 1) 固件
if [ "$DO_FW" = 1 ]; then
  echo "=== [1/3] 编译 RISC-V 固件 ==="
  command -v riscv-none-elf-gcc >/dev/null 2>&1 || export PATH="$RISCV_TOOLCHAIN:$PATH"
  command -v riscv-none-elf-gcc >/dev/null 2>&1 || {
    echo "找不到 riscv-none-elf-gcc，请检查 RISCV_TOOLCHAIN=$RISCV_TOOLCHAIN" >&2; exit 1; }
  make -B -C "$FW_DIR" BSP="$BSP"
  cp "$FW_DIR/build/camera_i2c.hex" "$FW_HEX_STABLE"
  # The firmware must be linked for the on-chip RAM base.  A stale build tree
  # from the vendor 0x1000 bootloader map makes SpinalHDL's HexTools assert
  # during IP generation, and embeds an image the CPU cannot boot.
  grep -q ':02000004F900' "$FW_HEX_STABLE" || {
    echo "firmware hex is not linked at 0xF9000000: $FW_HEX_STABLE" >&2; exit 1; }
  # The vendor devkit BSP uses a bootloader map (0x1000/124K).  This design runs
  # the application directly from on-chip RAM at 0xF9000000/16K; catch the wrong
  # BSP before it gets linked into the bitstream.
  grep -q 'ORIGIN = 0xF9000000' "$BSP_LD" || {
    echo "BSP linker is not the 0xF9000000 application map: $BSP_LD" >&2; exit 1; }
  grep -q 'LENGTH = 16K' "$BSP_LD" || {
    echo "BSP linker is not 16K: $BSP_LD" >&2; exit 1; }
  grep -q 'SYSTEM_RAM_A_SIZE 16384' "$BSP_SOC_H" || {
    echo "BSP soc.h does not describe 16 KiB on-chip RAM: $BSP_SOC_H" >&2; exit 1; }
  echo "固件 hex -> $FW_HEX_STABLE"
fi

# ------------------------------------------------------- 2) 重新生成 SoC IP
if [ "$DO_IP" = 1 ]; then
  echo "=== [2/3] 重新生成 SoC IP (嵌入固件) ==="
  PARAM_ARGS=()
  for p in "${SOC_PARAMS[@]}"; do PARAM_ARGS+=(--param "$p"); done
  PARAM_ARGS+=(--param "HexFile_PathEnable=1'b1")
  PARAM_ARGS+=(--param "HexFile_Path=\"$FW_HEX_STABLE\"")
  # Importing the existing settings.json keeps every parameter that is not
  # listed in SOC_PARAMS at its known-good value.  Without this, a direct
  # gen_ip.py run silently falls back to vendor defaults (4 KiB OCR, DDR AXI
  # and SPI0 enabled), which produced an unusable SoC during bring-up.
  if [ -f "$SOC_SETTINGS" ]; then
    PARAM_ARGS+=(--settings-json "$SOC_SETTINGS")
  fi
  # gen_ip.py imports Efinity's bundled PyQt6; the system Python does not.
  # setup.sh also supplies PYTHONHOME/PYTHONPATH for the private interpreter.
  EFINITY_HOME="${EFINITY_HOME:-/opt/efinity/2026.1}"
  # Keep Efinity's private Python environment confined to this process; the
  # system Python does not contain the IP Manager's bundled PyQt6.
  env EFINITY_HOME="$EFINITY_HOME" \
      PYTHONHOME="$EFINITY_HOME" \
      PYTHONPATH="$EFINITY_HOME/lib:" \
      EFINITY_USER_DIR_INI="${EFINITY_USER_DIR_INI:-$HOME/.local/share/efinity/user_dir.ini}" \
      "$EFINITY_HOME/bin/python3" tools/gen_ip.py \
      --vlnv "$SOC_VLNV" --gen-name "$SOC_GEN_NAME" "${PARAM_ARGS[@]}"
  # Fail closed if the IP Manager ignored the requested configuration.
  grep -q 'ram_symbol0 \[0:4095\]' "$SOC_V" || {
    echo "SoC OCR is not 16 KiB (expected ram_symbol0 [0:4095]): $SOC_V" >&2; exit 1; }
  grep -q 'SYSTEM_RAM_A_SIZE 16384' "$BSP_SOC_H" || {
    echo "BSP soc.h does not describe 16 KiB on-chip RAM after IP generation: $BSP_SOC_H" >&2; exit 1; }
  grep -q 'LENGTH = 16K' "$BSP_LD" || {
    echo "BSP linker is not 16K after IP generation: $BSP_LD" >&2; exit 1; }
  if grep -qE 'axiA_awready|io_memoryClk|system_spi_0_io_sclk_write' "$SOC_V"; then
    echo "SoC was generated with DDR/AXI/SPI enabled; top-level does not connect them: $SOC_V" >&2
    exit 1
  fi
  # IP Manager re-deploys the vendor BSP and the RAM hex with CRLF.  The
  # repository stores LF; normalize so a build does not dirty tracked files.
  find "$ROOT/embedded_sw/riscv_soc0" \
    \( -path '*/build' -o -path '*/obj_files' \) -prune -o \
    -name '*.bin' -prune -o \
    -type f -exec sed -i 's/\r$//' {} +
fi

# ------------------------------------------------------------- 3) FPGA 流程
if [ "$DO_FPGA" = 1 ]; then
  echo "=== [3/3] 从 NNgen manifest 生成板级 ST 层描述 ==="
  python3 tools/generate_st_board_config.py \
    --profile config/st_board_ink_dw16.json \
    --sv rtl/st_accel/st_layer_sel_generated.v \
    --weights-hex rtl/st_accel/st_w8_sel_weights_generated.hex \
    --report docs/st_board_profile.json
  python3 tools/generate_st_bias_requant.py \
    --meta config/weights/st_w8_sel_meta.json \
    --bias rtl/st_accel/st_w8_bias.hex \
    --requant rtl/st_accel/st_w8_requant.hex
  echo "=== [3/3] Efinity 综合/布局布线/生成 bitstream ==="
  rm -f outflow/fpga_src.proj_state.ini
  efx_run --prj fpga_src.xml -f compile --dir .
  # Fail closed on warnings that silently change the netlist.  Efinity reports
  # PASS while dropping a redeclared net, so a duplicate declaration reads as a
  # build success and the wrong logic ships.  VERI-2170 is that case; keep this
  # list short and grow it only for warnings with the same property.
  if grep -qE 'VERI-2170|VERI-1329' outflow/fpga_src.map.out; then
    echo "构建被拒绝：综合器丢弃了重复声明的对象，网表与源码不一致" >&2
    grep -E 'VERI-2170|VERI-1329' outflow/fpga_src.map.out >&2
    exit 1
  fi
  # DSP blocks are reserved for the NN accelerator: the video subsystem
  # (instance u_vid and below) must not use any.  hier_util lists each
  # instance with "dsp" as "total(self)".
  vid_dsp=$(awk -F'|' '$2 ~ /^ *\+u_vid / {gsub(/ /,"",$5); split($5,a,"("); print a[1]}' outflow/fpga_src.hier_util.rpt)
  if [ -n "$vid_dsp" ] && [ "$vid_dsp" != "0" ]; then
    echo "构建被拒绝：视频子系统 u_vid 用了 $vid_dsp 个 DSP（应为 0，DSP 留给 NN）" >&2
    exit 1
  fi
  echo
  echo "产物:"
  echo "  outflow/fpga_src.hex  (烧 SPI flash, 地址 0x000000)"
  echo "  outflow/fpga_src.bit  (JTAG 下载)"
fi

# ------------------------------------------------------------- 4) 可选 JTAG 下载
if [ "$DO_PROGRAM" = 1 ]; then
  [ -f outflow/fpga_src.bit ] || { echo "找不到 outflow/fpga_src.bit" >&2; exit 1; }
  echo "=== [4/4] 通过 JTAG 临时下载（不修改 SPI Flash） ==="
  efx_run --prj fpga_src.xml -f program --pgm_opts mode=jtag --dir .
fi

# ------------------------------------------------------------- 5) 可选写 Flash
# FT4232 的 SPI 通道接不到这块板的 Flash（mode=active 报 could not get flash
# device），所以走 JTAG Bridge：先经 JTAG 下载 Efinity 自带的 flash loader
# (pgm/fli/titanium/u<IDCODE>.bit)，再由它写 W25Q64 并回读校验。写完 FPGA 里
# 跑的是 loader，断电重上电（或按复位）后才从 Flash 启动新设计。
if [ "$DO_FLASH" = 1 ]; then
  [ -f outflow/fpga_src.hex ] || { echo "找不到 outflow/fpga_src.hex" >&2; exit 1; }
  FLI="${EFINITY_HOME:-/opt/efinity/2026.1}/pgm/fli/titanium/u10660A79.bit"
  [ -f "$FLI" ] || { echo "找不到 flash loader $FLI" >&2; exit 1; }
  echo "=== 写 SPI Flash: $(ls -l --time-style=+%F' '%T outflow/fpga_src.hex | awk '{print $6, $7}') 的 outflow/fpga_src.hex ==="
  efx_run --prj fpga_src.xml -f program --pgm_opts mode=jtag "source=$FLI" --dir .
  efx_run --prj fpga_src.xml -f program --pgm_opts mode=jtag_bridge --dir . | tee /tmp/fpga_flash.log
  grep -q "Flash verify successful" /tmp/fpga_flash.log || { echo "Flash 写入或校验失败" >&2; exit 1; }
  echo "Flash 已写入并校验；断电重上电后从 Flash 启动。"
fi
