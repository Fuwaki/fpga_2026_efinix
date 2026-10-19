# ST 480p30 流式架构: 总结 (2026-10-11 13:00)

> 本文档只记录**实测**数字 (Verilator 仿真 / Efinity 综合+布局布线报告); 生成器估算会标为"估算".
> 基线 fpga_src `main` 0864cf4 (ink_dw 画中画可用版本) **未改动**. 全程未烧写板子.

## 1. 做了什么
nngen `examples/st_stream` (分支 `st-stream`): 层融合流式 CNN 生成器, 输出可综合 Verilog.
- `gen_stream.py`: 读 w8a8 manifest, 按目标帧周期 T 给每层选折叠 (SIMD/PE/TP), 生成 `sts_top.v` + 权重 ROM hex. 一层一个模块, valid/ready 流水, 行缓冲 3x3 窗口, 残差分支 FIFO 按仿真实测深度定.
- `rtl/sts_lib.v`: 手动例化 EFX_DSP48 (DUAL 模式每 DSP 2 个 int8 乘法; 9-bit 输入时 1 个), fx requant (1 DSP/通道, 串行共享), SRL8 小 FIFO, 同步宽字 ROM, 非 2^n 深度 FIFO.
- `stref.py`: intref.rs 的 numpy 位精确移植 + "fx" requant 语义. `tb/`: Verilator 测试台, 逐层二分 (bisect.sh), 综合脚本 (synth.sh/mkproj.sh/rpt.py).
- `mkarch.py`: 生成合成权重的候选小网络 (只用 ink_dw 已有算子), 用于在不训练的情况下评估资源. `stripe.py`: 列条带切分 + halo 计算, 证明与整帧位精确.
- `tb/sys/st_stream_sys.v`: 整机集成模块 (显示流采集 -> DDR -> 4 条带推理 -> DDR -> 画中画回显), 带 AXI DDR 模型的系统级测试台. **尚未放进 fpga_src 工程综合**.

## 2. 实测结果
### 2.1 仿真 (Verilator, 与 Python 位精确参考逐值比较)
| 设计 | 分辨率 | 结果 | 帧周期 (cycles) |
|---|---|---|---|
| ink_dw v1 (f32 精确 requant) | 40x20 | 1600/1600 位精确 | 63591 (瓶颈层理论值 90.6%) |
| ink_dw v2/v3 (fx requant) | 40x20 | 1600/1600 位精确 | 63592 / 64534 |
| st480a 条带核, T=1.25M | 256x480 | 245760/245760 位精确, 2 帧 | 1,599,404 (未达目标, 只有 78%) |
| st480a 条带核, T=1.0M (=a480_c150) | 256x480 | 位精确, 2 帧 | 1,182,856 |
| **整机 st_stream_sys + a480_c150** | 1080p60 显示 -> 640x480 | 采集==2x2 均值 (0 差), OUT==stref(整帧 640x480, 4 条带拼接) (0 差), 画中画==2x 放大 (0 差) | 相邻两帧完成间隔 4,855,455 vclk = 32.7 ms @148.5 MHz => **30.6 fps** |

### 2.2 综合 / 布局布线 (Ti60F225, I3)
| 设计 | DSP48 | RAM10 (/256) | XLR / LUT4 | Fmax | 备注 |
|---|---|---|---|---|---|
| fpga_src main 0864cf4 (整工程) | 44/160 | 206 | XLR 23.2k | core_clk 109 MHz | 其中 SoC 81, DDR 39, frame_buffer 28, st_accel 32, st_vid_pipe 6 RAM |
| ink_dw v1 40x20 | 158 (requant 占 102) | 474 | LUT 23k | - | map |
| ink_dw v2 40x20 | 101 | 331 | LUT 12.4k | - | map, P&R 失败 (RAM 超) |
| ink_dw v3 160x120 @30fps | 64 (+1 DSP24) | **413** | LUT 16.5k | - | map, RAM 超 256 |
| st480a 256x480 (RQ 未共享) | 106 | 101 | XLR 45.4k | 196 MHz | P&R |
| st480a 256x480 T=1.25M (v3) | 87 | 140 | XLR 33.0k | - | P&R; ROM 阈值调低后 RAM 增加 |
| **st480a 256x480 T=1.0M (a480_c150, 推荐)** | **96** | **110** | **XLR 32.1k** | **220.8 MHz** | P&R, 目标 148.5 MHz |
| st480a 256x480 T=0.667M (100 MHz 版) | 150 | 127 | XLR 46.0k | - | P&R, DSP 太多, 不采用 |

## 3. 关键结论
1. **ink_dw 原网络做不了 480p30 全片上流式, 瓶颈是存储不是 DSP.** 估算 640x480: 行缓冲 396KB + 分支 FIFO 737KB (其中长 skip 约 590KB) + 上采样 46KB + 权重 50KB ≈ 1.2MB; Ti60 RAM 共 256x10Kbit ≈ 320KB, 替换 st_accel 后可用约 88 块. 实测 160x120 就已要 413 块. 即使把长 skip FIFO 放 DDR, 160x120 仍需约 186KB (估算), 权重一项就约 40 块. => ink_dw 继续用 main 上的 DDR 逐层 tile 引擎 (st_accel).
2. **DSP 的真正大头曾是 requant.** v1 的 f32 精确 requant 每通道 4 DSP (102/158). 改为 fx requant (17-bit 归一化乘数 + 每通道移位, 1 DSP) 并按层输出速率串行共享后, st480a 的 requant 只需 22-26 DSP.
3. **fx requant 与 intref.rs (f32) 不完全一致**: 逐层约 1e-4 的值在 .5 舍入边界上差 1; ink_dw 整网 160x120 输出 PSNR 50.2 dB (vs intref f32). **若采用流式架构, 需要在 fpga_st_train 的 intref.rs 中同步实现 fx requant** (stref.rq_fx_params / rq_fx_vec 是规范, 实现约 20 行), 否则硬件与金标准不能逐位比对.
4. **480p30 可行路线 = 小网络 + 列条带 + DDR 帧缓冲**: 640x480 切 4 条, 条带宽 256, halo 48, 计算量 x1.6; 核跑在 hdmi_tx_slow_clk 148.5 MHz; 整机仿真实测 30.6 fps 且位精确.
5. **资源尚未放下**: a480_c150 单独 110 RAM, 加集成部分 (估算约 14 块, 128-bit FIFO 改 SRL 后) ≈ 124, 而预算约 88. 需要再省约 36 块 (见第 5 节).

## 4. 推荐的再训练网络 (480p30 方向, st480a 及其瘦身版)
st480a (本次评估用, 权重 26.6KB, 每层只用 ink_dw 已有算子: conv3x3, dw3x3, pw1x1, add, up2 最近邻):
```
stem   conv3x3 s2  3->16   relu        (H/2)
e1     dw3x3  s2  16, pw 16->32        (H/4)
e2     dw3x3  s2  32, pw 32->64        (H/8)
r0,r1  残差块 x2 @H/8: [dw3x3 64, pw 64->64] x2 + add
d0     pw 64->32, up2, dw3x3 32, pw(mix) 32->32   (H/4)
d1     pw 32->16, up2, dw3x3 16, pw(mix) 16->16   (H/2)
d2     pw 16->8,  up2, dw3x3 8                    (H)
head   pw 8->3
```
要点: (a) 去掉编码器到解码器的长 skip (存储占比最大); (b) 残差块只放在 H/8; (c) 解码器先 pw 降通道再上采样, 全分辨率只留 8 通道; (d) 不要 dense 3x3 (除 stem).
为放进 88 块 RAM 的建议瘦身 (未综合验证, 下一步): H/8 主干 64->48 通道 (省权重约 45% 及 H/8 行缓冲/残差 FIFO 约 1/4), 或残差块 2->1.

## 5. 未完成 / 待办
- [ ] **st_stream_sys 未接入 fpga_src 工程, 未做整工程综合/P&R.** 集成 RTL 和系统仿真在 nngen `tb/sys/` (位精确). 接入方式: 替换 u_st_accel + u_st_vid_pipe, 占用原 APB0 槽 (0xF810_0000) 和 axi2_pri_arb 的 M1 口, 核时钟用 hdmi_tx_slow_clk, DDR 缓冲默认 0x0400_0000 起 8MB (IN0/IN1/OUT0/OUT1), 不需要固件.
- [ ] RAM 超预算约 36 块. 可行手段: mvau 输入双缓冲 (sts_sdp, 19 块, 每个只用 1Kbit) 改移位寄存器; d2.dw 窗口缓冲按 RAM 形状选折叠 (-4); 集成中 3 个 128-bit 同钟 FIFO 改 SRL (-21, 已在 RTL 计划中); 网络瘦身 (第 4 节).
- [ ] T=1.25M 时实测只达 78% 吞吐, 现用 T x0.8 余量解决; 根因 (多级突发叠加) 未分析.
- [ ] intref.rs 同步 fx requant (第 3.3 节).
- [ ] 权重是合成的 (mkarch.py), 需要真实训练 st480a 类网络后重新生成.

## 6. 复现
```
cd nngen/examples/st_stream
python3 mkarch.py st480a arch/st480a --img <img>   # 合成权重 manifest
python3 gen_stream.py arch/st480a --res 256x480 --cycles 1000000 --out a480_c150
python3 tb/mkvec.py arch/st480a <img> 256x480 a480_c150/vec
bash tb/run_sim.sh a480_c150 256 480 2      # 核级位精确仿真
bash tb/synth.sh a480_c150 6.734 1          # Efinity 综合+P&R (1 = 做 P&R)
bash tb/sys/run_sys.sh a480_c150 $PWD/arch/st480a <img> sys_run1 6   # 整机仿真 + check_sys.py
# ink_dw: Q=/data/competition/2026fpga/st_work/fst/runs/ink_dw/quant/w8a8
python3 gen_stream.py $Q --res 40x20 --cycles 60000 --out v2_40x20 && bash tb/run_sim.sh v2_40x20 40 20 2
```
nngen 提交见 `st-stream` 分支; 原始日志在 `examples/st_stream/logs/` (未入库).

---
# 附: 过程日志 (原始记录)

基线(安全): fpga_src main 0864cf4 (ink_dw 画中画可用版本, 未改动); nngen st-stream f9d6848.
不烧写板子, 只做仿真 + 综合.

## 已完成 (01:50 前)
- nngen/examples/st_stream: gen_stream.py (FINN 式逐层折叠的层融合流式生成器), rtl/sts_lib.v (DSP48 DUAL 手动例化, 位精确 requant), stref.py (intref.rs 的 numpy 位精确移植), Verilator testbench.
- ink_dw 40x20 仿真: 1600/1600 位精确, 帧周期 63591 cycles (达到瓶颈层理论值 90.6%).
- ink_dw 640x480 计划 (T=5M cycles = 30fps@150MHz): 216 DSP48 + 37 requant, 片上存储 ~1.2MB (行缓冲 396KB, 分支 FIFO 737KB, 上采样 46KB, 权重 50KB).
  Ti60 只有 256 块 10Kbit RAM (约 320KB 原始容量, 当前设计空闲约 88 块), 结论: ink_dw 原网络 480p30 全片上流式 **不可行**, 瓶颈是存储(长 skip FIFO 和 64ch 残差块).

## 日志
- 01:50 修 sts_rq k0w 位宽 (综合 elaboration 报错, PW-S<9 时越界). 修复后 40x20 仍 1600/1600 位精确. 启动 40x20 综合.
- 02:00 v1 40x20 综合实测 (map): DSP48 158 (其中 requant 102 个! MAC 仅 56), RAM10 474 (mvau 权重/偏置 ROM 174, 小 FIFO 108, 分支 FIFO 82, dw ROM 51), LUT 23k.
  => 瓶颈不是 MAC, 而是 requant 乘法 (f32 精确仿真需 19x33 乘法 = 4 DSP) 和存储碎片化.
- 02:20 v2 RTL: (1) requant 改为 "fx" 语义: 17-bit 归一化乘数 + 每通道移位, 1 个 DSP48/通道 (stref.rq_fx_vec);
  逐层与 f32 比较翻转率 ~1e-4, 整网 160x120 输出 PSNR 50.2dB (vs intref f32), 若采用需在 intref.rs 同步改 requant.
  (2) <=16 深 FIFO 改为可寻址移位寄存器 (SRL8), 不占 RAM 块; (3) dw/mvau 权重与偏置 ROM 改为同步宽字 (每折叠一字).
  v2 40x20 仿真 1600/1600 与 fx 参考位精确, 帧周期 63592 cycles.
- 02:40-10:00 Mac 离线, 工作中断.
- 10:20 v2 40x20 综合实测 (map): DSP48 158->101, LUT4 23.0k->12.4k, RAM10 474->331.
  fpga_src 现状 (main 0864cf4 实测): RAM 206/256, DSP 44/160, XLR 23.2k/60.8k. 其中 SoC 81 块 RAM, DDR 39, frame_buffer 28, st_accel 32, st_vid_pipe 6.
  => 替换 st_accel+st_vid_pipe 后给 ST 的预算约 RAM 88 块, DSP ~150, XLR ~40k.
- 10:40 ink_dw 结论 (生成器估算): 160x120@30fps 全片上需 行缓冲 99KB + skip FIFO 129KB + 残差 FIFO 26KB + 上采样 12KB + 权重 50KB = 315KB;
  即使 skip 放 DDR 也要 ~186KB (>150 块), 权重本身就要 ~40 块. ink_dw 在 Ti60 上做全片上流式不可行, 只适合现有 DDR 逐层 tile 引擎 (main 上的 st_accel).
- 10:50 新增 mkarch.py (合成权重网络, 只用 tiny_dw 已有算子), stripe.py (列条带切分, Python 证明位精确).
  候选网络 st480a: stem 3x3 s2 3->16, e1 dw s2 + pw 16->32, e2 dw s2 + pw 32->64, 2 个残差块 @H/8 64ch,
  解码器每级先 pw 降通道再上采样: 64->32 (H/4 dw+mix), 32->16 (H/2 dw+mix), 16->8 (全分辨率 dw), head pw 8->3. 权重 26.6KB.
  条带: 4 条, halo 48 px, 条带宽 256, 计算量 x1.6, 与整帧参考逐像素一致 (stripe.py 实测 exact).
- 11:10 修 bug: mvau 直接接残差 add 输出 (9-bit) 时按 8-bit 截断 -> 加 L9 模式 (每 DSP 1 个乘法). 加 requant 串行共享 (sts_rqser).
  st480a 256x480 条带 (T=1.25M/条, 即 4 条=30fps@150MHz): Verilator 2 帧 245760/245760 位精确.
  单独综合+布局布线 (I3): DSP48 87, RAM10 140, XLR 33.0k, Fmax 196 MHz. 实测帧周期 1.60M cycles (目标 1.25M 的 78%), 待优化.
  nngen 提交 b28cc26.
  (更正: 上一行的 Fmax 196 MHz 来自 RQ 未共享版本; v3 版本 P&R 未单独记录 Fmax.)
- 11:40 a480_c150 (T=1.0M, 148.5MHz) P&R: DSP48 96, RAM10 110, XLR 32.1k, Fmax 220.8 MHz. 100MHz 版 (T=0.667M): DSP 150, RAM 127, XLR 46.0k.
- 12:10 整机 st_stream_sys 系统仿真 (1080p 显示流 + AXI DDR 模型): 采集/4 条带推理/画中画三项全部 0 差; 帧间隔 4.86M vclk = 30.6fps.
- 12:15-13:00 Mac 离线. 13:00 按要求收尾, 不再推进架构.
