# fpga_src — Ti60F225 + SC431HAI 摄像头 → HDMI

在 Titanium **Ti60F225** 上实现：**MIPI CSI-2 摄像头采集 + DDR3 帧缓冲 + 图像处理 + HDMI 输出**，
并把**摄像头的 I2C 配置交给片上 RISC-V (Efinix Sapphire RV32 SoC)**。

参考工程（只参考这一个）：`../10_Ti60f225_sc431hai2hdmi_demo/Ti60f225_sc431hai2hdmi_v6`。
本次移植**引脚/外围完全沿用参考工程**（`fpga_src.peri.xml` 由 `ti60f225_oob.peri.xml` 直接改
`design_db name` 而来），所以板上接线、PLL、DDR3 PHY、MIPI RX/DSI LVDS、HDMI TMDS 全部一致。

---

## 1. 数据通路

```mermaid
graph LR
  CAM[SC431HAI 4-lane CSI-2] -->|LVDS| CSI[csi_rx_controller]
  CSI -->|40bit RAW10 取高 8 位| FB[frame_buffer V3 + ddr3_top]
  FB -->|960x1080 @74.25M| DB[debayer + 白平衡 rgb_gain_v1]
  DB --> G[gamma 校正 SRGB_ENC.mem]
  G --> SAT[饱和度增强]
  SAT --> ENC[dvi_encoder]
  ENC --> HDMI[TMDS 1080p60]

  CPU[Sapphire RV32 SoC<br/>riscv_soc0 @100MHz] -.I2C0 开漏.-> CAM
  CPU -.GPIO0[0].-> LED[led1: 配置完成]
```

| 环节 | 频率 | 说明 |
|---|---|---|
| `i_mipi_rx_pclk` | 50 MHz | CSI RX 像素时钟 |
| `core_clk` | 100 MHz | DDR3/DDR 逻辑 + **SoC 主频** |
| `vid_clk_dvi2` | 74.25 MHz | debayer/白平衡/gamma 域 |
| `hdmi_tx_slow_clk` | 148.5 MHz | 饱和度 + TMDS 编码，1080p60 |
| `sdram_clk` | 400 MHz | DDR3 |

输出时序为 CEA 1080p60（HFP/HSP/HBP = 88/44/148，VFP/VSP/VBP = 4/5/36）。

---

## 2. 目录

```
fpga_src.xml            工程文件（顶层 fpga_src，rtl/fpga_src_top.v）
fpga_src.peri.xml       Interface Designer 引脚/外围（沿用参考工程）
fpga_src.sdc            时序约束（沿用参考工程）
rtl/
  fpga_src_top.v        顶层：视频通路 + SoC 例化 + 引脚保持逻辑
  csi_rx_controller.sv  MIPI CSI-2 RX IP（加密核，参数在文件头明文）
  ddr3_controller/      软 DDR3 控制器 + 校准
  frame_buffer_V3/      DDR3 三帧缓冲（bank_switch / ddr_buffer / ...）
  debayer/              Bayer→RGB + 白平衡增益
  dvi_tx/               HDMI TMDS 编码器（加密核）
  gamma_conrrection/    gamma 校正 + 曲线 mem
  cam_i2c_ctrl/         【仅存档】原 FPGA 侧 I2C 寄存器表，现已不参与综合，
                        固件的寄存器表由它导出
ip/riscv_soc0/          无 IDE 生成的 Sapphire RV32 SoC（含片上 RAM 初始化 .bin）
embedded_sw/riscv_soc0/ BSP + 固件
  software/standalone/camera/cameraI2c/   本工程的固件（摄像头 I2C 初始化）
  camera_i2c.hex                          固件编译产物（嵌进 SoC 用）
tools/gen_ip.py         无 IDE 生成/重配 IP 的脚本
tools/build_all.sh      一键构建（固件 → SoC → bitstream）
```

---

## 3. 与参考工程的差异

**照搬**：整条视频通路 RTL、`peri.xml`、`sdc`、引脚、DDR3 参数、gamma 曲线用法。

**改动**：
1. 顶层改名 `fpga_src`，文件放 `rtl/fpga_src_top.v`（放在 `rtl/` 是为了
   `include "ddr3_controller/ddr3_parameter.vh"` 的相对路径与参考工程一致）。
2. **删除 JTAG debug core**（VIO / Logic Analyzer）。因此：
   - `gamma_sel`（原来自 VIO）改成 `localparam GAMMA_BYPASS`；
   - 参考工程里"VIO 写入不生效、白平衡只能硬编码"的问题不复存在；
   - 未使用的 JTAG/DSI 输入引脚由一段 `pin keep` 异或逻辑保留（否则综合会把
     无负载输入裁掉，PnR 报 `Required pin ... is not found`）。见
     `rtl/fpga_src_top.v` 中"未使用的外围输入引脚保持"一节。
3. **摄像头 I2C 上移到 RISC-V**：删掉 `i2c_master_ctrl_top` 及其 164 条 ROM 播放器，
   改为 Sapphire SoC 的 I2C0 直接驱动 `io_cam_scl/sda`，寄存器表搬进固件。
4. 增加 SoC 状态灯：`SoC GPIO0[0] -> led[1]`。

---

## 4. 工具链

| 工具 | 位置 | 说明 |
|---|---|---|
| Efinity 2026.1.132 | `/opt/efinity/2026.1`，`/usr/bin/efx_run` 等 | 已可命令行使用 |
| RISC-V GCC | `/opt/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin` | xPack `riscv-none-elf-gcc`（官方 RISC-V IDE 用的同一套），支持 rv32imc/ilp32 |

把工具链加进 PATH：

```sh
export PATH=/opt/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin:$PATH
```

**IP 不需要 IDE**：`tools/gen_ip.py` 直接调用 Efinity IP Manager 的 python API，
等价于 GUI 里"选 IP → 改参数 → Generate"。示例：

```sh
python3 tools/gen_ip.py --list
python3 tools/gen_ip.py --vlnv soc/efx_soc:3.4.0 --dump-params
```

---

## 5. 构建

```sh
# 全流程（固件 + SoC + FPGA），约 4 分钟
tools/build_all.sh

# 只改了 RTL：跳过固件和 IP 生成，约 2.5 分钟
tools/build_all.sh --fpga-only

# 改了固件但没改 SoC 配置
tools/build_all.sh --no-ip
```

只跑 FPGA 时等价于：

```sh
efx_run --prj fpga_src.xml -f compile --dir .
```

构建产物：

| 文件 | 用途 |
|---|---|
| `outflow/fpga_src.hex` | 烧 SPI flash，起始地址 `0x000000` |
| `outflow/fpga_src.bit` | JTAG 下载 |
| `embedded_sw/.../camera_i2c/build/camera_i2c.elf` | 固件调试用 |

> 本工程**只有一个比特流**：SoC 固件已经作为片上 RAM 初值编进 bitstream，
> 不需要像参考工程那样再单独烧一个 `0x380000` 的固件镜像。

构建参数：`max_threads=24`（`fpga_src.xml` 综合/PnR 两处）。

---

## 6. SoC（riscv_soc0）配置与接口

配置（`tools/build_all.sh` 里的 `SOC_PARAMS`，改完必须重跑 IP 生成）：

| 项 | 值 | 理由 |
|---|---|---|
| SOC_MODE | Standard | |
| Frequency | 100 MHz | 与 `core_clk` 同源 |
| DDR | 关 | 外部 DDR3 留给视频帧缓冲，SoC 用片上 RAM |
| OCRSize | 64 KB | 固件实测占 9.5 KB |
| I2C0 | 开 | 摄像头配置 |
| UART0 | 开 | 本板没空闲串口脚，暂未引出 |
| GPIO0 | 开（4 位） | 状态灯 + 预留按键 |
| SPI0/1/2 | 关 | 不需要 |
| AXISlave | 关 | 不接 AXI master |
| DEBUG | 关 | 不带 JTAG 调试核 |
| HexFile_Path | `embedded_sw/riscv_soc0/camera_i2c.hex` | Custom On-Chip RAM Application：直接跑固件，不跑 SPI bootloader |

顶层连接（`rtl/fpga_src_top.v`）：

```verilog
.io_systemClk              (core_clk)          // 100 MHz
.io_asyncReset             (~w_arstn)          // 所有 PLL 锁定后释放
.system_i2c_0_io_scl_read  (io_cam_scl_IN)
.system_i2c_0_io_scl_write (w_soc_i2c_scl_write)
.system_i2c_0_io_sda_read  (io_cam_sda_IN)
.system_i2c_0_io_sda_write (w_soc_i2c_sda_write)

// I2C 开漏：write=0 拉低，write=1 释放（靠总线/内部弱上拉）
assign io_cam_scl_OUT = 1'b0;
assign io_cam_scl_OE  = ~w_soc_i2c_scl_write;
assign io_cam_sda_OUT = 1'b0;
assign io_cam_sda_OE  = ~w_soc_i2c_sda_write;
```

极性依据：Efinity 自带示例 `ip/riscv_soc0/T120F324_devkit/top_soc.v` 的
`writeEnable = !write`，配合三态 GPIO 的 `OUT=0`，即开漏。

---

## 7. 固件（cameraI2c）

`embedded_sw/riscv_soc0/software/standalone/camera/cameraI2c/`

- `src/sc431hai_regs.h`：164 条寄存器表，**由 `rtl/cam_i2c_ctrl/i2c/i2c_master_reg_rom.v`
  自动导出**，顺序不可改（数据手册要求上电时序不能重排；其中 index 0 是
  `0x0100=0x00` 停流，index 0x90 是 `0x0100=0x01` 开流）。
- 设备地址：数据手册 1.4 节，PAD SID 低电平 → 7-bit `0x30` / 8-bit 写地址 `0x60`
  （与参考工程的 `I2C_DEVICE_ADDR=8'h60` 一致）。
- 报文格式：16-bit Sub Address（先高后低）+ 8-bit data，用 BSP 的
  `i2c_writeData_w()`。
- 跑完 164 条后把 GPIO0[0] 置 1 → 点亮 `led[1]`。

单独编译：

```sh
cd embedded_sw/riscv_soc0/software/standalone/camera/cameraI2c
make BSP=efinix/EfxSapphireSoc
```

> `BSP=efinix/EfxSapphireSoc` 必须传；IDE 会自动填，命令行要显式给。

---

## 8. 后续要加按键时

两条现成的路：

1. **SoC GPIO0**：4 位，`system_gpio_0_io_write/read/writeEnable`。
   顶层把要用的位接到板上按键脚（需要在 `fpga_src.peri.xml` 里给对应引脚
   加/改 GPIO 定义，用 Interface Designer 或在 peri.xml 里改 `comp_gpio`），
   固件用 `gpio_getInput()` 轮询或开中断（`gpio_setInterruptRiseEnable` 等）。
2. **APB3 从机 `io_apbSlave_0_*`**：SoC 已经引出 APB3 主机接口
   （基址 `0xf8010000` 起，`APBSlave0_Size=64KB`）。自己写一个 APB3 从机模块
   挂上去（参考 `ip/riscv_soc0/T120F324_devkit/top_soc.v` 里的 `apb3_slave` 例化），
   适合做按键消抖/状态寄存器这类"带寄存器映射"的逻辑，RPU 侧用
   `read_u32/write_u32` 访问。

当前顶层 APB 主机已被引出但**悬空**（`w_soc_apb_*` 未接从机，`PREADY=1`），
直接挂模块即可，不用改 SoC 配置。

---

## 9. 已知限制 / 未做

- **不是上个电就能看的成品**：本次交付到"综合/布局布线/bitstream 全过 + 时序收敛 +
  固件编译并嵌入"为止，**没有上板验证**（本机 `lsusb` 里没有 Efinix 下载器，
  也无法接摄像头/显示器）。
- 板上资源余量：XLR 52.4%（31873/60800）、Memory Block 65%（166/256）、DSP 9/160。
  片上 RAM 已占 64 KB（79 个 BRAM），再加大 SoC 空间要留意 Memory Block。
- UART0 已在 SoC 里使能但**未接引脚**（`rxd` 固定 1），所以固件里的
  `CAM_I2C_VERBOSE` 打开也看不到输出。
- SoC **没有 JTAG 调试核**（`DEBUG=0`）。要用 OpenOCD 单步调试固件，需要
  重新生成 SoC（`DEBUG=1'b1`）并在 `peri.xml` 里加 JTAG 引脚，同时把顶层的
  `pin keep` 段让位给调试核的 TDO。
- `fpga_src/engine/` 是之前 conv-engine 实验留下的目录，与本工程无关，未改动。

---

## 10. 验证记录（本次）

| 项 | 结果 |
|---|---|
| `efx_run -f compile` | map/interface/pnr/pgm 全部 PASS，`last_run_state=pass` |
| 时序 | 最差 setup slack **+0.427 ns**（tx_cal_clk_90edge），hold 无需修复 |
| 资源 | XLR 52.42%、Memory Block 166/256、DSP 9/160 |
| 固件编译 | 9472 B / 64 KB（14.45%），`riscv-none-elf-gcc` rv32imc/ilp32 |
| 寄存器表一致性 | 固件 `.data` 里 656 B 表与参考工程 ROM **逐字节一致**（164 条） |
| SoC 片上 RAM 初值 | `ip/riscv_soc0/*_system_ramA_logic_ram_symbol*.bin` 随固件更新（md5 变化已确认） |

---

## 11. 和"用 IDE 的人"协作 / 怎么改 IP

### 11.1 IP 生成产物就是一套固定结构

`ip/riscv_soc0/` 与 IDE 生成的 `ip/<模块名>/` **逐项一致**（对照参考工程的
`ip/csi_rx_controller/`）：

```
<模块名>.v            生成出来的 HDL 源（SoC 是 SpinalHDL 生成的全部明文 Verilog）
<模块名>_define.vh    宏/地址定义
<模块名>_tmpl.v/.sv/.vhd   例化模板
settings.json         【核心】该 IP 的全部参数记录
ipm/component.pickle  IP Manager 内部缓存（重新配置时用）
ipm/graph.pickle
<器件>_devkit/        交付的示例工程（可以不管）
Testbench/            交付的仿真文件
```

参数**不在工程 XML 里**（`fpga_src.xml` 的 `<efx:ip_info/>` 是空的，参考工程也是空的），
而在每个 IP 自己的 `settings.json` 里。我们的 SoC 那份记了 **152 项**参数：

```json
{ "args": [ ..., {"name":"efx_soc","version":"3.4.0"} ],
  "conf": { "DDR": "1'b0", "OCRSize": "65536", "I2C0": "1'b1",
            "HexFile_PathEnable": "1'b1",
            "HexFile_Path": "embedded_sw/riscv_soc0/camera_i2c.hex", ... } }
```

另外，**引脚/PLL/DDR PHY/LVDS 这些"硬"配置不在 IP 里**，在
`fpga_src.peri.xml`（Interface Designer）。那个才相当于"CubeMX 的单个工程配置文件"。

### 11.2 改 IP 的正确方式（IDE 用户）

生成的 `.v` **不要手改**（下次 Generate 会被覆盖，而且 Efinity 官方明确说
不要手工把 IP 的 .v 加进工程）。正确姿势：

- IDE：Project 面板右键 `ip` 目录 → **Import IP** → 选 `settings.json`
  → 向导带着现有参数打开 → 改 → Generate。
- 命令行（本工程用的方式）：

  ```sh
  python3 tools/gen_ip.py --vlnv soc/efx_soc:3.4.0 --dump-params   # 看参数
  # 改 tools/build_all.sh 里的 SOC_PARAMS 然后：
  tools/build_all.sh
  ```

两条路走的是**同一个 IP Manager API**，改完都会重写 `settings.json`，所以能互相接管。

### 11.3 哪些是加密的（改不了内部逻辑）

| 文件 | 加密比例 | 说明 |
|---|---|---|
| `rtl/csi_rx_controller.sv` | 20 块，约 73% 行 | MIPI CSI-2 RX 核，只有参数和端口是明文 |
| `rtl/dvi_tx/dvi_encoder.v_encrypted.v` | 1 块，约 87% | TMDS 编码核 |
| `ip/riscv_soc0/riscv_soc0.v` | **2 块，约 1%** | SoC 基本全是明文 Verilog（只有 `EfxCPUSp1/Sp2` 两个小块受保护） |

所以 SoC 侧想看懂/改内部实现是可行的，MIPI/HDMI 核只能改参数。

### 11.4 本工程与"纯 IDE 流程"的两点差异

1. **生成的 `.v` 直接放在 `ip/` 下并写进 `design_file` 列表。**
   参考工程的习惯是把 IP 的 .v 拷到 `rtl/` 再手工维护。放在 `ip/` 更符合
   Efinity 的组织方式，IDE 会把它当 IP 实例显示；重新 Generate 会自动生效。
2. **`HexFile_Path` 用项目内相对路径**（`embedded_sw/riscv_soc0/camera_i2c.hex`），
   不是绝对路径 —— 保证 clone 到别人机器上重新生成 IP 时路径仍然有效。
