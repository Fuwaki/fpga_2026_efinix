# 多风格部署：从训练检查点到板上切换

2026-11-03，feat/st-guided（82f4c34）。第一次部署的是 2 个风格：whitebox 和 sky。
模型来自 `fpga_st_train/experiments/tiny_dw_whitebox_sky_480p`。

**当前上板的模型**（feat/st-fmax，125 MHz）是 `fpga_st_train/runs/astra2/final_s3b`：3 个风格（0 bright、1 gouache、2 comic），带 packet_guide 结构，见第 8 节。

之前上板的是 `fpga_st_train/runs/codex_fix`：在上面那个模型的基础上做了权重空间编辑，见它的 README。
导出在 `st_work/cf`，`st_work/board_w8a8` 指向 `cf/w8a8`；第一版的导出还留在 `st_work/ms2`。
这版的 FiLM 共享常数是 sz26 sg24 sb20、c0 19846、kb900，联合校准时 scale 最多放大 1.3 倍。
板上 14.6 fps，`errors 0`。

方案选择见 docs/st-multistyle-packets.md。实际走的是方案 B：所有风格都放在片上，按 `ui_style` 选基址。
扩 FiLM ROM 需要的 RAM 不是靠缩小 OCR 换来的，而是把两个小 FIFO 改成 SRL 实现腾出来的（见第 4 节）。

## 1. 结果

| 项目 | 数值 |
|---|---|
| 风格 | 2 个（菜单显示 1–4：1、3 是 whitebox，2、4 是 sky） |
| 每帧周期（仿真） | 6,413,390，两个风格相同，和单风格版本一样 |
| 板上 | 14.8 fps，`errors 0`，摄像头不丢帧，切换后画面正常 |
| RAM10 | 254/256（251 + 3 DPRAM） |
| XLR | 59734/60800（98.25%） |
| 时序 | 所有时钟的 setup 和 hold 都满足 |

## 2. 模型里什么是共享的

训练端的 `tiny_dw_guided` 设 `styles=2` 时：

- **所有卷积共享**：PW、DW 和 requant 三个 ROM 只有一份。
- **每个风格一套**：主干 LN 的 γ、β（`trunk_norm`），以及 H/2 FiLM 的 MLP（`film_h2`）。
- **检查点的存法**：风格 0 的 LN 和 FiLM 放在普通字段里；风格 k（k ≥ 1）放在 `model.mpk` 的 `style_packets[k-1]` 里。

训练端的 `export-int8` 目前拒绝 `styles > 1`（`export_block_reason`）。为了不改训练仓库，部署时先拆成单风格模型，再在外面合并。

## 3. 导出流程

在 `/data/competition/2026fpga` 下：

```bash
T=fpga_st_train/experiments/tiny_dw_whitebox_sky_480p/trials/packets
W=st_work/ms2
PY=~/.cache/stvenv/bin/python          # 带 msgpack 的 venv（--system-site-packages）

# 1. 拆成单风格模型：风格 k 的包拷进普通字段，styles 改成 1
$PY fpga_src-st-accel/tools/st_split_styles.py --from $T --out $W        # → $W/style0, $W/style1

# 2. 每个风格单独校准
cd fpga_st_train
for k in 0 1; do
  ./target/release/fpga_st_train --device cpu calibrate --model ../$W/style$k \
      --content ../style-transfer/data/content --batches 10 --safety 1.0 --bits w8a8 \
      --out ../$W/style$k/calibration.json
done
cd ..

# 3. 联合校准：逐点取各风格 scale/absmax 的最大值
python3 fpga_src-st-accel/tools/st_merge_calib.py --out $W/calibration_joint.json \
    $W/style0/calibration.json $W/style1/calibration.json

# 4. 每个风格用同一份联合校准导出
cd fpga_st_train
for k in 0 1; do
  ./target/release/fpga_st_train --device cpu export-int8 --model ../$W/style$k \
      --calibration ../$W/calibration_joint.json --out ../$W/w8a8_s$k
done
cd ..

# 5. 合并成一个带 style_packets 的 manifest
python3 fpga_src-st-accel/tools/st_merge_styles.py --out $W/w8a8 $W/w8a8_s0 $W/w8a8_s1
ln -sfn ms2/w8a8 st_work/board_w8a8
```

为什么要联合校准：卷积和它们的 requant 是共享的，所以每个量化点的 scale 必须所有风格一样。
逐点取最大值能保证每个风格的削顶都不比它自己单独校准时更严重。这个模型上 scale 最多放大 1.2 倍。

`st_merge_styles.py` 会检查 `weights.bin` 和除 `norm_layers`/`film_layers` 以外的所有 manifest 字段完全一致，不一致就报错。
合并后的 manifest 就是风格 0 的 manifest，加上：

```json
"style_packets": [{"norm_layers": [...], "film_layers": [...]}, ...]
```

每个风格一项，包括风格 0。不认识风格的工具看到的就是风格 0。

## 4. 生成 RTL 数据并验证

```bash
cd fpga_src-st-accel
python3 tools/st_gen_guided.py
python3 tools/st_gen_norm.py --manifest ../st_work/board_w8a8 --out rtl/st_accel_new/gen/guided
python3 tools/st_gen_film.py --manifest ../st_work/board_w8a8 --out rtl/st_accel_new/gen/guided
python3 tools/st_gen_prelut.py
```

各工具的默认 manifest 现在都是 `st_work/board_w8a8`。

| 生成物 | 内容 |
|---|---|
| `st_ln.hex` | 风格 k 的 LN 系数放在第 20k 到 20k+19 行（FiLM 区从第 128 行开始，所以最多 6 个风格） |
| `st_film.hex`、`st_film_hi.hex` | 每个风格 384 行，风格 k 从第 384k 行开始；0..1023 行在 `st_film.hex`，其余在 `st_film_hi.hex`（第 8 节） |
| `st_net_pkg.sv` | `ST_STYLES`，以及所有风格共用的 FiLM 常数 `ST_FILM_SZ/SG/SB/C0/KB` |

**FiLM 常数共享**：

- C0 和 KB 只取决于量化 scale，联合校准后所有风格都一样。
- 移位 SZ/SG/SB 取各风格拟合结果的最小值（`st_guided.film_shifts`），保证没有风格溢出。
- `st_gen_film.build_styles` 会检查所有风格的共享常数确实相等。
- 第一版双风格模型是 sz26 sg24 sb20、c0 21922、kb900，和 p90 单风格版本不同（p90 是 sg23、c0 26755）。
- 最终版 final_s3b 是 sz25 sg24 sb20、c0 8391、kb900。

**golden**：`tools/st_guided.py --style k` 用第 k 个风格包。两个风格的硬件输出对 fp32 都在 37.8 dB 以上。

**仿真**：

```bash
make -C sim tb_st_film                 # 4 组 × FILM_STYLES="0 1"
make -C sim tb_st_norm                 # 含 ln_s1：风格 1 的 LN
make -C sim tb_st_engine ENGINE_STYLE=1
```

两个风格的期望输出不同，所以这些测试确实能查出风格选错的问题。

## 5. 硬件实现

本节先写的是双风格版本，3 个风格时改了的地方在每条后面注明，细节见第 8 节。

**风格从哪来**：

- 固件已经有风格菜单：`ui_regs` 的 MENU 寄存器 bits[4:3]。双风格时按键在 0–3 之间循环；现在在 0..`ST_NUM_STYLES`-1（3 个风格时是 0–2）之间循环。
- `fpga_src_top.v` 把 `ui_style` 接到 `st_accel_wrapper` 的 `style` 端口。
- `ui_regs` 和加速器在同一个时钟上（feat/st-fmax 里是 125 MHz 的 sys_clk），不需要跨时钟同步。

**锁存**：

- `st_engine` 在一帧开始（start）时锁存 style 到 `style_q`，再送给 `st_norm`、`st_film`，并用来选 guide 层的 rq 基址。
  `ST_STYLES` 是 2 的幂时按它取模；`ST_STYLES = 3` 时把 3 映射成 0。
- 所以一帧里不会混用两套参数，切换在下一帧生效。
- 双风格时菜单的 4 个值按 2 取模：屏幕显示的 1、3 是风格 0，2、4 是风格 1。

**读地址**：

- `st_norm`：LN 模式下的读基址是 `style × 20`，用 `style<<4 + style<<2` 算，不需要乘法器。FiLM 区的基址不变。
- `st_film`：双风格时 ROM 深度是 `512 × STYLES`，读地址是 `{style, rom_addr}`。
  现在每个风格的步长是 384（`style<<8 + style<<7 + rom_addr`），`STYLES` 可以是 1 到 4。

**腾出 RAM**：

- 两个风格的 FiLM ROM 要 4 个 RAM10，比原来多 2 个，map 结果是 258/256。
- `st_add` 和 `st_norm` 的输出 FIFO 都是 16 深 × 43 位。用 `fifo_sync_core` 时各占 2 个 RAM10：块数由位宽决定，深度用不满也一样占。
- 新写了 `rtl/vid/common/fifo_srl_core.sv`，接口和读侧时序（寄存器输出、首字直通）都和 `fifo_sync_core` 一样。
  它用一条带异步抽头的移位寄存器存数，Efinity 会映射成 SRL8，和 st_dw 的列延迟线是同一种写法。
- 两个 FIFO 换掉以后省 4 个 RAM10，结果是 254/256。代价是 XLR 从约 97.7% 涨到 98.25%。
- 走过的弯路：把 fifo_sync_core 按 40 位切片不能省 RAM。Efinity 不用 256×40 这个形状，130 位宽、深 256 或 64 时仍然是 7 块。

## 6. 换模型或加风格

**同样 2 个风格、换训练结果**（最常见）：

1. 重跑第 3 节。
2. 重跑第 4 节的生成和仿真。
3. 编译，JTAG 加载，跑 `tools/board_smoke_test.py --vid --json --seconds 10`。

只要网络结构和通道数不变，RTL 不用改。

`board_w8a8` 换目标以后测试向量必须跟着重新生成。`st_norm_vectors.py` 的 golden 缓存按 manifest 内容做 key，`st_io_vec` 在 make 里依赖 manifest，其余的向量每次运行都会重新生成。
以前缓存按路径做 key，换模型后会误用旧缓存。

**同样 3 个风格、换训练结果**：重跑第 8 节的流程（拆分 → 校准 → 联合校准 → 导出 → 合并 → 生成 → 仿真 3 个风格 → 编译上板）。
只要结构不变，RTL 不用改。合并时如果有别的层也按风格变了，`st_merge_styles.py` 会报错，要先确认它是不是也是折进卷积的正系数仿射。

**4 个风格**：

- LN：4 × 20 = 80 行，coef_ram 放得下。
- FiLM ROM：4 × 384 = 1536 字，拆成 1024 + 512 两个数组，要 4 + 2 = 6 个 RAM10 以上，比现在至少多 2 个。现在 RAM 已经 256/256，要先腾出来。候选有：
  - OCR 从 16 KB 降到 8 KB，能省 8 个（见 docs/st-multistyle-packets.md 方案 B）；
  - st_dw 的 `u_fifo`（131 位 × 64 深，7 个 RAM10）。
- guide 的 rq 块：每个风格 8 个字，rq ROM 放得下。
- 固件里 `ST_NUM_STYLES` 改成 4，引擎按 `& 3` 取模。

**3 个风格**：已经实现，见第 8 节。

**网络结构变了**（通道数、层数）：pass 表、ROM 形状都会变，要按 docs/st-guided-adr.md 的流程整套重新生成和验证。

## 7. 相关文件

| 文件 | 作用 |
|---|---|
| `tools/st_split_styles.py` | 把多风格检查点拆成单风格模型 |
| `tools/st_merge_calib.py` | 合并各风格的校准结果，逐点取最大值 |
| `tools/st_merge_styles.py` | 合并各风格的 W8A8 导出，生成 `style_packets` |
| `tools/st_guided.py` | golden，`--style k`；`film_shifts` 计算共享的 FiLM 移位 |
| `tools/st_gen_norm.py`、`tools/st_gen_film.py` | 按风格生成 LN、FiLM 的 hex |
| `rtl/st_accel_new/engine/st_norm.sv`、`st_film.sv`、`st_engine.sv` | 按风格选址、锁存 |
| `rtl/vid/common/fifo_srl_core.sv` | SRL 实现的小 FIFO |

## 8. 最终版：3 个风格和 packet_guide（final_s3b）

2026-11-03，feat/st-fmax。导出在 `st_work/s3b`，`board_w8a8` 指向 `s3b/w8a8`。

| 项目 | 数值 |
|---|---|
| 风格 | 0 bright、1 gouache、2 comic；菜单在 1–3 之间循环 |
| 每帧周期（仿真） | 6,413,390，3 个风格相同 |
| 板上 | 125 MHz 时 16.8 fps，`errors 0`，摄像头不丢帧 |
| RAM10 | 256/256 |
| XLR | 59804/60800（98.36%） |
| DSP | 159/160 |
| 时序 | setup 和 hold 都满足；sys_clk 最差 slack +0.63 ns |
| hw 对 fp32 | bright 34.9–38.6 dB，gouache 36.4–39.1 dB，comic 31.8–37.0 dB，和训练端 int 推理一致 |

**拆分**：训练端已经把风格拆成单风格模型（`runs/astra2/split/{bright,gouache,comic}`），不需要 `st_split_styles.py`。
之后的校准、联合校准、导出和合并跟第 3 节一样，只是有 3 个风格：

```bash
cd /data/competition/2026fpga
W=st_work/s3b; S=fpga_st_train/runs/astra2/split
cp -r $S/bright $W/style0; cp -r $S/gouache $W/style1; cp -r $S/comic $W/style2
cd fpga_st_train
for k in 0 1 2; do
  ./target/release/fpga_st_train --device cpu calibrate --model ../$W/style$k \
      --content ../style-transfer/data/content --batches 20 --safety 1.0 --bits w8a8 \
      --out ../$W/style$k/calibration.json
done
cd ..
python3 fpga_src-st-fmax/tools/st_merge_calib.py --out $W/calibration_joint.json \
    $W/style0/calibration.json $W/style1/calibration.json $W/style2/calibration.json
cd fpga_st_train
for k in 0 1 2; do
  ./target/release/fpga_st_train --device cpu export-int8 --model ../$W/style$k \
      --calibration ../$W/calibration_joint.json --out ../$W/w8a8_s$k
done
cd ..
python3 fpga_src-st-fmax/tools/st_merge_styles.py --out $W/w8a8 $W/w8a8_s0 $W/w8a8_s1 $W/w8a8_s2
#   -> "layer guide: per-style weight_scale, bias, bias_int32, requant"
ln -sfn s3b/w8a8 st_work/board_w8a8
```

然后在 `fpga_src-st-fmax` 里重跑第 4 节的 4 个生成命令，跑下面的仿真，最后 `tools/build_all.sh --no-ip`（固件也要重编），JTAG 加载，跑 `tools/board_smoke_test.py --vid --json --seconds 10 --clk-mhz 125`。
确认无误后 `tools/build_all.sh --no-fpga --flash` 写入 Flash。

**packet_guide**：每个风格的 guide 输出是 `relu(guide_conv(x)·g_s + b_s)`。拆分时它已经折进 guide 卷积，权重是 W·g、偏置是 b·g + b_s，g > 0。
所以各风格 int8 权重码完全一样，`weights.bin` 仍然共享。不同的只有 guide 层的 `weight_scale`、`bias`、`bias_int32` 和 `requant`。

- `st_merge_styles.py` 只允许这四个字段按层不同，并把它们写进每个风格包的 `layer_overrides`；其他字段不一致还是报错。
- `st_guided.Guided(style=k)` 用风格 k 的 `layer_overrides` 覆盖层参数。
- `st_gen_guided.py` 给这类层在 rq ROM 里每个风格放一块（风格 s 在 `rq_base + s × ST_RQ_STRIDE`，这里 stride 是 8）。
  `st_net_pkg::st_rq_base(层, style)` 给出基址，`st_engine` 用它给 DW 和 PW 取 rq 基址。rq ROM 从 842 字增加到 858 字，RAM 不变。

**3 个风格的存储**：

- LN：3 × 20 行，不变。
- FiLM ROM：每个风格的步长从 512 改成 384（380 字已用），地址是 `style×256 + style×128 + addr`。
  Efinity 会把一个数组的深度向上取到 2 的幂，1152 × 40 放在一个数组里要 8 个 RAM10。所以拆成两个数组：
  `st_film.hex` 放 0..1023 字（4 个 RAM10），`st_film_hi.hex` 放其余字（2 个 RAM10），读出寄存以后再按地址选。总共 6 个 RAM10，正好 256/256。
- 选风格：`st_engine` 在 `ST_STYLES = 3` 时把 style 3 映射到 0，2 的幂时仍然取模。固件菜单在 0..2 之间循环（`ST_NUM_STYLES`）。

**LN 偏置位宽**：gouache 有 8 个通道的 β 超过 16 个输出码，`B_c` 超出 27 位字段。
现在 `ln_consts` 把 `B_c` 取成偶数（`LN_BSH = 1`），字段里存 `B_c >> 1`，`st_norm` 在 LN 模式下左移一位还原。
精度损失只有 2^-22 个码，看不出差别；RAM 不变。

**仿真**：`make -C sim tb_st_norm`（多了 ln_s2）、`make -C sim tb_st_film`（`FILM_STYLES` 默认是 `0 1 2`）、`make -C sim tb_st_engine ENGINE_STYLE=k`（k = 0、1、2 都要跑，整帧全部字节一致）。

**余量**：RAM 已经用满。以后要加东西，就把 OCR 从 16 KB 降到 8 KB，能腾出 8 个 RAM10（见第 6 节）。
