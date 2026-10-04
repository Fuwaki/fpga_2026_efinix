##############################################################################
# camera_i2c - 由 RISC-V 完成的 SC431HAI 摄像头 I2C 初始化
#
# 构建 (需要 riscv 工具链在 PATH 中, 见 fpga_src/README.md):
#   cd embedded_sw/riscv_soc0/software/standalone/camera_i2c
#   make
#
# 产物: build/<PROJ_NAME>.elf / .hex / .bin
##############################################################################
PROJ_NAME=camera_i2c

STANDALONE = ../..

SRCS = 	$(wildcard src/*.c) \
		$(wildcard src/*.cpp) \
		$(wildcard src/*.S) \
		${STANDALONE}/common/start.S

include ${STANDALONE}/common/bsp.mk
include ${STANDALONE}/common/riscv64-unknown-elf.mk
include ${STANDALONE}/common/standalone.mk

LDSCRIPT = ${BSP_PATH}/linker/default.ld
