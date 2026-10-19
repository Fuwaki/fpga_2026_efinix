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
#   tools/build_all.sh --no-ip      # 只重编固件+FPGA (没改 SoC 配置时更快)
#   tools/build_all.sh --fpga-only  # 只重跑 FPGA 流程 (改 RTL 时最快)
#   tools/build_all.sh --fpga-only --program  # 编译后通过 JTAG 临时下载
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
SOC_V="$ROOT/ip/$SOC_GEN_NAME/riscv_soc0.v"
BSP_LD="$ROOT/embedded_sw/riscv_soc0/bsp/efinix/EfxSapphireSoc/linker/default.ld"
BSP_SOC_H="$ROOT/embedded_sw/riscv_soc0/bsp/efinix/EfxSapphireSoc/include/soc.h"

# SoC 配置 (与 ip/riscv_soc0 当前设置保持一致；改这里必须重跑 IP 生成)
SOC_PARAMS=(
  "SOC_MODE=0"            # Standard
  "Frequency=100"
  "DDR=1'b0"              # 不用外部 DDR，代码/数据全在片上 RAM
  "OCRSize=65536"         # 64KB 片上 RAM
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

for a in "$@"; do
  case "$a" in
    --fpga-only|--rtl-only) DO_FW=0; DO_IP=0 ;;
    --no-ip)     DO_IP=0 ;;
    --no-fpga)   DO_FPGA=0 ;;
    --program)   DO_PROGRAM=1 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

if [ "$DO_PROGRAM" = 1 ] && [ "$DO_FPGA" != 1 ]; then
  echo "--program 需要本次执行 FPGA 编译；请勿隐式下载可能过期的 bitstream" >&2
  exit 2
fi

# ---------------------------------------------------------------- 1) 固件
if [ "$DO_FW" = 1 ]; then
  echo "=== [1/3] 编译 RISC-V 固件 ==="
  command -v riscv-none-elf-gcc >/dev/null 2>&1 || export PATH="$RISCV_TOOLCHAIN:$PATH"
  command -v riscv-none-elf-gcc >/dev/null 2>&1 || {
    echo "找不到 riscv-none-elf-gcc，请检查 RISCV_TOOLCHAIN=$RISCV_TOOLCHAIN" >&2; exit 1; }
  make -C "$FW_DIR" BSP="$BSP"
  cp "$FW_DIR/build/camera_i2c.hex" "$FW_HEX_STABLE"
  # The vendor devkit BSP uses a bootloader map (0x1000/124K).  This design runs
  # the application directly from on-chip RAM at 0xF9000000/64K; catch the wrong
  # BSP before it gets linked into the bitstream.
  grep -q 'ORIGIN = 0xF9000000' "$BSP_LD" || {
    echo "BSP linker is not the 0xF9000000 application map: $BSP_LD" >&2; exit 1; }
  grep -q 'SYSTEM_RAM_A_SIZE 65536' "$BSP_SOC_H" || {
    echo "BSP soc.h does not describe 64 KiB on-chip RAM: $BSP_SOC_H" >&2; exit 1; }
  echo "固件 hex -> $FW_HEX_STABLE"
fi

# ------------------------------------------------------- 2) 重新生成 SoC IP
if [ "$DO_IP" = 1 ]; then
  echo "=== [2/3] 重新生成 SoC IP (嵌入固件) ==="
  PARAM_ARGS=()
  for p in "${SOC_PARAMS[@]}"; do PARAM_ARGS+=(--param "$p"); done
  PARAM_ARGS+=(--param "HexFile_PathEnable=1'b1")
  PARAM_ARGS+=(--param "HexFile_Path=\"$ROOT/$FW_HEX_STABLE\"")
  # Importing the existing settings.json keeps every parameter that is not
  # listed in SOC_PARAMS at its known-good value.  Without this, a direct
  # gen_ip.py run silently falls back to vendor defaults (4 KiB OCR, DDR AXI
  # and SPI0 enabled), which produced an unusable SoC during bring-up.
  if [ -f "$ROOT/ip/$SOC_GEN_NAME/settings.json" ]; then
    PARAM_ARGS+=(--settings-json "$ROOT/ip/$SOC_GEN_NAME/settings.json")
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
  grep -q 'ram_symbol0 \[0:16383\]' "$SOC_V" || {
    echo "SoC OCR is not 64 KiB (expected ram_symbol0 [0:16383]): $SOC_V" >&2; exit 1; }
  if grep -qE 'axiA_awready|io_memoryClk|system_spi_0_io_sclk_write' "$SOC_V"; then
    echo "SoC was generated with DDR/AXI/SPI enabled; top-level does not connect them: $SOC_V" >&2
    exit 1
  fi
fi

# ------------------------------------------------------------- 3) FPGA 流程
if [ "$DO_FPGA" = 1 ]; then
  echo "=== [3/3] 从 NNgen manifest 生成板级 ST 层描述 ==="
  python3 tools/generate_st_board_config.py \
    --profile config/st_board_ink_dw16.json \
    --sv rtl/st_accel/st_layer_sel_generated.v \
    --weights-hex rtl/st_accel/st_w8_sel_weights_generated.hex \
    --report docs/st_board_profile.json
  echo "=== [3/3] Efinity 综合/布局布线/生成 bitstream ==="
  rm -f outflow/fpga_src.proj_state.ini
  efx_run --prj fpga_src.xml -f compile --dir .
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
