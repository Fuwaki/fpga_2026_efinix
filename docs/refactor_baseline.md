# 视频重构基线（可出图版本）

| 项 | 值 |
|---|---|
| 分支起点 | `57a39b92fe64cb1d12be74043dd3e53ffb9e5ca6` |
| 重构分支 | `refactor/video-rgb-ddr-720p` |
| 可用 bitstream | `outflow/fpga_src.bit`（2026-10-19） |

重构前通路：CSI RAW → DDR → debayer@显示域 → gamma/sat → st_vid_pipe → HDMI。

详见 `video_architecture.md`。
