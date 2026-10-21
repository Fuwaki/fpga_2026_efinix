# 视频读侧 SV 重构：1/120 横向错位问题报告

> **状态：已解决（2026-10-20）。** 根因见 §2。下方 §5 记录的七次无效尝试与
> §6 的三个可疑点均**不是**根因，保留作为排查过程记录，避免后续重复。
> 修正位于 `rtl/display/layer_fetch.sv` 的 `flush` 端口。

| 项 | 值 |
|---|---|
| 工程 | `/data/competition/2026fpga/fpga_src` |
| 分支 | 当前工作区，基于 `f4f3e69`（可出图基线） |
| 板卡 | Titanium Ti60F225 + SC431HAI + DDR3 |
| 输出 | CEA 1080p60，TMDS 正常锁定 |
| 日期 | 2026-10-20 |

---

## 1. 一句话结论

显示链路已重建并可出图，曾存在**固定的 1 AXI-beat 横向循环错位**：画面最左
约 16 像素（占宽 1/120）显示的是本该位于最右的内容。

**根因**：`layer_fetch` 的 FIFO 跨帧残留 1 个 beat，且每帧的产生量与消费量
恰好相等，残留永远无法被排空。**修正**：每帧在场起始处清空 FIFO。

---

## 2. 根因与修正（最终结论）

### 2.1 机制

`layer_fetch` 在有效窗口内消费（960 字/行 × 1080 行 = 1,036,800 字/帧），
`par2ser` 每帧推送同样数量的字。**产生 = 消费**，所以：

- 帧与帧之间若残留任意数量的字（上电首帧、短帧、长帧、`par2ser` 的
  `data_buffer` 在帧末锁存的那一拍），该残留会**永久停在 FIFO 头部**。
- 每行因此整体后移 1 个 beat：行首出现上一行最后一拍的内容。
- 1 beat = 8 字 = 16 像素 = 1920 的 1/120，与观测完全吻合。

### 2.2 修正

`layer_fetch` 新增 `flush` 端口，接 `raster_gen.vline_zero`（`vc == 0`，场第 0 行）：

```verilog
wire push = in_valid && !full;
wire pop  = want && !empty;

logic flush_d;
wire  flush_pulse = flush & ~flush_d;   // 单拍边沿

always_ff @(posedge clk or negedge rst_n) begin
    ...
    end else if (flush_pulse) begin
        wr_ptr <= '0;
        rd_ptr <= '0;
        count  <= '0;
    end else begin
        ...
```

要点两条：

1. **必须清空指针与计数**，不能只清数据：残留的是「位置」而非「内容」。
2. **必须边沿触发**。`vline_zero` 持续整行（`vc==0` 满 `H_TOTAL` 拍），
   若用它直接门控 `push`/`pop`，会阻塞整行的写入与读取。

原 `data_tx` 靠 `fifo_rd_period` 下降沿复位自己的 FIFO，做的是同一件事
（`fifo_rst = neg_fifo_rd_period`），只是分散在另一个模块里。

### 2.3 为何之前七次尝试无效

因为问题不在**时序契约**（极性/相位/脉宽），也不在**单拍延迟对齐**，
而在**缓冲区的生命周期**：FIFO 需要一个跨帧的清零点。这属于状态管理问题，
数据通路上的任何调参都无法影响它。

---

## 2. 当前架构（本次重构目标）

拆分原则：**显示时序不依赖采集**。采集侧速率可任意，显示侧 raster 永不停摆。

```text
采集（CLAUDE 未改）：
  MIPI CSI → i_mipi_rx_pclk → frame_buffer 写侧（RAW32 打包）
      → AXI 写 → DDR（FB_NUM=3，bank_switch 切 bank）

显示（本次重构）：
  ddr_rd_buffer（AXI 读整帧 → rd_fifo 128bit）
      → par2ser_parse / vid_par2ser（128bit → 16bit 字，vid_clk 域）
      → layer_fetch（FIFO 缓冲 + 窗口裁剪，vid_clk 域）
      → debayer_top_2to1（16bit → RGBx2）
      → 2 像素/拍解包（hdmi_tx_slow_clk 148.5MHz）
      → gamma → saturation → dvi_encoder → HDMI
```

新增模块：

| 文件 | 职责 |
|---|---|
| `rtl/video/video_contract_pkg.sv` | SV package：raster 常量、`rgb24_t`、`layer_desc_t`、`pix_stream_t` |
| `rtl/display/raster_gen.sv` | 纯计数器产生 hs/vs/de/x/y/sof/vline_zero，**无外部数据输入** |
| `rtl/display/frame_sync.sv` | 每帧一个 `frame_period` 标记，驱动 `ddr_rd_buffer.start` 与 `par2ser.frame_period` |
| `rtl/display/layer_fetch.sv` | 16bit 字 FIFO + 窗口消费，吸收读写速率差 |
| `rtl/frame_buffer_V3/frame_buffer_read.sv` | 组装上述三者，替换 `data_tx` |

`frame_buffer.v` 用 `parameter RD_FREE_RUN` 做 `generate` 分支：
`RD_FREE_RUN=1` 走新读侧（当前），`=0` 保留原 `data_tx` 老路径（可回退）。

---

## 3. 现象（可复现）

### 3.1 画面
- HDMI 正常锁定 1080p60。
- 画面内容正确（能看见摄像头实时影像，手在镜头前晃动会变化）。
- **最左侧出现一条竖向错位带，宽度约为画面宽度的 1/120**，其内容是本应位于画面**最右侧**的部分。
- 其余部分内容正确，无撕裂、无闪烁、无色彩异常。

### 3.2 已排除
| 假设 | 排除依据 |
|---|---|
| 色彩/白平衡问题 | 错位是**空间**错位，不是通道亮度偏差；WB 是全局乘数，不产生空间分界 |
| DDR 带宽或容量不足 | 256 MiB DDR，3 帧 1080p RGB 仅 23.7 MiB；遥测无异常 |
| 显示时序错误 | `board_smoke_test` 报告 `de=64800/s`、`hs=67500/s`、`vs=60/s`，精确等于 1080p60 |
| 时钟问题 | `slow_hb=566/0.5s`（148.5MHz）、`video_hb=283/0.5s`（74.25MHz）均正确 |
| 编码器/TMDS | 输出稳定锁定，且此前 `TP_EN` 彩条可正常显示 |

### 3.3 遥测基线（当前板载）
```json
{"de":2727820,"hs":2841486,"vs":2526,"slow_hb":48717,"video_hb":24359,
 "status":15,"delta":{"de":32400,"hs":33750,"vs":30,"slow_hb":566,"video_hb":284}}
```
`status=15` = PLL 全锁 + DDR 校准完成 + 视频复位释放 + SoC 完成摄像头 I2C。

---

## 4. 关键量化关系

```
1920 px / line
  ÷ 8 word  (每个 16bit 字含 2 个 Bayer 像素 → 960 word/line)
  ÷ 8 word/beat (AXI 128bit = 8 × 16bit)
  = 120 AXI beat / line
```

因此：

- **1 beat 偏移 = 8 word = 16 px = 画面宽度的 1/120**
- 观测到的错位带宽度恰好是 1/120，**说明偏移量精确等于 1 个 AXI beat**

这个数字是定位的核心线索：偏移发生在 **beat 粒度**，不是像素粒度，也不是行粒度。

---

## 5. 已尝试的修复（全部无效）

按时间顺序，全部已烧录验证：

| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | `frame_period` 极性反了 | 改为「平时高、单拍低」 | 从纯色变为有画面（有效，但不是本问题） |
| 2 | `frame_period` 相位错（锚在 `sof`） | 改为锚在 `vs` 上升沿 | 全黑（更差） |
| 3 | 相位应锚在 `vc==0` | 增加 `vline_zero` | 恢复画面，错位仍在 |
| 4 | 低电平脉宽 1 拍不够 | 加宽到 8 拍 | **错位未变** |
| 5 | 低电平应覆盖整行 | `frame_period <= ~vline_zero`（1100 拍低） | **错位未变** |
| 6 | `layer_fetch` RAM 读延迟导致地址错拍 | 由 `rd_ptr` 直接寻址 | **错位未变** |
| 7 | 同步信号延迟与数据延迟不匹配 | `hs/vs/de` 由 2 拍改为 1 拍 | **错位未变** |

结论：**问题不在 `frame_period` 的极性/相位/脉宽，也不在 `layer_fetch` 的单拍延迟对齐。**

---

## 6. 曾经的可疑点（已全部排除，保留供参考）

### 6.1 `par2ser` 在 `IN_CNT == 1` 时的退化（已排除）

`vid_par2ser.v` 内部：

```verilog
localparam MAXI_DATA_WIDTH = max_width(I_VID_WIDTH, O_VID_WIDTH); // 128, 16 -> 128
localparam IN_CNT  = MAXI_DATA_WIDTH / I_VID_WIDTH;  // = 1
localparam IN_CNT_WIDTH = $clog2(IN_CNT);            // = 0 !!
```

当 `I_VID_WIDTH=128`（AXI 位宽）且 `O_VID_WIDTH=16` 时，`IN_CNT=1`，于是 `shift_in` 是 **0 位宽**向量，`shift_in == IN_CNT-1`（即 `0==0`）**恒为真**。

受影响的逻辑：

```verilog
if( frame_start_w )
    pipe_en <= 1'b0;
else if( shift_in == 0 && rd_fifo_rdvalid_r )   // 恒真的一半
    pipe_en <= 1'b1;
...
else if( frame_start_w || (shift_in == IN_CNT-1 && rd_fifo_rden) )
    rd_fifo_rden_r <= 1'b0;                      // 恒真的一半
```

这意味着 `rd_fifo_rden_r` 的「每 beat 一次脉冲」在 `IN_CNT=1` 时依赖 `rd_fifo_rden` 自身的时序，而非计数器节拍。**这是原设计的边界缺陷**，在老路径下被 `data_tx` 的 `fifo_rd_en` 掩蔽；新路径的 `layer_fetch` 是纯 FIFO，无法掩蔽。

**建议**：在 128→16 的拆分里显式实现 beat 相位，不要复用退化后的 `shift_in`。或者在 `par2ser` 上游把 `O_VID_WIDTH` 改成 32/64，让 `IN_CNT > 1`。

### 6.2 `data_buffer` 装载顺序（已排除）

`vid_par2ser.v`：

```verilog
data_buffer <= rd_fifo_rdvalid_r ? {data_buffer[MAXI-I-1:0], rd_fifo_rddata} : data_buffer;  // 新 beat 压入低位
...
data_buffer1 <= data_buffer1 << O_VID_WIDTH;                    // 左移
tx_fifo_wrdata = data_buffer1[MAXI-1:MAXI-O_VID_WIDTH];         // 取高位
```

装载是「新数据进低位」，输出是「从高位取出」，这形成 **LIFO 顺序**：最后进入的 beat 最先输出。需确认这与写侧 `ser2par_v1` 的装载顺序严格互逆。若两者不互逆，会出现整 beat 的循环移位——与当前现象高度吻合。

**建议**：用一个最小 testbench 单独验证 `frame_buffer` 的写→读 round-trip（`ser2par → 存储 → par2ser`），输入已知递增图样，检查输出是否逐字相同、无循环移位。

### 6.3 `frame_info_det` 的 `ddr_frame_len` 与实际写入量（已排除）

写侧 `I_VID_WIDTH=32`，每 beat 4 字节；每行实际 beat 数取决于 CSI 每拍像素数。当前 `MAX_VID_WIDTH=960`（按 `I_VID_WIDTH` 字数），仅用于 `bank_switch.compute FRAME_LEN`：

```verilog
localparam FRAME_LEN = MAX_VID_WIDTH*MAX_VID_HIGHT*VID_DATA_WIDTH/8 + 32'h200;
```

若 `FRAME_LEN` 与实际写入量不一致，bank 之间可能出现**地址重叠或空洞**。当前 `MAX_VID_WIDTH=960` 给出 3.956 MiB/槽，而实际写入约 1.98 MiB，槽偏大 → 不越界，但值得确认长期行为（3 bank 共 11.9 MiB，DDR 有余量）。

### 6.4 `bank_switch` 与 `rd_start` 的握手（已排除）

`bank_switch` 的三缓冲逻辑依赖 `wr_sw` / `rd_sw` 双沿信号：

- `rd_sw` 来自 `ddr_rd_buffer.bank_sw`，在**读完一整帧**（`burst_last`）后拉高。
- 新路径的 `frame_period` 每帧触发 `rd_start`。

需确认：当 `frame_period` 早于 `rd_sw` 到达时，`start_addr` 是否已稳定。建议在仿真中观察 `rd_start_addr` 在 `rd_start` 边沿处的稳定窗口。

---

## 7. 复现与验证（当前状态）

### 7.1 构建与烧录
```sh
cd /data/competition/2026fpga/fpga_src
tools/build_all.sh --fpga-only          # 综合+P&R，约 2 分钟
efx_run --prj fpga_src.xml -f program --pgm_opts mode=jtag --dir .
```

### 7.2 遥测
```sh
python3 tools/board_smoke_test.py --port /dev/ttyUSB2 --json
```
关注 `delta.de ≈ 32400/0.5s`、`delta.hs ≈ 33750/0.5s`、`delta.vs = 30/0.5s`。

### 7.3 A/B 对照开关（代码内已有）
`rtl/fpga_src_top.v`：
```verilog
localparam TP_EN = 1'b0;   // 置 1 = 编码器输出本地 8 色竖条，绕过整条像素通路
```
- 彩条正常 → 问题在像素通路（当前情况）
- 彩条异常 → 问题在编码器/TMDS

### 7.4 回退到已验证基线
```sh
git checkout f4f3e69 -- rtl/fpga_src_top.v rtl/frame_buffer_V3/frame_buffer.v fpga_src.xml
```
或把 `frame_buffer.v` 的 `RD_FREE_RUN` 置 0，走回 `data_tx` 老路径。

---

## 8. 文件清单（当前工作区，未提交）

```
M  fpga_src.xml
M  rtl/frame_buffer_V3/frame_buffer.v
?? rtl/display/frame_sync.sv
?? rtl/display/layer_fetch.sv
?? rtl/display/raster_gen.sv
?? rtl/frame_buffer_V3/frame_buffer_read.sv
?? rtl/video/video_contract_pkg.sv
```

MD5（便于确认接手的是同一版本）：

```
4af9b52ae71d7c8defae65d1343f825c  rtl/display/frame_sync.sv
abee4c8a0f93f1141ec53e14ca3d730c  rtl/display/layer_fetch.sv
e5c6d8133692a6240c9d6951c008dc2a  rtl/display/raster_gen.sv
6363afe44eb4b6f9fd80b8e12e4f8a54  rtl/frame_buffer_V3/frame_buffer_read.sv
e33d287b0589c58e8c4b8a2de7b2d8fd  rtl/frame_buffer_V3/frame_buffer.v
```

---

## 9. 验证结果

| 项 | 结果 |
|---|---|
| 画面 | 完美，无错位、无偏色、无撕裂 |
| `map` / `interface` / `pnr` / `pgm` | 全 PASS |
| XLR 用量 | 20,954 / 60,800 |
| 遥测 `delta.de` | 32,400 / 0.5 s → 64,800/s = 1080 行 × 60 fps |
| 遥测 `delta.hs` | 33,750 / 0.5 s → 67,500/s = 1125 行 × 60 fps |
| 遥测 `delta.vs` | 30 / 0.5 s → 60.0 fps |
| `status` | 15 (0x0F)：PLL 锁定 + DDR 校准 + 视频复位释放 + SoC I2C 完成 |

---

## 10. 背景：为何要重构

原 `data_tx` 一个模块同时承担三件事：

1. 生成 HDMI 的 hs/vs/de（显示时序）
2. 产生 `fifo_rd_period` 驱动 `ddr_rd_buffer.start`（读引擎节拍）
3. 用 h/v 状态机输出 `rd_fifo_rden`（逐像素取数）

这导致**读速率必须精确等于显示像素速率**，一旦采集侧或帧缓冲参数变化，整个显示就停摆（此前表现为「无信号」）。重构目标是把三者分离，使显示时序独立、上游速率任意。当前架构已实现该目标（raster 不再被上游阻塞），但引入了本报告描述的 beat 相位问题。
