# 硬件资源使用报告

2026-11-03，feat/st-guided（374d536）：双风格 guided 网络，codex_fix 权重。

- **器件**：Efinix Titanium Ti60F225，速度等级 I3，Efinity 2026.1。
- **数据来源**：一次完整编译的 `outflow/fpga_src.place.rpt`（总量）、`fpga_src.hier_util.rpt`（按模块）和 `fpga_src.timing.rpt`（时序）。重新编译后可以按文末的命令重新取数。

## 1. 总量

| 资源 | 已用 | 总量 | 占比 | 剩余 |
|---|---|---|---|---|
| XLR（逻辑单元） | 59,722 | 60,800 | 98.2% | 1,078 |
| RAM10（10 Kbit 块 RAM，含 3 个 DPRAM10） | 254 | 256 | 99.2% | 2 |
| DSP 块 | 159 | 160 | 99.4% | 1 |
| 全局时钟 GBUF | 16 | 32 | 50% | 16 |
| 区域时钟 RBUF | 1 | 32 | 3% | 31 |
| 输入 / 输出 | 121 / 343 | 1,703 / 2,267 | 7% / 15% | – |

XLR 按用途拆分（每个 XLR 只计一种用途）：

| 用途 | XLR |
|---|---|
| LUT4 | 22,900 |
| LUT4 + FF | 9,505 |
| 加法器 | 7,371 |
| 加法器 + FF | 2,282 |
| SRL8（移位寄存器） | 2,643（SRL8 上限 14,720） |
| 仅 FF | 15,021 |

三种主要资源都已接近用满，剩余的余量只够做小修改。

## 2. 按子系统

| 子系统 | 顶层实例 | XLR | 占比 | RAM10 | DSP |
|---|---|---|---|---|---|
| 风格迁移加速器 | `gen_st_accel.u_st_accel_wrapper` | 34,623 | 58.0% | 150 | 155 |
| 视频子系统（采集、ISP、帧环、合成） | `u_vid` | 7,212 | 12.1% | 31 | 0 |
| DDR3 控制器（厂商 IP） | `u_ddr3_top` | 6,167 | 10.3% | 39 | 0 |
| RISC-V SoC（Sapphire） | `u_riscv_soc0` | 4,866 | 8.1% | 21 | 4 |
| MIPI CSI-2 接收（厂商 IP） | `inst_efx_csi2_rx` | 3,302 | 5.5% | 11 | 0 |
| HDMI/DVI 发送 | `dvi_encoder_m0` | 1,437 | 2.4% | 2 | 0 |
| 顶层胶合逻辑 | `fpga_src` 本层 | 1,977 | 3.3% | 0 | 0 |
| 按键、UI 寄存器、复位 | `u_key*`、`u_ui_regs`、`inst_reset_ctrl` | 140 | 0.2% | 0 | 0 |
| **合计** | | **59,722** | | **254** | **159** |

加速器占了约 58% 的逻辑、59% 的 RAM 和 97% 的 DSP。其余部分构成整条视频链路：摄像头 → ISP → DDR → 合成 → HDMI。

## 3. 风格迁移加速器内部

`u_engine` 共 34,478 XLR、150 RAM10、155 DSP。wrapper 本层另有 145 XLR。

| 模块 | 作用 | XLR | RAM10 | DSP | 说明 |
|---|---|---|---|---|---|
| `u_pw` | 1×1 卷积（PW） | 12,825 | 37 | 81 | 8×16 MAC 阵列 64 DSP、3,049 XLR；4 路 requant 16 DSP；权重 ROM 26 块，rq ROM 9 块 |
| `u_dw` | 3×3 卷积（DW 和普通 conv） | 9,177 | 59 | 53 | DW 乘法 37 DSP；4 路 requant 16 DSP；权重 ROM 15 块，两条行缓存各 14 块，rq ROM 9 块，输出 FIFO 7 块 |
| `u_norm` | LayerNorm 和 FiLM 仿射 | 4,397 | 14 | 9 | 系数 RAM 9 块（两个风格的 LN 加 FiLM 区），rsqrt LUT 2 块，像素缓存 3 块；输出 FIFO 用 SRL |
| `u_film` | FiLM 的 GAP 和 MLP | 1,788 | 4 | 1 | MLP ROM 每个风格 2 块 |
| `u_add` | 残差 / 分支相加 | 1,373 | 0 | 8 | 4 路 requant 8 DSP；输出 FIFO 用 SRL |
| `u_um`、`u_ua` | 主输入、辅助输入解包 | 689 + 327 | 0 | 0 | |
| `u_pre` | 输入 2×2 box 和量化 LUT | 638 | 11 | 0 | 行对缓存 8 块，RGB 量化 LUT 3 块 |
| `u_post` | 输出反量化和 565 抖动 | 635 | 4 | 0 | |
| `u_wr` | 输出写 DMA | 560 | 7 | 0 | 突发 FIFO 7 块 |
| `u_pack` | 输出打包 | 505 | 0 | 0 | |
| `u_rd_main`、`u_rd_aux` | 主、辅输入读 DMA | 458 + 430 | 7 + 7 | 0 | 每个突发 FIFO 7 块 |
| `u_arb` | AXI 仲裁 | 162 | 0 | 0 | |
| `u_engine` 本层 | pass 表和调度 | 516 | 0 | 3 | |

存储按用途汇总：

| 用途 | RAM10 | 内容 |
|---|---|---|
| 网络权重和量化参数（常驻片上，推理时不读 DDR） | 26 + 15 + 9 + 9 = 59 | PW 权重、DW 权重、两套 rq ROM |
| 风格参数 | 4 + 9 + 2 = 15 | FiLM MLP ROM（2 个风格）；LN/FiLM 系数 RAM；rsqrt LUT |
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

## 4. 其余子系统

**视频子系统 `u_vid`**（7,212 XLR，31 RAM10）：

| 模块 | XLR | RAM10 | 说明 |
|---|---|---|---|
| ISP（`u_isp`） | 2,761 | 7 | 黑电平/白平衡 653，去马赛克 630（4 RAM），饱和度 731，统计 513，抖动 192，gamma 3 RAM |
| 合成（`u_comp`） | 1,006 | 0 | 摄像头层、处理层和 OSD 合成 |
| 帧写 DMA（`u_wr`） | 916 | 7 | |
| 两个帧读 DMA（`u_rd0`、`u_rd1`） | 423 + 395 | 7 + 7 | |
| AXI 仲裁（`u_arb`） | 512 | 0 | 视频、加速器、CPU 共享 DDR |
| 帧环、采集、行释放等 | 约 840 | 3 | |
| 本层 | 358 | 0 | |

**DDR3 控制器 `u_ddr3_top`**（6,167 XLR，39 RAM10）：

- PHY：2,419 XLR，22 RAM10。
- AXI 总线：1,459 XLR。
- 存储器总线：1,254 XLR。
- 本地总线：516 XLR。
- 时钟域转换：502 XLR，17 RAM10。

**RISC-V SoC `u_riscv_soc0`**（4,866 XLR，21 RAM10，4 DSP）：

- CPU：2,696 XLR，4 RAM10，4 DSP。
- 片上 RAM（OCR）16 KB：16 RAM10。
- I2C（摄像头配置）：610 XLR。
- UART：333 XLR，1 RAM10。
- CLINT、调试、GPIO、总线等：约 1,230 XLR。

**MIPI CSI-2 接收**（3,302 XLR，11 RAM10）：

- D-PHY：1,240 XLR。
- 协议层：2,062 XLR，其中字节转像素 1,548 XLR、7 RAM10，通道对齐 4 RAM10。

**HDMI/DVI 发送**（1,437 XLR，2 RAM10）：

- TMDS 编码三通道约 400 XLR。
- 辅助包（`tx_aux_inst`）930 XLR，其中 264 是 SRL FIFO。

## 5. 时钟和时序

| 时钟 | 约束频率 | 可达频率 | 最差 setup slack | 用途 |
|---|---|---|---|---|
| `core_clk` | 100 MHz | 122.7 MHz | +1.85 ns | 加速器、视频子系统、SoC、UI |
| `sdram_clk`、`tx/rx_cal_clk` | 400 MHz | 446–470 MHz | +0.13 ns 起 | DDR3 PHY |
| `vid_clk_dvi2`、`hdmi_tx_slow_clk` | 74.25 MHz | 123–440 MHz | +5.78 ns 起 | 720p60 像素时钟 |
| `hdmi_tx_fast_clk` | 371.25 MHz | – | – | TMDS 串行化（硬核） |
| `i_mipi_rx_pclk` | 50 MHz | 135.2 MHz | +12.1 ns | CSI-2 接收 |
| `i_cam_ck_CLKOUT` | 100 MHz | 195.6 MHz | +3.98 ns | 摄像头侧 |

所有时钟关系的 setup 和 hold 都满足。最差 setup slack 是 0.129 ns（`tx_cal_clk`），最差 hold slack 是 0.026 ns。

## 6. 性能和资源效率

- 每帧约 6.85M 个 `core_clk` 周期（板上实测）。板上 14.6 fps，仿真 6.41M 周期。
- 网络 0.59 GMAC/帧（640×360）。PW 阵列峰值 128 MAC/周期，整帧平均约 87 MAC/周期。
- 网络权重全部常驻片上（59 RAM10）。DDR 只存特征图和视频帧。

## 7. 余量和压缩历史

**剩余余量**：1,078 XLR、2 RAM10、1 DSP。布局时 XLR 已达 98%，再加大块逻辑会先碰到布线和时序问题。

**已经做过的压缩**（详见 docs/st-engineering-notes.md）：

- 小 FIFO（st_add、st_norm 的 16 深输出）改用 SRL，省了 4 RAM10。
- DW 的列延迟线用 SRL。

**还能腾出资源的地方**：

| 方式 | 可省 | 代价 |
|---|---|---|
| OCR 16 KB → 8 KB | 8 RAM10 | 固件现在约 4.7 KB（含栈）。要重新生成 SoC，并改 linker 设置 |
| DW 输出 FIFO 改小或改 SRL | 最多 7 RAM10 | 要重新核对 DW 的反压深度；用 SRL 需要约 1,000 XLR，现在剩下的 XLR 不够 |
| ISP 去掉饱和度或统计模块 | 约 700 或 500 XLR | 影响画质调节 |
| 去掉 HDMI 辅助包（`tx_aux_inst`） | 约 930 XLR | 要先确认演示用的显示器不依赖它 |

从 2 个风格扩到 4 个风格，FiLM ROM 要再加 4 RAM10。比较可行的办法是 OCR 降到 8 KB（docs/st-multistyle-deploy.md 第 6 节）。

## 8. 重新取数

```bash
cd fpga_src-st-accel
grep -A22 "Resource Summary (begin)" outflow/fpga_src.place.rpt | tail -n 22   # 总量
# 按模块：前 4 级层次
awk -F'|' '/^\| +\+/ {n=$2; match(n,/^ */); if (RLENGTH<=4) print $2, $3, $4, $5}' outflow/fpga_src.hier_util.rpt
sed -n '/User target constrained clocks/,/Clock Frequency Summary (end)/p' outflow/fpga_src.timing.rpt
sed -n '/Setup (Max) Clock Relationship/,/^$/p' outflow/fpga_src.timing.rpt
```

表里 XLR 的数字直接取自 hier_util 报告，该报告对某些模块会给出 .5 的小数。模块之和与总量之间有不超过几个 XLR 的取整误差。
