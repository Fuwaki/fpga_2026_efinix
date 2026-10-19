# 风格迁移硬件接入进度

日期：2026-10-09（Asia/Shanghai）  
工程：`/data/competition/2026fpga/fpga_src`  
板卡：Titanium **Ti60F225** + SC431HAI → HDMI（摄像头通路保持不变）

## 1. 盘点结论

### 工具与板卡
| 项 | 值 |
|----|-----|
| Efinity | `/opt/efinity/2026.1`（2026.1.132），CLI：`/usr/bin/efx_run` |
| 一键构建 | `tools/build_all.sh --fpga-only` → map / interface / pnr / pgm |
| USB | 可见 FT4232H（`0403:6011`）；本阶段只综合+出 bit，未烧录 |

### 接入前资源（摄像头→HDMI 基线）
| 资源 | 已用 / 总量 | 占用 |
|------|-------------|------|
| XLR | 31708 / 60800 | 52.15% |
| Memory Blocks | 166 / 256 | 64.84% |
| DSP | 9 / 160 | 5.62% |

剩余约：29.1k XLR、90 RAM、151 DSP。

### SoC / 总线
- Sapphire `riscv_soc0`：100 MHz，DDR=0 / AXISlave=0。
- APB0 基址 **IO_APB_SLAVE_0_INPUT = 0xF810_0000**。
- `userInterruptA` ← st_accel IRQ。
- DDR3 AXI（128-bit）由 **frame_buffer 独占**；ST 挂 DDR 需 AXI 互联。

### 加速器候选（结论）
| 候选 | 结论 |
|------|------|
| 完整 nngen ST IP | 过重，难与摄像头并存 |
| `engine_top` | ~25k XLR，装不下 |
| 自研 DSP PE（本路径） | 可行；用硬 DSP 原语 |

## 2. Phase-1（已完成）— stub

- `st_accel_stub.v`：APB + 8 路推断 MAC + IRQ，P&R 通过。
- 资源：XLR 33893（+2185）、DSP 17（+8）、RAM 166。
- VERSION `0x53540001`。日志：`docs/st_synth_fpga_only.log`。

## 3. Phase-2（进行中）— 硬 DSP 卷积 PE + 硬件层序列器

### DSP / IP 结论
- Efinity IP Catalog **没有**独立 Multiplier IP。
- Titanium 硬乘加原语（Quantum Titanium Primitives UG）：
  - EFX_DSP48（NORMAL 19x18 / DUAL / QUAD / BFLOAT）
  - EFX_DSP24（DUAL 下一路 8x8；两颗 DSP24 可打进同一物理 DSP）
  - EFX_DSP12（QUAD 4x4）
- 文档：`/opt/efinity/2026.1/doc/pdf/efinity-quantum-ti-primitives-ug.pdf`
- 本阶段：**显式例化 EFX_DSP24**（`rtl/st_accel/efx_mac8.v`），N_SEL=CONST0 纯乘，PE 侧累加。

### RTL
| 文件 | 作用 |
|------|------|
| `rtl/st_accel/efx_mac8.v` | EFX_DSP24 int8xint8，流水线 LAT=3 |
| `rtl/st_accel/st_accel.v` | APB 外设 + 16 路 PE + 片上 X/W/Y + **硬件层序列器** |
| `rtl/st_accel/st_accel_stub.v` | Phase-1 保留（已移出工程 xml） |

### 架构选择（已拍板）
- **硬件自序列化一层**：CPU 经 APB 写 X/W、配 CFG_SHAPE/CFG_MISC、写 START；硬件遍历整层 3x3 conv（pad=0,stride=1）→ 片上 Y → DONE/IRQ。
- 上限：H/W/IC/OC <= 16，K=3，N_PE=16（期望约 8 物理 DSP block）。
- 片上 **通道分 bank**（每 lane 单口），避免扁平多口读。
- **未接 DDR AXI**；IN_ADDR/OUT_ADDR 预留。

### 寄存器（APB0 + 偏移）
| 偏移 | 名 | 说明 |
|------|----|------|
| 0x00 | VERSION | 0x53540002 |
| 0x04 | CTRL | START W1P, IRQ_EN, SOFT_RST |
| 0x08 | STATUS | BUSY, DONE |
| 0x0C | STATUS_W1C | W1C DONE |
| 0x10 | CYCLES | 上次周期数 |
| 0x14 | MAC_ACC | 末像素累加（debug） |
| 0x18/1C | IN/OUT_ADDR | DDR 预留 |
| 0x20 | CFG_SHAPE | {OC,IC,W,H} |
| 0x24 | CFG_MISC | QSHIFT[3:0], RELU[8] |
| 0x28 | MEM_CTRL | bank 0=X 1=W 2=Y |
| 0x2C | MEM_ADDR | 字节地址 |
| 0x30 | MEM_DATA | X/W: 写 [7:0] 后地址+1；Y: 写 32-bit 后+4 |
| 0x34 | DBG_STATE | FSM/坐标 |

### DDR 计划（本 milestone 不实现）
1. frame_buffer 与 ST 之间加 AXI 互联/仲裁。
2. APB 描述符 + 硬件 DMA：tile → 片上缓冲 → 写回。
3. 仅当 16x16 片上不够目标分辨率时再做。

### 综合结果（P&R PASS，未烧录）
- 命令：`tools/build_all.sh --fpga-only`
- 日志：`docs/st_synth_phase2.log`
- bit：`outflow/fpga_src.bit` / `.hex`

| 阶段 | XLR | RAM | DSP |
|------|-----|-----|-----|
| 基线（摄像头） | 31708 (52.15%) | 166 (64.84%) | 9 (5.62%) |
| Phase-1 stub | 33893 (55.75%) | 166 | 17 (10.62%) |
| **Phase-2 PE** | **49343 (81.16%)** | **202 (78.91%)** | **25 (15.62%)** |
| delta vs Phase-1 | +15450 | +36 | +8 |
| 剩余 | ~11.5k | 54 | 135 |

- `hier_util`：`u_st_accel` ≈ 2207 XLR、36 Memory、16 DSP24（显式 `EFX_DSP24`，打包进约 8 个物理 DSP block）。
- **调度决策：保留硬件层序列器**（资源仍有余量；未退回 CPU-per-layer）。
- u_st_accel itself ~2207 XLR; chip +15k vs Phase-1; hier_util shows inst_gamma_correction at 25117 XLR (long-standing async-read->logic warning; check if report/infer regression).
- 下一刀：APB 地址解码去除法改位移；可选 N_PE=8 再量；DDR AXI 仍仅计划。

## 4. 相关路径

- 加速器：`rtl/st_accel/`
- 顶层：`rtl/fpga_src_top.v`（`u_st_accel`）
- 资源：`outflow/fpga_src.place.rpt`、`outflow/fpga_src.hier_util.rpt`
- nngen 黄金：`../nngen/examples/st_manifest/`


## 5. Phase-3 — 视频通路接入（camera → ST → HDMI PiP）

日期：2026-10-09 Asia/Shanghai

### 目标与取舍
- **可见端到端**优先于完整 16 层风格迁移网。
- 本阶段：全分辨率 camera→HDMI 保持；从 post-saturation RGB **下采样 16×16 luma** → `st_accel` 硬件 3×3 **sharpen** → 左上角 **112×112 PiP**（×8 最近邻）+ 青色边框。
- **未接 DDR AXI 互联**：16×16 片上足够；512-bit AXI 仲裁在 XLR≈81% 时风险高。DDR 接入列为 Phase-3b。

### 新增 RTL
| 文件 | 作用 |
|------|------|
| rtl/st_accel/st_vid_pipe.v | 采集 / CDC / 踢加速器 / PiP 叠加 |
| st_accel.v（扩展） | hw_x_* / hw_load_w / hw_start / hw_y_* 视频口；内置 sharpen 权重 |

### 数据流
sat RGB (hdmi_tx_slow_clk) → st_vid_pipe 采集 → TDP CDC → core_clk 填 X / load W / START
→ st_accel HW 序列器 → 拷 Y → TDP → PiP 替换 dvi_encoder 输入

### DDR 计划（Phase-3b，未实现）
1. 2:1 AXI 读写仲裁（frame_buffer 高优先，st_accel 低优先）。
2. st_accel 加 512-bit AXI master：tile DMA 读写 DDR。
3. 触发条件：要上 32×32+ 或多层权重超片上容量。

### 综合结果（P&R PASS，未烧录）
- 日志：docs/st_synth_phase3_vid.log
- bit：outflow/fpga_src.bit

| 阶段 | XLR | RAM | DSP |
|------|-----|-----|-----|
| Phase-2 PE | 49343 (81.16%) | 202 (78.91%) | 25 (15.62%) |
| Phase-3 vid pipe | 49288 (81.07%) | 204 (79.69%) | 28 (17.50%) |
| delta vs Phase-2 | -55 | +2 | +3 |

- 视频桥几乎不吃 XLR（TDP BRAM + 小 FSM）；DSP +3 为打包抖动。
- 未烧录：需板上确认后再 flash；bit 已生成可供 JTAG。
- 可见效果：左上 112x112 青色边框 PiP = 全帧下采样 16x16 luma 经 st_accel 3x3 sharpen。

## 6. Flash (2026-10-09 Asia/Shanghai)

- USB: FT4232H `0403:6011` present.
- **JTAG program SUCCESS** (`efx_run --prj fpga_src.xml -f program --pgm_opts mode=jtag`):
  - Device ID `0x10660A79`, bit `outflow/fpga_src.bit` @ 3 MHz
  - Log: `docs/st_flash_jtag.log`
- SPI via jtag_bridge **FAILED**: Unsupported JTAG Bridge version 0.0 (needs bundled bridge image). Log: `docs/st_flash_spi.log`
- Implication: current image is in FPGA SRAM — visible now; **power-cycle reloads old SPI image** until SPI is updated.

### What to see on HDMI
- Full camera→HDMI live view (unchanged).
- Top-left **112×112** box with **cyan border**: false-color PiP of 16×16 luma after st_accel 3×3 sharpen (R=result, muted G/B).


## 7. DDR arbiter HDMI grey/flicker fix (2026-10-09 21:30 Asia/Shanghai)

**Symptom:** After first DDR-arbiter flash (`st_synth_ddr_arb` / `st_flash_ddr_arb`), HDMI full grey / flicker — camera path dead.

**Cause:** `axi2_pri_arb` used a *registered* AW/W/B/AR/R path with pulse-style ready/valid. That dropped frame_buffer DDR beats (W valid cleared on ready, R beats registered+cleared), so FB could not sustain camera↔DDR traffic.

**Fix:** Rewrote `rtl/st_accel/axi2_pri_arb.v` as lock-based grant + **combinational mux** (M0=FB priority, M1=ST). Kept arbiter in top (FB→M0, ST idle→M1, slave→ddr3). Restored Phase-3 `st_vid_pipe` TILE=16 + Phase-3 `st_accel` (AXI ports present but idle-tied) for stable PiP while M1 stays quiet.

**Build/flash:** `docs/st_synth_arb_fix.log` PASS; JTAG `docs/st_flash_arb_fix.log` SUCCESS (ID 0x10660A79). Resources: XLR 22600 (37.17%), RAM 206 (80.47%), DSP 27 (16.88%).

## 8. Phase-4 — AXI M1 + W8A8@32 golden PiP (2026-10-09 CST)

### Goal
Wire `st_accel` as AXI M1 through fixed `axi2_pri_arb` (M0=FB > M1=ST), show
SW-matched W8A8 Style Transfer (vangogh) at **32×32** on HDMI as **256×256** PiP
(SCALE=8), without breaking the camera/FB path.

### Architecture
- **Arbiter:** lock + comb mux (`axi2_pri_arb.v`) — unchanged from HDMI-restore fix.
- **st_accel AXI:** `st_axi_mm` on M1. Default **idle** (no auto DDR traffic) so FB
  stays healthy. Weight bootstrap = APB@0x30 byte-gather → AXI write beats to
  `W_BASE=0x0100_0000`. No on-chip weight ROM (async 16KB `wboot` mapped to logic
  and blew XLR to ~200k; removed). Full ~376KB weights stay in DDR; zero-pad OK.
- **Compute:** DSP PE array + sharpen sequencer still in RTL; this build’s PiP does
  **not** overwrite display BRAM (COPYY off). Visible ST = SW golden in BRAM.
- **Video:** `st_vid_pipe` TILE=32 SCALE=8; TDP BRAMs `st_golden_32{r,g,b}.hex` from
  `nngen/.../build_w8a8_vangogh/golden_ng_eval.npy` (×2 for 8-bit). Cyan border.
- **SW match:** same tensor as golden_ng_eval.npy (vangogh W8A8 @32).

### Resources (place.rpt)
- XLR **21253 / 60800 (34.96%)**
- Memory **171 / 256 (66.80%)**
- DSP **8 / 160 (5.00%)**
- Synth: `docs/st_synth_phase4_32.log` — map/interface/pnr/pgm **PASS**
- Note: PE DSP/BRAM were DCE’d in this golden-PiP-first build (pe_ce dangling);
  AXI M1 + arbiter + golden PiP are live. Restoring live PE for on-device ST is next.

### Flash
- JTAG: `docs/st_flash_phase4_32.log` — SUCCESS, Device ID `0x10660A79`
- Bit: `outflow/fpga_src.bit`

### What you should see
- Full-screen live camera (FB path intact).
- Top-left **256×256** PiP, cyan border, van Gogh–styled color image (32×32
  upscaled) matching SW W8A8 golden — object-visible at this res.
- No grey/flicker.

## 9. Phase-5 — Live camera → DSP PiP (2026-10-09 CST)

### Goal
PiP **follows the camera** through kept EFX_DSP24 PE array (not static golden).

### Honest scope (subset, not full W8A8 ST)
Full vangogh W8A8 @32 is ~16 layers / ~376KB weights / ~5M nngen cycles — needs DDR
weight+act DMA. This release is a **visible live stylizer subset** on the same DSP PE
path to prove camera→accel→PiP:

1. Capture 32×32 RGB from HDMI camera path  
2. Per channel, 2-pass 3×3 on 16× EFX_DSP24: **blur** then **emboss+palette bias**
   (yellow/blue van Gogh–ish push) + residual  
3. Write Y planes back to PiP BRAMs every processed frame  

Gold border on PiP = live mode (Phase-4 was cyan + static golden).

Full ST (DDR `st_axi_mm` weight gather @APB 0x30, layer_desc, act ping-pong) is next.

### Latency / fps (estimate @ core_clk 100 MHz)
- Per tap ≈ 1 + (DSP_LAT+3) ≈ 7 cycles; 9 taps/pixel → ~63 cyc/pix  
- 32×32 × 63 ≈ 65k cyc/pass; ×2 passes ×3 ch ≈ **390k cyc ≈ 3.9 ms**/frame  
- Headroom for 30–60 fps camera; pipe processes each captured tile when idle  
- Measured proxy: APB `CYCLES` (0x10) after a run  

### Resources (place.rpt)
- XLR **38261 / 60800 (62.93%)** — elevated: async `xmem` slice mapped to logic (fix later)
- Memory **176 / 256 (68.75%)**
- DSP **23 / 160 (14.38%)** — **EFX_DSP24 ×19** (PE kept; was 8 / DCE’d in Phase-4)
- `u_st_accel`: ~15 DSP, PE path live (`docs/st_synth_phase5_live.log` PASS)

### Flash
- JTAG SUCCESS — `docs/st_flash_phase5_live.log`, Device ID `0x10660A79`
- Bit: `outflow/fpga_src.bit`
- Arbiter unchanged (lock+comb, M0=FB > M1=ST idle-unless-APB)

### What you should see
- Full-screen live camera (FB OK)  
- Top-left **256×256** PiP with **gold** border  
- PiP content **moves/changes with the camera** (styled blur+emboss, not photo-identical)  
- If PiP frozen again → regression; re-check COPYY / `hw_done` path

## 10. Phase-6 — Near-full W8A8 ST live PiP (2026-10-09 CST)

### Goal
Camera → real vangogh **W8A8** weights through DSP `st_accel` → HDMI PiP that tracks
the camera with a true style-transfer look (not Phase-5 blur/emboss).

### What is implemented (honest)
**Near-full** tiny-ST graph with **real** `fpga_st_train` W8A8 vangogh weights:

| Stage | Op | Notes |
|-------|----|-------|
| enc.0 | conv 3→32, k3,s1 | real weights |
| enc.1 | conv 32→64, k3,s2 | real weights |
| *(enc.2)* | **avg-pool 2× shortcut** | **not** real enc.2 conv (BRAM) |
| res.0..3 | **bypassed** | residual blocks skipped |
| upsample | nearest 2× | before each up3 |
| up3.0 / up1.0 / up3.1 / up1.1 / head | real W8A8 | |

Weights on-chip ROM (`st_w8_sel_weights.hex`, **44048 B** from `weights.bin`).
Acts ping-pong in on-chip banks. `st_axi_mm` M1 still wired (idle) for future DDR
full-weight/act spill. Arbiter unchanged (M0=FB > M1).

### Resolution
- Infer **16×16** (TILE=16) — BRAM fit; PiP **256×256** (SCALE=16).
- Purple PiP border = Phase-6 W8A8 mode.

### Latency / fps (estimate @100 MHz)
- Per out-pixel: ~9 taps × (16 loads + MAC drain≈6) ≈ 200 cyc; ×IC/16 tiles
- Rough order **tens of ms**/frame at 16×16 near-full path → **~few–15 fps** processed
  (camera frames skipped while `hw_busy`). Not full nngen 5M-cyc@32.

### Resources
- XLR **22806 / 60800 (37.51%)**
- Memory **239 / 256 (93.36%)**
- DSP **40 / 160 (25.00%)** — EFX_DSP24 kept
- Synth `docs/st_synth_phase6_w8.log` PASS; flash `docs/st_flash_phase6_w8.log`

### What you should see
- Live camera full-screen (FB OK)
- Top-left **256×256 purple-border** PiP that **moves with the camera** with
  van Gogh–styled colors from real W8A8 encoder/decoder/head weights
- Look will differ from SW golden@32 (res 16, enc.2 pooled, residuals off)

### Next (full ST)
- DDR-resident full 376KB weights + residual layers + real enc.2
- Act ping-pong in DDR to free BRAM for 32×32
- Fix bias/requant multi-beat load precision if artifacts remain

## 10b Phase-6b purple PiP white/black — root cause & fix (2026-10-09)

**Symptom:** Purple-border PiP showed a small white block; the rest was black. HDMI passthrough OK.

**Root causes (stacked):**
1. **virt_up dst size bug (primary):** After enc.1 (8×8), layer up3.0 set `need_up` and virtually presented phys 8×8 as 16×16 for reads, but `dst_h/w` stayed 8. Head therefore wrote only 8×8×3 bytes into `out_pix`. COPYY still walked 16×16×3=768 addresses → unread locations read as 0 → black field; the 8×8 island often clamped bright → “small white block”.
2. **COPYY overwriting camera prefill:** Prefill wrote live camera into Y planes first (correct follow), then COPYY replaced the full PiP with sparse ST output → black dominated.
3. **Bias/requant BRAM latency:** Multi-beat bias/M load captured RQ lo/hi on the wrong beat (hi into lo). Guard now waits one cycle per beat and falls back to M=256 when M==0.
4. **Earlier (already patched):** 32-wide capture addrs at TILE=16; planar `in_act` packing; `need_pool=0` (pool would shrink to ~4×4).

**Fixes applied:**
- `st_accel.v` S_SETUP: on `lneed_up`, set `dst_h/w <= src<<1` (same old-src RHS as virt src enlarge).
- `st_accel.v` S_BIASLD2: correct 1-cycle BRAM latency for bias bytes + requant M; M==0 → 256.
- Keep camera PRE_R/G/B then ST COPYY; TILE=16 packing; no pool; HDMI/axi2_pri_arb untouched.

**Expected after reflash:** Purple PiP tracks camera (prefill). When ST finishes, full 16×16 Y overwrite — style may be partial/noisy but not black field.

**Build/flash (Phase-6b):**
- Synth `docs/st_synth_phase6b_fix.log` — map/interface/pnr/pgm PASS
- JTAG `docs/st_flash_phase6b_fix.log` — SUCCESS, Device ID `0x10660A79`, bit `outflow/fpga_src.bit` @ 3 MHz
- Arbiter unchanged (lock+comb, M0=FB > M1). HDMI path not touched.

## 10c Phase-6c purple PiP vertical line (2026-10-10 CST)

**Symptom:** After 6b, purple PiP tracked camera but showed a thin vertical line slightly left of center.

**Root cause:** PiP Y-plane TDP BRAM is synchronous (1-cycle read). Display used `vid_y_raddr<= {sy,sx}` and `out_r<=yr` in the **same** cycle, so each physical column showed the **previous** column’s texel. At every SCALE tile boundary (`px % 16 == 0`) that injects a 1px ghost of the left tile; the seam near image center (px≈128, sx 7→8) is the most visible “mysterious vertical line”. Not a capture/COPYX packing bug.

**Secondary:** COPYY assumed 1-cycle `hw_y_data` but `out_pix → out_rdata_m → hw_y_data` is 2 cycles (RGB plane scramble on ST overwrite).

**Fix:** Pipeline overlay 1 cycle (issue addr + pend flags; next beat emit yr/yg/yb or delayed passthrough). COPYY waits 2 beats before first write. HDMI/arbiter untouched.

## 10d Phase-6d ink_dw switch + vertical-line fix flash (2026-10-10 CST)

**Phase-6 was dense `tiny` vangogh subset** (`st_w8_sel_weights` from `runs/vangogh/quant/w8a8`, ~44KB). User priority: smaller DW net.

**Now:** `tiny_dw` **ink_dw** W8A8 exported via `scripts/ptq.sh runs/ink_dw w8a8` → `runs/ink_dw/quant/w8a8/` (weights.bin **50144 B**, 29 layers). On-chip subset **8096 B** (skip enc.1 + all residual blocks):

| idx | layer | notes |
|---|---|---|
| 0 | stem 3→32 dense | |
| 1–2 | enc.0 dw/pw s2 | →8×8×64 |
| 3–5 | up3.0 dw/pw, up1.0 | stay 8×8 |
| 6–8 | virt_up + up3.1 dw/pw, up1.1 | →16×16 |
| 9–10 | head dw/pw | RGB out |

**RTL:** `st_layer_sel.is_dw`; `st_accel` DW path (1-ch×3×3, weight `oc*k*k`); head at layer 10. **Vertical line (10c):** PiP BRAM 1-cycle align in `st_vid_pipe` + COPYY 2-cycle fix. HDMI/axi2_pri_arb untouched.

**High-res realtime ETA (plan):**
1. ~~Vertical seam + ink_dw bring-up @16~~ (this flash) — hours
2. Add enc.1 + 1–2 residual DW blocks @4×4 + skip-add — **1–2 days** (BRAM OK at 4×4)
3. Second upsample + full 29-layer ink_dw on-chip (50KB weights fit) — **2–3 days**
4. TILE 32–64 with DDR act spill (M1 AXI already wired idle) — **~1 week**
5. Realtime ≥30 fps @ ≥256: needs DW PE throughput + tile pipeline overlap; ballpark **2–3 weeks** calendar if DW path stays primary (dense was a dead-end for realtime).

**Build/flash (Phase-6d):**
- Synth `docs/st_synth_phase6d_inkdw.log` — map/interface/pnr/pgm PASS
- JTAG `docs/st_flash_phase6d_inkdw.log` — SUCCESS, Device ID `0x10660A79`, bit `outflow/fpga_src.bit`
- Export: `fpga_st_train/runs/ink_dw/quant/w8a8/` (PTQ calibrate+export-int8; eval skipped — no demo_inputs)

