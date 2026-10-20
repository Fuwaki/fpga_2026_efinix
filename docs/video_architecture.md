# 视频架构

CSI (720p binning) → `isp_top` → RGBx32 → DDR → `video_compositor` → `display_tone` → HDMI.

- 存储：1280×720×4 字节/像素，`FB_NUM=3`，`DDR_CAM0_BASE=0`。
- 显示：1080p60 时序，720p 内容居中留黑。
- NN：`ENABLE_ST_ACCEL=0`。
- 传感器表：`embedded_sw/.../sc431hai_regs.h`。
