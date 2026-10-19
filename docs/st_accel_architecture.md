# ST 加速器架构决策

日期：2026-10-13  
目标器件：Efinix Titanium Ti60F225  
基线模型：`fpga_st_train` 导出的 `ink_dw` W8A8 manifest

## 决策

继续使用 nngen 的 manifest、定点参考和 `st_stream` 的逐层折叠规划作为软件工具链基础；不把当前静态“每层一套 PE”的整网流式 RTL 直接接进主 FPGA 工程。主线加速器采用**可配置的共享 MAC 引擎 + tile 调度 + 局部算子融合**：

1. 每层由描述符指定算子、形状、步幅、padding、量化参数和并行折叠度。
2. 卷积乘加阵列跨层复用。层内以输入通道 SIMD、输出通道 PE 和空间像素并行度决定展开；未展开维度分时复用。
3. 3×3 depthwise / dense 卷积用行窗口缓冲；1×1 pointwise 不建空间窗口。
4. 优先融合相邻 DW→PW、短残差支路和同一 tile 内可复用的算子，减少中间特征图往返 DDR。
5. 大特征图、长跳连以及超出片上预算的中间结果放 DDR；BRAM 只做容量明确的 tile 双缓冲、行缓存和小 FIFO。
6. 小通道的 head、bias/requant 等适合并行的短路径可专用或多 lane 展开；不对整网所有通道、像素和层同时做空间展开。

这保留 `st_stream` 的流式局部性，但把它从“每层硬件永久占位的流水线”改成可调度的 tile 数据流。`st_stream` 现有生成器适合作为折叠/流控/位精确组件来源和性能探索基线，不应被视为已完成的板级系统。

## 10 fps / 480p 目标的修正

按用户确定的目标改为 640×480、10 fps。完整模型约需 19.16 GMAC/s。100 MHz 下若按 EFX_DSP48 DUAL 的 2 个 int8 MAC/周期估算，MAC 理论下限约 96 个 DSP；考虑 9-bit 残差通路、调度泡、requant、DMA 和 tile 边缘，架构探索预算先设为约 110–120 个 MAC DSP，最终以 Ti60 综合映射为准。整工程基础资源约占 8 DSP，尚需给 SoC/视频和外围逻辑留出余量。

真实 `ink_dw` manifest 已通过 `st_stream/gen_stream.py` 在 640×480、10M 周期预算下生成。自动折叠计划瓶颈 9,866,272 cycles，估算 113 MAC DSP + 29 requant lane；其每层硬件并行流水方式虽然周期刚好接近预算，却估算约 1.08 MB 的行缓存/FIFO/权重，超出可用片上 RAM 一个数量级。把周期压到 9M 后，该生成器为各层分别放置硬件，合计约 184 MAC DSP + 31 requant lane，同样不可接受。由此确认：只增加静态流式生成器的 per-layer 展开配置，还不足以交付目标；生产架构必须让**多个层复用同一 MAC 引擎**，并让生命周期跨 tile 的数据走 DDR。

初始共享阵列目标设为 110–120 个 MAC lane 的 DSP 映射预算，requant 采用按输出速率共享的串行单元；层 descriptor 选择 SIMD/PE/tap 展开，调度器串行执行 layer/tile。DW→PW 和同 tile 内短残差仍做局部融合，减少 DDR 流量。10 fps 是性能目标而非已证明结果：tile 引擎的 DDR 有效带宽和 DDR/BRAM 重叠必须通过仿真、综合和板测验证。

## 资源与吞吐依据

最近的整工程 Ti60F225 布局报告 `outflow/fpga_src.place.rpt`：23,259/60,800 XLR、206/256 Memory Block、44/160 DSP。当前 ST 相关模块占有部分资源；以报告和 nngen planner 的统计口径，移除旧 ST 模块后约有 88 个 Memory Block 可重新分配，DSP 预算上限约 152 个（实际还需给时钟、SoC 和视频链路留余量）。片上 RAM 是架构约束，不能把“DSP 尚有空位”推导成可以堆叠整层流水线。

对完整 `ink_dw` 在 640×480 的 planner 估算为约 1.916 GMAC/帧、50,144 B 权重。30 fps 需要 57.5 GMAC/s。若 MAC 使用 100 MHz `core_clk`，即使把可用 152 个 DSP 全部按每拍 2 个 int8 MAC 计算，理论值也只有 30.4 GMAC/s，尚未扣除控制、访存、填充、requant 和空泡；因此完整模型不可能在当前 100 MHz 配置下达到 480p30。即使把时钟升到 148.5 MHz，理想峰值约 45.1 GMAC/s，仍低于需求。达到目标需要显著降低模型 MAC 数、降低推理分辨率/帧率，或改变任务定义；单纯提高 PE 展开度不能解决理论吞吐不足。

planner 对逐层 DDR 回写估算 108.7 MB/帧（假设 DW→PW 融合），30 fps 约 3.26 GB/s，高于当前帧缓冲共用 DDR 的可用带宽假设。另一方面，完整全网流式估算片上约 1.1 MB，而可分配 BRAM 约 88 KiB。两端都不可直接采用：逐层全量 DDR spill 带宽过大，全网长 FIFO/skip 流式则片上存储超预算。因此 tile 内融合、跨 tile/长距离特征图外存是折中主线，并需用 DDR 实测带宽验证 tile 大小和复用策略。

以上是模型运算量和当前资源数据给出的**架构上限判断**，不是板上 fps 结论。planner 的 DDR 有效带宽、融合流 FIFO 深度和综合资源还需用整工程实测校准。

## 每层展开策略

| 层/算子 | 数据通路 | 优先展开维度 | 复用与存储 |
|---|---|---|---|
| 3×3 stem / 普通卷积 | 3 行窗口 + MAC | 小输入通道全展开；输出 PE 按预算展开 | 像素流式窗口，权重驻留；输出通道不足时分时累加 |
| 3×3 depthwise | 每通道独立 3×3 MAC | tap 维度适度并行，通道 SIMD 依据 RAM/DSP 预算 | 行缓冲复用相邻像素；DW 与后继 PW 尽量同 tile 融合 |
| 1×1 pointwise | 通道点积 | 输出通道 PE 优先，输入通道 SIMD 次之 | 空间像素按 tile 流入；过多 IC 分时累加，避免全 OC×IC 展开 |
| 残差 / skip add | 对齐逐元素加法 | tile lane 并行 | 短支路用 BRAM/FIFO；长 skip 保存在 DDR，回读与主支路配对 |
| upsample / head | nearest + 低通道卷积 | head 的少量输出通道可全展开 | 避免为全分辨率长支路建深 FIFO；按 tile 输出 |

对于连续像素流，行缓存只保存卷积窗口需要的行；不应为整个层保存全部激活。对于无法融合或有长生命周期的激活，使用 DDR 的 ping-pong tile 区；每个 tile 的 halo 由算子 receptive field 推导，并纳入 descriptor / host planner。

## NNgen 规划器接口建议

现有 `gen_stream.py` 已支持逐层自动选择 `SIMD/PE/TP`，并可用 `STS_FORCE` 强制指定部分层的折叠度；但其目标主要是让独立流式层满足周期预算并最小化乘法资源代价，尚未联合优化跨层资源复用、BRAM bank/深度、DDR 流量和时钟域。因此下一步不需要重写 NNgen 前端，而是把每层策略显式化并生成可复现的 plan：

```json
{
  "layer": "enc.0.dw",
  "engine": "shared_conv0",
  "schedule": "tile_stream",
  "simd_ic": 8,
  "pe_oc": 1,
  "parallel_taps": 3,
  "spatial_lanes": 1,
  "buffer": "line",
  "fuse_next": true
}
```

每层可配置：`engine/group`（共享哪套 PE）、`SIMD_IC`、`PE_OC`、`TP`、`spatial_lanes`、`tile WxH`、`buffer=line|bram|ddr`、融合边界和驻留权重策略。planner 对每个候选方案报告预计周期、DSP、BRAM 的**实际 bank 深度/宽度映射**、权重容量、DDR 读写字节数及 slack；超预算时明确报错，而不是静默选择全展开的兜底方案。`STS_FORCE` 保留为快速实验入口，最终配置落到 manifest 旁的版本化 plan 文件。

## 实施顺序

1. 固定 `ink_dw` manifest、权重哈希、输入图和量化参考，建立 host 端逐层 golden。
2. 在当前加速器加入每层/每 tile cycle、MAC busy、输入等待、输出等待、DDR stall 计数，首先取得可靠的板上基线。
3. `st_stream` 已增加 per-layer fold JSON override；`configs/ink_dw_480p10.json` 固定当前真实 manifest 在 480p/10 fps 周期预算下的折叠配置。将该 plan 与资源、RAM/DDR 成本关联，不能只看单层周期。
4. 抽取统一的共享 MAC/累加/REQUANT engine 和 3×3 行窗口单元，完成 tile 级仿真与固定向量比对。
5. 接 AXI M1 双缓冲 tile DMA，测量与 frame_buffer 并发时的持续读写带宽；验证一组 tile 内 DW→PW 融合。
6. 只有整工程 P&R、AXI 仿真和板上图像/周期/校验值均通过后，才扩大分辨率和追求帧率。

## 当前分支结论

可以继续从 nngen 的 `st-stream` 分支开发，但要将其定位为新架构实验分支/代码来源，不直接切换或覆盖 `fpga_src` 的工作区。该分支已有层折叠生成器、SRL FIFO、同步 ROM、位精确核仿真和整机仿真框架；它的 `st_stream_sys` 尚未进入 fpga_src 工程，也没有 Ti60 整机综合和板测。已记录的 30.6 fps 是合成权重 st480a 的整机 RTL 仿真结果，不能代表真实训练模型或当前板卡性能。
