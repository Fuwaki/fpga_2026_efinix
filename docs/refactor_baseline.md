# 视频重构基线

| 项 | 值 |
|---|---|
| 分支起点 | `57a39b92fe64cb1d12be74043dd3e53ffb9e5ca6` |
| 重构分支 | `refactor/video-rgb-ddr-720p` |
| 重构前参照 | `ac6b658`（720p binning，旧通路，画面正常） |

重构前通路：CSI RAW8 → DDR 帧缓冲（`frame_buffer_V3`）→ 显示域 debayer / gamma / 饱和度 → HDMI。
重构后通路：CSI → ISP → RGB565 帧环 → 处理单元 → 合成器 → HDMI，见 `video_architecture.md`。

| 阶段 | 提交 | 板上结论 |
|---|---|---|
| Phase 1 契约库 + DMA | `5bce523` | DMA 自检 0 错；发现控制器只能 1 个读未完成 |
| Phase 2a 新显示路径 | `946563f` | 图样帧 60 fps；发现写需同样限制 |
| Phase 2b ISP 前置 | `c0b16f8` | 采集固定图签名与模型一致；摄像头画面颜色正确 |
| Phase 3 处理 + 分屏 | `207aa51` | 满负载 0 错 0 丢；左原图右反色，画面稳定 |
| Phase 4 退役旧通路 | 本提交 | 旧帧缓冲、显示域 ISP、`axi2_pri_arb` 删除；XLR 29.5k → 28.6k |

逐步排查记录：`720p_binning_black_screen_issue.md`。
