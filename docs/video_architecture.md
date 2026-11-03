# 视频架构（rtl/vid）

摄像头 1280×720（SC431HAI 2×2 binning，约 22 fps）→ ISP → DDR 帧环（RGB565）→ 处理单元 → 合成器 → HDMI 1080p60。
全部在 `vid_subsystem`（`rtl/vid/vid_subsystem.sv`）里，顶层只连扁平端口。

```
CSI pclk 50 MHz          core_clk 100 MHz                                          pixel clk 148.5 MHz
csi_capture ─ async FIFO ─ line_release ─ isp_top ─ push2stream ─ vdma_wr ─┐
                                                                           ├─ ISP 环 (4 槽) ──┬─ vdma_rd (层 0) ─┐
                            proc_engine: vdma_rd (NEW_ONLY) → proc_stub → vdma_wr ─ PROC 环 (3 槽) ─ vdma_rd (层 1) ─┤
vid_testgen ─ vdma_wr ─ 测试环 ─ vdma_rd ─ vid_testchk   (DMA 自检)                                                  │
                                         axi_arb ─ DDR3 控制器                       compositor ─ dvi_encoder ◄─────┘
```

## 1. 契约

| 契约 | 定义 | 规则 |
|---|---|---|
| `vpush_if #(T, PPC)` | `common/vpush_if.sv` | 固定延迟、无反压；sof = 帧首拍、eol = 行末拍；eol 后至少 MIN_GAP 拍空闲（`line_release` 保证，各级不缩短） |
| `vstream_if #(T, PPC)` | `common/vstream_if.sv` | valid/ready；valid 拉高后数据保持到成交（`sva/vstream_sva.sv` 检查）；同样的 sof/eol |
| 帧环 | `dma/ring_if.sv`、`dma/frame_ring_core.sv` | 生产者 ACQ → 写整帧 → COMMIT（最后一个 B 之后）或 ABORT；消费者 ACQ(REPEAT_OK / NEW_ONLY) → 读 → REL。槽数 ≥ 消费者数 + 2 时生产者永不缺槽 |
| AXI | `common/axi4_if.sv` | 每个主机一对 `axi4_wr_if/axi4_rd_if`，`axi_arb` 汇到控制器唯一端口（`sva/axi4_sva.sv`） |

像素类型在 `common/vid_pkg.sv`：`raw10_t`、`rgb10_t`、`rgb888_t`、`rgb565_t`（r[15:11] g[10:5] b[4:0]）。
一拍里 element 0 是最左边的像素。

## 2. 各级

| 模块 | 时钟 | 作用 |
|---|---|---|
| `isp/csi_capture` | pclk | 每拍 4 像素 RAW10，行末拍补 eol，帧首补 sof；FIFO 满时丢拍并计数。`CSI_PATTERN=1` 换成固定图（保留传感器时序） |
| `isp/line_release` | pclk → core | 双时钟 FIFO；一行的 eol 进 FIFO 后才整行连续放出（每拍 2 像素），行间强制间隙 |
| `isp/isp_top` | core | `isp_blc_wb` → `isp_demosaic`（双线性，输出第 k 行以输入第 k−1 行为中心，第 0 行黑）→ `isp_gamma`（三张 1024×10 表）→ `isp_sat`（1.5×）→ `isp_dither565`（2×2 有序抖动）；`isp_blc_wb` 的 R/G/B 增益（Q4.8，已含黑电平拉伸）每帧 sof 时从 `ui_regs` 锁存，乘法用 `mul_nodsp`（视频子系统保持 0 DSP）；`isp_stats` 统计原始四相位和、过曝数、帧计数；`isp_gray_stats` 在去马赛克之后统计接近灰色的像素的 R/G/B 和（给固件 AWB）。`bypass_all` 时原始值高 8 位作灰度直出 |
| `dma/vdma_wr` | core | 字在 FIFO 前打包成整拍，FIFO 里够一个突发才发 AW，W 每时钟一拍；逐拍核对 sof/eol，短帧/长帧/错位帧 ABORT；帧签名 `sig = rotl(sig,1) ^ word` |
| `dma/vdma_rd` | core（输出可异步） | 按行按裁切窗口发读突发，按 FIFO 余量计信用，R 每时钟一拍进 FIFO，FIFO 后拆字；最后一拍收到后释放帧 |
| `proc/proc_engine` | core | 以 NEW_ONLY 读 ISP 环每个新帧 → `proc_stub`（PASS / INVERT / SOBEL）→ 写 PROC 环，结果帧带源帧 `src_seq` |
| `disp/compositor` | pixel | `raster_gen` 出 1080p60；两层共用居中的 1280×720 窗口，`COMP_SINGLE` 或 `COMP_SPLIT`（分屏列任意）；每层 `layer_unpack` 按 sof/eol 逐行对齐，欠载只黑当行 |
| `dma/axi_arb` | core | 读写独立仲裁，低编号优先 + 饿死超时；按发出顺序路由响应，下游 ID 恒 0 |

仲裁优先级（低编号先）：写 0 外部（ST）、1 ISP、2 处理、3 自检；读 0 外部、1 显示层 0、2 显示层 1、3 处理、4 自检。

ISP 的全部算术以 `sim/ref/isp_ref.py` 为规格，RTL 与之逐位一致（`make -C sim tb_isp*`）。
DSP 全部留给神经网络：子系统里所有乘法经 `common/mul_nodsp.sv`（常数乘化为加法），`build_all.sh` 检查 u_vid 的 DSP = 0。

## 3. DDR

| 区域 | 基址 | 内容 |
|---|---|---|
| ISP 环 | `0x0400_0000` | 4 槽 × 4 MiB |
| PROC 环 | `0x0600_0000` | 3 槽 × 4 MiB |
| 测试环 | `0x0700_0000` | 3 槽 × 4 MiB |
| 0 .. 64 MiB | — | 空，留给外部主机 |

像素 (x, y) 地址 = 槽基址 + y × 4096 + x × 2。一行 2560 B 不跨 4 KiB 页。

**控制器限制**（板上实测，仿真模型不复现）：同时 >1 个读未完成会返回错数据；已排队的写先于读服务。
因此 `DDR_MAX_RD = DDR_MAX_WR = 1`。满负载（摄像头写 + 两层显示读 + 处理读写 + 自检）下读延迟峰值约 240 时钟、写约 290 时钟，
显示仍 60 帧/秒无欠载。

## 4. 顶层开关（`rtl/fpga_src_top.v`）

| 开关 | 默认 | 作用 |
|---|---|---|
| `VID_SPLIT` / `VID_SPLIT_COL` | 1 / 640 | 1 = 左摄像头、右处理结果；0 = 只显示摄像头（处理单元不综合） |
| `VID_PROC_MODE` | `PROC_SOBEL` | 右半显示什么：`PROC_SOBEL` 边缘（亮度 (R+2G+B)/4 的 3×3 Sobel，(|gx|+|gy|)/2）、`PROC_INVERT`、`PROC_PASS` |
| `CSI_PATTERN` | 0 | 1 = 采集侧固定图；遥测页 1 的帧签名应为 `0xa4f003e6`（`isp_ref.py pattern-sig`），证明 CSI→ISP→DDR 逐位正确 |
| `TP_EN` | 0 | 1 = HDMI 本地彩条，与视频通路无关 |
| `ENABLE_ST_ACCEL` | 0 | ST 加速器，打开时它的 AXI 主机接 `vid_subsystem` 外部端口 |

ISP 参数是 `vid_subsystem` 的 `ISP_CFG`（`vid_pkg::isp_cfg_t`，默认 `ISP_CFG_DEFAULT`）。黑电平、gamma、饱和度等仍是编译期常量；
R/G/B 增益从 0f2a1b7 起是运行时输入 `isp_gain`（`vid_pkg::isp_gain_t`），由 `ui_regs` 驱动，复位值等于 `isp_gain_of(ISP_CFG_DEFAULT)`（R 273、G 141、B 273）。

`ui_regs`（APB，0x8000–0x803F，和 ISP 同在 sys_clk，不需要跨时钟）：

| 地址 | 内容 |
|---|---|
| 0x8000 | CTRL：bit 0 OSD 开关，bits [2:1] OSD 显示的白平衡状态（0 AUTO、1 CAL、2 LOCK，固件写） |
| 0x8004 | MENU（bits[4:3] 风格） |
| 0x8008 | GAIN_RG：[11:0] R，[27:16] G（Q4.8） |
| 0x800C | GAIN_B：[11:0] B |
| 0x8010–0x801C | 原始统计：四个 CFA 相位的和（相位 R = 2、B = 1、G = 0/3） |
| 0x8020 | 过曝（削顶）计数 |
| 0x8024 | KEY1：bit 0 = KEY1 按下（消抖后），白纸标定键 |
| 0x8028 | FRAMES[7:0]，每锁存一次统计加 1 |
| 0x802C–0x8034 | 灰像素 R、G、B 和（每个分量 >>2 后累加） |

**固件 AWB/AE**（`embedded_sw/.../cameraI2c/src/isp_ctrl.c`，主循环轮询按键时顺带调用，每个新统计帧跑一次）：

- AE 只调传感器曝光（0x3E00–0x3E02）：原始 G 均值目标是 2·T，±25% 死区；10 ms 以上取 10 ms 的整数倍（防工频闪烁），最长 40 ms；改一次等 3 帧。
- 亮度：G 增益 = 150·256 / G 均值。
- 白平衡：光源估计 `rg_q8`、`bg_q8` 限制在 R/G 115–205、B/G 90–166 内；灰像素足够多（G 和 ≥ 2000·32）时，用灰像素的 R/G、B/G 残差更新。R/B 增益 = G 增益·256 / 估计值。所有更新每次只走目标的 1/4。
- 灰像素：去马赛克后的偶数列，G ≥ 64，R/G/B < 1000，|R−G| 和 |B−G| < 3/16·G。
- 白纸标定（a8ff3b2）：KEY1 短按时取 4 帧整帧原始统计（过曝超过 2% 的帧不用），减黑电平后的 R/G、B/G 直接作为光源估计并锁定，不再用灰像素更新；长按约 1 秒回到自动。锁定时 AE 和亮度照常。
  KEY1 原来是 PLL/CSI 的异步复位，现在不再复位任何东西。
  OSD 第 4 行显示状态（a83d75c）：`WB AUTO`、`WB CAL`（采样中）、`WB LOCK`。
- 固件总共约 7.2 KB（text 4,104 + data 1,018 + bss 2,100），OCR 16 KB 不用改。

## 5. 接入一个加速器

按 `proc/proc_engine.sv` 的样子：从 ISP 环以 NEW_ONLY 取帧（`vdma_rd`）→ 加速器（`vstream_if` 进出）→ `vdma_wr` 写自己的帧环，
透传 `src_seq`。在 `vid_subsystem` 里给它一对仲裁器端口和一个帧环，合成器把那个环作为一层显示即可。
加速器不是逐像素流（比如按 tile 访问 DDR）时，用外部端口 `ext_*` 直接做 AXI 主机。

## 6. 验证与遥测

- `make -C sim`：lint + 单元/集成仿真（FIFO、帧环对照参考模型、DMA、子系统自检、显示逐像素、分屏、ISP 逐位），SVA 全开；
  `tools/quality_gate.sh` 包含它。
- `python3 tools/board_smoke_test.py --vid`：遥测每 0.5 s 一帧，按 seq 低 2 位轮换四页——0 显示、1 摄像头路径（含帧签名）、
  2 原始统计（含 CSI 错误位）、3 自检与处理单元。`ok` 要求时钟/复位/1080p60 正常且所有帧环无协议错误。

## 7. 资源

最终版（91514ca，带 ST 加速器）：u_vid 7,381 XLR、31 RAM10、0 DSP，其中 ISP 2,996 XLR（灰像素统计 397）。全片见 docs/st-resource-report.md。

Phase 4 完成时（还没有加速器）：

全片 XLR 29.1k / 60.8k、Memory 196 / 256、DSP 4（只有 SoC）。u_vid：10.6k XLR、63 块 Memory、0 DSP
（Sobel 的两行亮度缓冲 4 块）。
Memory 大头：SoC 81、DDR 控制器 39、CSI RX 11；u_vid 中每个 DMA 引擎 7 块（130 位宽 FIFO），ISP 7 块。
关掉 DMA 自检（`ENABLE_SELFTEST=0`）省 14 块。

## 8. 已知限制

- 帧率约 22 fps；30 fps 需 VTS ≈ 2048 并相应缩短曝光。
- AE/AWB 已由固件实现（第 4 节），但白平衡在部分场景下仍容易偏绿：灰像素 3/16 的容差偏宽、Bayer 上 G 占一半采样，也没有色彩校正矩阵（CCM）。暂时没继续调。演示时用 KEY1 对白纸标定并锁定，可以避开这个问题。
- 原始统计不再统计近黑像素数（为省 XLR 去掉了），DARK 寄存器读 0。
- 去马赛克是双线性，细节处有轻微彩色噪点。
- RGB565 量化靠 2×2 抖动掩盖，暗部渐变仍可能看到细纹。
- Sobel 输出相对原图右移 2 像素、下移 1 行（每个输出拍随输入拍产生，弹性流里不需要单独补发）。
