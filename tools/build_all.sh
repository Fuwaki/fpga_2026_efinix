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

for a in "$@"; do
  case "$a" in
    --fpga-only) DO_FW=0; DO_IP=0 ;;
    --no-ip)     DO_IP=0 ;;
    --no-fpga)   DO_FPGA=0 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 1) 固件
if [ "$DO_FW" = 1 ]; then
  echo "=== [1/3] 编译 RISC-V 固件 ==="
  command -v riscv-none-elf-gcc >/dev/null 2>&1 || export PATH="$RISCV_TOOLCHAIN:$PATH"
  command -v riscv-none-elf-gcc >/dev/null 2>&1 || {
    echo "找不到 riscv-none-elf-gcc，请检查 RISCV_TOOLCHAIN=$RISCV_TOOLCHAIN" >&2; exit 1; }
  make -C "$FW_DIR" BSP="$BSP"
  cp "$FW_DIR/build/camera_i2c.hex" "$FW_HEX_STABLE"
  echo "固件 hex -> $FW_HEX_STABLE"
fi

# ------------------------------------------------------- 2) 重新生成 SoC IP
if [ "$DO_IP" = 1 ]; then
  echo "=== [2/3] 重新生成 SoC IP (嵌入固件) ==="
  PARAM_ARGS=()
  for p in "${SOC_PARAMS[@]}"; do PARAM_ARGS+=(--param "$p"); done
  PARAM_ARGS+=(--param "HexFile_PathEnable=1'b1")
  PARAM_ARGS+=(--param "HexFile_Path=\"$ROOT/$FW_HEX_STABLE\"")
  python3 tools/gen_ip.py --vlnv "$SOC_VLNV" --gen-name "$SOC_GEN_NAME" "${PARAM_ARGS[@]}"
fi

# ------------------------------------------------------------- 3) FPGA 流程
if [ "$DO_FPGA" = 1 ]; then
  echo "=== [3/3] Efinity 综合/布局布线/生成 bitstream ==="
  rm -f outflow/fpga_src.proj_state.ini
  efx_run --prj fpga_src.xml -f compile --dir .
  echo
  echo "产物:"
  echo "  outflow/fpga_src.hex  (烧 SPI flash, 地址 0x000000)"
  echo "  outflow/fpga_src.bit  (JTAG 下载)"
fi
