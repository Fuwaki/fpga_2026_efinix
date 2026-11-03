# 硬件资源使用报告

2026-11-03，feat/st-fmax（91514ca 的数据；最终写入 Flash 的是 a8ff3b2，它把 KEY1 改成白纸标定白平衡键，XLR 60,525（99.55%，+183），sys_clk fmax 134.5 MHz，RAM/DSP 不变，下面各表仍是 91514ca 的逐模块数据）：最终版 3 风格网络 `s3d`（bright、gouache、comic，带 packet_guide，训练端修正了偏黄），用户逻辑跑在 125 MHz。
这一版 ISP 的白平衡和曝光改成固件闭环控制（ISP 增益运行时可写，新增灰像素统计），见 docs/video_architecture.md。

- **器件**：Efinix Titanium Ti60F225，速度等级 I3，Efinity 2026.1。
- **数据来源**：一次完整编译的 `outflow/fpga_src.place.rpt`（总量）、`fpga_src.hier_util.rpt`（按模块）和 `fpga_src.timing.rpt`（时序）。重新编译后可以按文末的命令重新取数。
- 和之前几版（feat/st-guided 374d536 双风格 100 MHz；feat/st-fmax dad8cb8 final_s3b、固定白平衡）的差别见第 7 节。

## 1. 总量

| 资源 | 已用 | 总量 | 占比 | 剩余 |
|---|---|---|---|---|
| XLR（逻辑单元） | 60,342 | 60,800 | 99.25% | 458 |
| RAM10（10 Kbit 块 RAM，含 3 个 DPRAM10） | 256 | 256 | 100% | 0 |
| DSP 块 | 159 | 160 | 99.4% | 1 |
| 全局时钟 GBUF | 16 | 32 | 50% | 16 |
| 区域时钟 RBUF | 1 | 32 | 3% | 31 |
| 输入 / 输出 | 121 / 343 | 1,703 / 2,267 | 7% / 15% | – |

XLR 按用途拆分（每个 XLR 只计一种用途）：

| 用途 | XLR |
|---|---|
| LUT4 | 23,213 |
| LUT4 + FF | 9,782 |
| 加法器 | 7,321 |
| 加法器 + FF | 2,317 |
| SRL8（移位寄存器） | 2,643（SRL8 上限 14,720） |
| 仅 FF | 15,066 |

三种主要资源都已用满或接近用满。RAM 一块不剩，再加任何占 RAM 的东西都要先腾出空间（第 8 节）。

## 2. 按子系统

| 子系统 | 顶层实例 | XLR | 占比 | RAM10 | DSP |
|---|---|---|---|---|---|
| 风格迁移加速器 | `gen_st_accel.u_st_accel_wrapper` | 34,774 | 57.6% | 152 | 155 |
| 视频子系统（采集、ISP、帧环、合成） | `u_vid` | 7,381 | 12.2% | 31 | 0 |
| DDR3 控制器（厂商 IP） | `u_ddr3_top` | 6,223 | 10.3% | 39 | 0 |
| RISC-V SoC（Sapphire） | `u_riscv_soc0` | 4,875 | 8.1% | 21 | 4 |
| MIPI CSI-2 接收（厂商 IP） | `inst_efx_csi2_rx` | 3,253 | 5.4% | 11 | 0 |
| HDMI/DVI 发送 | `dvi_encoder_m0` | 1,437 | 2.4% | 2 | 0 |
| 顶层胶合逻辑 | `fpga_src` 本层 | 2,222 | 3.7% | 0 | 0 |
| 按键、UI 寄存器、复位 | `u_key*`、`u_ui_regs`、`inst_reset_ctrl` | 179 | 0.3% | 0 | 0 |
| **合计** | | **60,342** | | **256** | **159** |

加速器占了约 58% 的逻辑、59% 的 RAM 和 97% 的 DSP。其余部分构成整条视频链路：摄像头 → ISP → DDR → 合成 → HDMI。

## 3. 风格迁移加速器内部

`u_engine` 共 34,629 XLR、152 RAM10、155 DSP。wrapper 本层另有 145 XLR。

| 模块 | 作用 | XLR | RAM10 | DSP | 说明 |
|---|---|---|---|---|---|
| `u_pw` | 1×1 卷积（PW），也跑 im2col 后的 3×3 普通卷积 | 12,909 | 37 | 81 | 8×16 MAC 阵列 64 DSP、3,049 XLR；4 路 requant 16 DSP；权重 ROM 26 块，rq ROM 9 块 |
| `u_dw` | 3×3 DW 卷积和 im2col | 9,176 | 59 | 53 | DW 乘法 37 DSP；4 路 requant 16 DSP；权重 ROM 15 块，两条行缓存各 14 块，rq ROM 9 块，输出 FIFO 7 块 |
| `u_norm` | LayerNorm 和 FiLM 仿射 | 4,416 | 14 | 9 | 系数 RAM 9 块（3 个风格的 LN 加 FiLM 区），rsqrt LUT 2 块，像素缓存 3 块；输出 FIFO 用 SRL |
| `u_film` | FiLM 的 GAP 和 MLP | 1,791 | 6 | 1 | MLP ROM：3 个风格共 1152 × 40，拆成 1024 字和 128 字两个数组 |
| `u_add` | 残差 / 分支相加 | 1,380 | 0 | 8 | 4 路 requant 8 DSP；输出 FIFO 用 SRL |
| `u_um`、`u_ua` | 主输入、辅助输入解包 | 691 + 328 | 0 | 0 | |
| `u_pre` | 输入 2×2 box 和量化 LUT | 639 | 11 | 0 | 行对缓存 8 块，RGB 量化 LUT 3 块 |
| `u_post` | 输出反量化和 565 抖动 | 638 | 4 | 0 | |
| `u_wr` | 输出写 DMA | 573 | 7 | 0 | 突发 FIFO 7 块 |
| `u_pack` | 输出打包 | 512 | 0 | 0 | |
| `u_rd_main`、`u_rd_aux` | 主、辅输入读 DMA | 457 + 432 | 7 + 7 | 0 | 每个突发 FIFO 7 块 |
| `u_arb` | AXI 仲裁 | 146 | 0 | 0 | |
| `u_engine` 本层 | pass 表、调度、按风格选 rq 基址 | 543 | 0 | 3 | |

存储按用途汇总：

| 用途 | RAM10 | 内容 |
|---|---|---|
| 网络权重和量化参数（常驻片上，推理时不读 DDR） | 26 + 15 + 9 + 9 = 59 | PW 权重、DW 权重、两套 rq ROM（858 字，含 guide 层的 3 份 requant） |
| 风格参数 | 6 + 9 + 2 = 17 | FiLM MLP ROM（3 个风格）；LN/FiLM 系数 RAM；rsqrt LUT |
| 行缓存和像素缓存 | 14 + 14 + 8 + 3 = 39 | DW 两条行缓存、pre 行对缓存、norm 像素缓存 |
| DMA 和流水 FIFO | 7 × 4 = 28 | 读主、读辅、写、DW 输出 |
| 其他 | 9 | pre LUT 3 块，post 4 块，PW 本层 2 块 |

DSP 按用途汇总：

| 用途 | DSP |
|---|---|
| PW MAC 阵列（8×16 = 128 MAC/周期） | 64 |
| DW 乘法 | 37 |
| requant（PW 4 路、DW 4 路、add 4 路） | 40 |
| LN / FiLM 乘法 | 10 |
| 调度 | 3 |
| SoC CPU 乘法器 | 4 |

**每个风格多占多少**：

- FiLM MLP ROM：380 字 × 40 位，约 2 个 RAM10。
- LN 系数：20 行，放在已有的系数 RAM 里，不多占块。
- guide 层的 requant：8 个字，放在已有的 rq ROM 里，不多占块。
- 逻辑：按风格选址只用了几十个 XLR。

## 4. 其余子系统

**视频子系统 `u_vid`**（7,381 XLR，31 RAM10）：

| 模块 | XLR | RAM10 | 说明 |
|---|---|---|---|
| ISP（`u_isp`） | 2,996 | 7 | 黑电平/白平衡 590（运行时增益，乘法用 LUT），去马赛克 630（4 RAM），饱和度 731，原始统计 415，灰像素统计 397，抖动 192，gamma 3 RAM |
| 合成（`u_comp`） | 981 | 0 | 摄像头层、处理层和 OSD 合成 |
| 帧写 DMA（`u_wr`） | 918 | 7 | |
| 两个帧读 DMA（`u_rd0`、`u_rd1`） | 424 + 397 | 7 + 7 | |
| AXI 仲裁（`u_arb`） | 467 | 0 | 视频、加速器、CPU 共享 DDR |
| 帧环、采集、行释放等 | 约 842 | 3 | |
| 本层 | 357 | 0 | |

**DDR3 控制器 `u_ddr3_top`**（6,223 XLR，39 RAM10）：

- PHY：2,418 XLR，22 RAM10。
- AXI 总线：1,510 XLR。
- 存储器总线：1,260 XLR。
- 本地总线：516 XLR。
- 时钟域转换：502 XLR，17 RAM10。

**RISC-V SoC `u_riscv_soc0`**（4,875 XLR，21 RAM10，4 DSP）：

（以下细分取自上一版，SoC 本身没有改动，布局差异只有几十个 XLR。）

- CPU：2,677 XLR，4 RAM10，4 DSP。
- 片上 RAM（OCR）16 KB：16 RAM10。
- I2C（摄像头配置）：598 XLR。
- UART：334 XLR，1 RAM10。
- CLINT、调试、GPIO、总线等：约 1,230 XLR。

**MIPI CSI-2 接收**（3,253 XLR，11 RAM10）：

- D-PHY：1,223 XLR。
- 协议层：2,030 XLR，其中字节转像素 1,525 XLR、7 RAM10，通道对齐 4 RAM10。

**HDMI/DVI 发送**（1,437 XLR，2 RAM10）：

- TMDS 编码三通道约 400 XLR。
- 辅助包（`tx_aux_inst`）930 XLR，其中 264 是 SRL FIFO。

## 5. 时钟和时序

| 时钟 | 约束频率 | 可达频率 | 最差 setup slack | 用途 |
|---|---|---|---|---|
| `i_mipi_tx_pclk`（RTL 里叫 `sys_clk`） | 125 MHz | 134.8 MHz | +0.58 ns | 加速器、视频子系统、SoC、CSI 接收侧、DDR 的 AXI 口、UI |
| `core_clk` | 100 MHz | 187.5 MHz | +4.67 ns | 只剩 DDR3 控制器内核 |
| `sdram_clk`、`tx/rx_cal_clk` | 400 MHz | 405–450 MHz | +0.03 ns 起 | DDR3 PHY |
| `vid_clk_dvi2`、`hdmi_tx_slow_clk` | 74.25 MHz | 124–526 MHz | +5.38 ns 起 | 720p60 像素时钟 |
| `hdmi_tx_fast_clk` | 371.25 MHz | – | – | TMDS 串行化（硬核） |
| `i_mipi_rx_pclk` | 50 MHz | 120.3 MHz | +11.7 ns | CSI-2 接收 |
| `i_cam_ck_CLKOUT` | 100 MHz | 162.2 MHz | +3.84 ns | 摄像头侧 |

所有时钟关系的 setup 和 hold 都满足。最差 setup slack 是 0.030 ns（`tx_cal_clk`，DDR PHY 内部，厂商 IP 的固定路径），最差 hold slack 是 0.026 ns。

`sys_clk` 用的是 MIPI TX PLL 空着的 125 MHz 输出。DDR3 控制器内核留在 100 MHz：它到 PHY 的路径按固定 4:1 比例约束，内核提到 125 MHz 时 slack 是 -0.69 ns。
双风格版本的 sys_clk 可达 147 MHz，加到 3 个风格后降到 135.7 MHz，XLR 用到 99.25% 的最终版是 134.8 MHz，离 125 MHz 还有约 8% 的余量。

## 6. 性能和资源效率

- 板上每帧 7.36M–7.50M 个 `sys_clk` 周期（随画面和 DDR 争用浮动），也就是 125 MHz 下每帧约 59.6 ms，16.7–17.0 fps（约 16.8 fps），`errors 0`。仿真是 6.41M 周期。
  板上比仿真多出的周期主要是 DDR 等待。DDR 内核仍是 100 MHz，所以按周期算，访存比 100 MHz 版本（6.85M）显得更慢。
- 3 个风格的每帧周期相同，切换风格不影响帧率。
- 网络 0.59 GMAC/帧（640×360）。PW 阵列峰值 128 MAC/周期，按板上周期算整帧平均约 80 MAC/周期，按仿真周期算约 92 MAC/周期。
- 网络权重和 3 个风格的参数全部常驻片上，DDR 只存特征图和视频帧。

## 7. 和之前版本对比

| 项目 | feat/st-guided 374d536（2 风格，100 MHz） | feat/st-fmax dad8cb8（final_s3b，固定白平衡） | feat/st-fmax 91514ca（s3d，固件 AWB/AE，最终版） |
|---|---|---|---|
| XLR | 59,722（98.2%） | 59,804（98.4%） | 60,342（99.25%） |
| RAM10 | 254 | 256 | 256 |
| DSP | 159 | 159 | 159 |
| 用户逻辑时钟可达频率 | 122.7 MHz（core_clk） | 135.7 MHz（sys_clk） | 134.8 MHz（sys_clk） |
| 板上 | 14.6 fps | 16.8 fps | 16.8 fps |

- dad8cb8 比 374d536 多出的 2 个 RAM10 是第 3 个风格的 FiLM ROM。一个 1152 深的数组 Efinity 会凑成 2048 深、占 8 块，所以拆成 1024 字和 128 字两个数组，只占 6 块。
- s3d 和 final_s3b 结构完全相同（同样的风格包和 packet_guide），换模型只换了 ROM 内容，加速器资源不变。
- 91514ca 多出的约 540 XLR 全在视频子系统和顶层：ISP 增益从编译期常量改成运行时寄存器（乘法器不再能被常量化简，用 `mul_nodsp` 的 LUT 乘法，保持视频子系统 0 DSP），新增灰像素统计，`ui_regs` 扩到 16 个寄存器。
  第一次编译超了 96 XLR（60,896），靠去掉暗像素计数、把原始统计的计数器收窄、灰像素统计只累加高 8 位才放下。

## 8. 余量和压缩历史

**剩余余量**：458 XLR、0 RAM10、1 DSP。XLR 已达 99.25%，再加任何逻辑都要先在别处省出来。

**已经做过的压缩**（详见 docs/st-engineering-notes.md、docs/st-multistyle-deploy.md）：

- 小 FIFO（st_add、st_norm 的 16 深输出）改用 SRL，省了 4 RAM10。
- DW 的列延迟线用 SRL。
- FiLM ROM 每个风格的步长从 512 字压到 384 字，并拆成两个数组，3 个风格占 6 块，不是 8 块。
- LN 偏置 `B_c` 只存一半（它总是偶数）。这样一个风格较大的 β 也能放进 27 位字段，不用加宽系数 RAM（加宽要多 1 块）。
- ISP 统计：原始统计的相位和收窄到 28 位、削顶计数 20 位，去掉暗像素计数；灰像素统计只累加每个分量的高 8 位，不计像素数。

**还能腾出资源的地方**：

| 方式 | 可省 | 代价 |
|---|---|---|
| OCR 16 KB → 8 KB | 8 RAM10 | 固件现在约 6.2 KB（text 3,148 + data 958 + bss 2,076，含栈），加上 AWB/AE 以后离 8 KB 已经不远。要重新生成 SoC，并改 linker 设置 |
| DW 输出 FIFO 改小或改 SRL | 最多 7 RAM10 | 要重新核对 DW 的反压深度；用 SRL 需要约 1,000 XLR，现在剩下的 XLR 不够 |
| ISP 去掉饱和度、原始统计或灰像素统计 | 约 730、415 或 400 XLR | 影响画质调节；去掉统计后 AE/AWB 要改用别的输入 |
| 去掉 HDMI 辅助包（`tx_aux_inst`） | 约 940 XLR | 要先确认演示用的显示器不依赖它 |

再加第 4 个风格要多 2 个 RAM10（FiLM ROM），需要先降 OCR。

## 9. 重新取数

```bash
cd fpga_src-st-fmax
grep -A22 "Resource Summary (begin)" outflow/fpga_src.place.rpt | tail -n 22   # 总量
# 按模块：前 4 级层次
awk -F'|' '/^\| +\+/ {n=$2; match(n,/^ */); if (RLENGTH<=4) print $2, $3, $4, $5}' outflow/fpga_src.hier_util.rpt
sed -n '/User target constrained clocks/,/Clock Frequency Summary (end)/p' outflow/fpga_src.timing.rpt
sed -n '/Setup (Max) Clock Relationship/,/^$/p' outflow/fpga_src.timing.rpt
```

表里 XLR 的数字直接取自 hier_util 报告，该报告对某些模块会给出 .5 的小数，表里四舍五入到整数。模块之和与总量之间有不超过几个 XLR 的取整误差。
