# SC431HAI 720p binning

1280×720 2×2 binning，4-lane。寄存器表与每条改动的理由见
`embedded_sw/riscv_soc0/software/standalone/camera/cameraI2c/src/sc431hai_regs.h` 表头，
排查过程见 `docs/720p_binning_black_screen_issue.md`。

`0x3221` 只是镜像（`[2:1]`）/倒置（`[6:5]`），不是 binning 开关。
binning 由厂商表中的 `0x3215=0x31`（行）与 `0x5000/0x5900/0x5901`（数字水平合并）完成，
且必须与厂商表的整套 PLL / 模拟时序 / HTS 一起使用。

改表后 `tools/build_all.sh`。
