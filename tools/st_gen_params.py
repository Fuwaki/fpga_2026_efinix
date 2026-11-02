#!/usr/bin/env python3
"""Generate the ST block-engine parameter ROMs and the network package.

Writes into --out:

  st_pw.hex      PW weight ROM, 1024-bit words, one per output tile of 8 and
                 input tile of 16, output tile outer, input tile inner.  Byte
                 o*16 + i of a word holds the weight of output lane o and
                 input lane i, two's complement int8.  One 1x1 PW layer takes
                 ceil(Cout/8) * ceil(Cin/16) words; the stem is the same ROM
                 over im2col inputs, Cin = 27, lane j = ic*9 + ky*3 + kx.
  st_dw.hex      depthwise weight ROM, 288-bit words, one per 4-channel
                 group: byte c*9 + ky*3 + kx.
  st_rq.hex      requant ROM, 64-bit words, 16 hex digits, MSB first:
                 [31:0] bias_int32 (two's complement), [55:32] mant,
                 [61:56] k = 24 - exp, [63:62] 0, with
                 (mant, exp) = f32_parts(r).  One word per output channel of
                 every conv layer in manifest order, then one word per add.
  st_net_pkg.sv  package st_net_pkg: ROM depths, the layer, pass and DDR
                 region tables as function lookups (Efinity does not accept
                 localparam arrays of structs).
  st_net.json    the same tables, for the Python testbenches.

Every weight byte is the manifest's, bit for bit: the generator decodes its
own ROM images again and asserts they equal the manifest, and it checks that
the ROM bases fit their depths.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_golden import CAM_H, CAM_W, PASSES, WIDE_POINTS, f32_parts  # noqa: E402

PW_LANES, PW_IN = 8, 16          # PW MAC array: 8 outputs x 16 inputs
DW_LANES = 4                     # DW stage: 4 channels per cycle
PW_WORD_BYTES = PW_LANES * PW_IN
DW_WORD_BYTES = DW_LANES * 9

RQ_WORD_BYTES = 8
ADD_CLAMP = 127                  # residual/skip add: clamp(src, +-act_qmax)

DDR_BASE = 0x0800_0000
REGION_ALIGN = 0x1000            # every DDR region starts 4 KiB aligned
IMG_W, IMG_H = 320, 240          # network resolution (ADR)

KIND_PW, KIND_DW, KIND_IM2COL = 0, 1, 2

# Field widths of the st_net_pkg.sv structs; the generator refuses a network
# that would not fit them rather than let it truncate.
W_CIN, W_COUT, W_CH = 7, 7, 7     # layer and pass channel fields
W_W, W_H = 12, 12                 # pass grid fields: pre reads the 1280-wide ISP slot
W_RW, W_RH = 10, 10               # DDR region grid fields
W_PB = 8                          # pixel bytes, at most 16 * 8


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def roundup16(n: int) -> int:
    return ceil_div(n, 16) * 16


def align_up(n: int, a: int) -> int:
    return ceil_div(n, a) * a


# --------------------------------------------------------------- manifest
def load_manifest(mdir: Path):
    m = json.loads((mdir / "manifest.json").read_text())
    wts = np.fromfile(mdir / m["weight_file"], dtype=np.int8).astype(np.int64)
    return m, wts


def layer_kind(l: dict) -> int:
    if l["groups"] > 1:
        assert l["groups"] == l["in_channels"] == l["out_channels"], \
            f"{l['name']}: depthwise groups must equal the channel count"
        return KIND_DW
    return KIND_IM2COL if l["kernel"] != [1, 1] else KIND_PW


def rom_inputs(l: dict):
    """ROM input lane j -> (ic, ky, kx); Cin of the ROM is len(self)."""
    k = l["kernel"][0]
    if k == 1:
        return [(c, 0, 0) for c in range(l["in_channels"])]
    return [(c, ky, kx) for c in range(l["in_channels"])
            for ky in range(k) for kx in range(k)]


def pw_matrix(l: dict, wts: np.ndarray) -> np.ndarray:
    """Weight as [oc][ROM input lane] (im2col order for 3x3 kernels)."""
    k = l["kernel"][0]
    ic, oc = l["in_channels"], l["out_channels"]
    wt = wts[l["weight_offset"]: l["weight_offset"] + oc * ic * k * k].reshape(oc, ic, k, k)
    return np.stack([wt[:, c, ky, kx] for c, ky, kx in rom_inputs(l)], axis=1)


def dw_matrix(l: dict, wts: np.ndarray) -> np.ndarray:
    """Weight as [oc][ky*3 + kx]."""
    k = l["kernel"][0]
    oc = l["out_channels"]
    assert k == 3, f"{l['name']}: depthwise kernel must be 3x3"
    return wts[l["weight_offset"]: l["weight_offset"] + oc * k * k].reshape(oc, k * k)


# ------------------------------------------------------------- ROM images
def pw_word(w2d: np.ndarray, ot: int, it: int, cout: int) -> bytes:
    b = bytearray(PW_WORD_BYTES)
    for o in range(PW_LANES):
        oc = ot * PW_LANES + o
        if oc >= cout:
            continue
        for i in range(PW_IN):
            ic = it * PW_IN + i
            if ic >= w2d.shape[1]:
                continue
            b[o * PW_IN + i] = int(w2d[oc, ic]) & 0xFF
    return bytes(b)


def dw_word(w2d: np.ndarray, g: int) -> bytes:
    b = bytearray(DW_WORD_BYTES)
    for c in range(DW_LANES):
        oc = g * DW_LANES + c
        if oc >= w2d.shape[0]:
            continue
        for t in range(9):
            b[c * 9 + t] = int(w2d[oc, t]) & 0xFF
    return bytes(b)


def rq_word(bias: int, mant: int, k: int) -> bytes:
    assert -2**31 <= bias < 2**31, f"bias {bias} does not fit int32"
    assert 0 < mant < 2**24, f"mantissa {mant} is not 24 bit"
    assert 0 <= k < 64, f"shift {k} does not fit 6 bit"
    v = (bias & 0xFFFF_FFFF) | ((mant & 0xFF_FFFF) << 32) | ((k & 0x3F) << 56)
    return v.to_bytes(RQ_WORD_BYTES, "little")


def hex_lines(words: list[bytes]) -> str:
    """Little-endian byte lists -> MSB-first hex, one word per line."""
    return "".join(w[::-1].hex() + "\n" for w in words)


def parse_hex(text: str) -> list[bytes]:
    """Inverse of hex_lines: one byte list per line, byte 0 first."""
    return [bytes.fromhex(line)[::-1] for line in text.splitlines() if line.strip()]


# ------------------------------------------------------------ weight check
def decode_pw(words: list[bytes], base: int, cout: int, cin: int) -> dict:
    n_in = ceil_div(cin, PW_IN)
    n_out = ceil_div(cout, PW_LANES)
    got = {}
    for ot in range(n_out):
        for it in range(n_in):
            w = words[base + ot * n_in + it]
            for o in range(PW_LANES):
                oc = ot * PW_LANES + o
                for i in range(PW_IN):
                    ic = it * PW_IN + i
                    code = w[o * PW_IN + i]
                    if oc >= cout or ic >= cin:
                        assert code == 0, \
                            f"PW lane ({oc},{ic}) outside {cout}x{cin} is not zero"
                        continue
                    got[(oc, ic)] = code - 256 if code > 127 else code
    return got


def decode_dw(words: list[bytes], base: int, cout: int) -> dict:
    got = {}
    for g in range(ceil_div(cout, DW_LANES)):
        w = words[base + g]
        for c in range(DW_LANES):
            oc = g * DW_LANES + c
            for t in range(9):
                code = w[c * 9 + t]
                if oc >= cout:
                    assert code == 0, f"DW lane {oc} outside {cout} is not zero"
                    continue
                got[(oc, t)] = code - 256 if code > 127 else code
    return got


# ------------------------------------------------------------- net tables
def conv_shape(l: dict, ih: int, iw: int):
    k, st, p = l["kernel"][0], l["stride"][0], l["reflect_pad"]
    return (ih + 2 * p - k) // st + 1, (iw + 2 * p - k) // st + 1


def layer_clamp(l: dict, qmax: int, oqmax: int):
    if l["out_unsigned"]:
        return 0, oqmax
    if l["out_relu"]:
        return 0, qmax
    return -qmax, qmax


def build(mdir: Path, iw: int, ih: int):
    m, wts = load_manifest(mdir)
    layers = m["layers"]
    L = {l["name"]: l for l in layers}
    qmax = int(m["act_qmax"])
    oqmax = int(m["output_qmax"])
    scales = m["point_scales"]

    pw_words: list[bytes] = []
    dw_words: list[bytes] = []
    rq_words: list[bytes] = []
    ltbl = []

    for l in layers:
        kind = layer_kind(l)
        stride = l["stride"][0]
        lo, hi = layer_clamp(l, qmax, oqmax)
        assert -512 <= lo <= hi <= 511, f"{l['name']}: clamp {lo}..{hi} does not fit 10 bit"
        cout = l["out_channels"]
        if kind == KIND_DW:
            cin = cout
            pw_base, dw_base = 0, len(dw_words)
            w2d = dw_matrix(l, wts)
            for g in range(ceil_div(cout, DW_LANES)):
                dw_words.append(dw_word(w2d, g))
            n_pw = 0
        else:
            w2d = pw_matrix(l, wts)
            cin = w2d.shape[1]
            pw_base, dw_base = len(pw_words), 0
            n_in = ceil_div(cin, PW_IN)
            for ot in range(ceil_div(cout, PW_LANES)):
                for it in range(n_in):
                    pw_words.append(pw_word(w2d, ot, it, cout))
            n_pw = ceil_div(cout, PW_LANES) * n_in
        rq_base = len(rq_words)
        for oc in range(cout):
            mant, exp = f32_parts(l["requant"][oc])
            k = 24 - exp
            assert 16 <= k <= 47, f"{l['name']}[{oc}]: k={k} outside the lane's 16..47"
            rq_words.append(rq_word(int(l["bias_int32"][oc]), mant, k))
        assert cin < (1 << W_CIN) and cout < (1 << W_COUT), \
            f"{l['name']}: {cin}->{cout} does not fit the channel fields"
        assert stride < 4, f"{l['name']}: stride {stride} does not fit 2 bits"
        ltbl.append(dict(
            index=layers.index(l), name=l["name"], kind=kind, cin=cin, cout=cout, stride=stride,
            pw_base=pw_base, dw_base=dw_base, rq_base=rq_base, lo=lo, hi=hi,
            in_point=l["in_point"], out_point=l["out_point"],
            n_pw_words=n_pw, n_rq_words=cout,
            n_dw_words=0 if kind != KIND_DW else ceil_div(cout, DW_LANES),
        ))

    # ---- adds: one requant word each, in graph order (5->9, 9->13, 13->17,
    #      17->21, then the skip 3->21), exactly as Net.add_requant.
    adds = [(int(g["point"]), int(g["source_point"]))
            for g in m["graph"] if g["op"] == "add"]
    assert adds == [(9, 5), (13, 9), (17, 13), (21, 17), (21, 3)], adds
    add_rq_base = len(rq_words)
    add_tbl = []
    for dst, src in adds:
        f = np.float32(scales[src]) / np.float32(scales[dst])
        mant, exp = f32_parts(f)
        k = 24 - exp
        assert 16 <= k <= 47, f"add {src}->{dst}: k={k} outside the lane's 16..47"
        assert 0 < f < 1.0, f"add {src}->{dst}: factor {f} is not a downscale"
        rq_words.append(rq_word(0, mant, k))
        add_tbl.append(dict(dst_point=dst, src_point=src, rq_index=len(rq_words) - 1,
                            factor=float(f), mant=mant, k=k))
    add_by_pair = {(a["dst_point"], a["src_point"]): a for a in add_tbl}

    # ---- passes and point shapes
    dim = {0: (ih, iw, 3)}                    # (h, w, c) of point 0
    ptbl = []
    res_src = None
    for pi, (pname, lnames, ups, add) in enumerate(PASSES, start=1):
        l0 = L[lnames[0]]
        in_pt = l0["in_point"]
        if pname == "res0a":
            res_src = in_pt          # the chain's source point (st_golden.Net.run)
        ph, pw_, _ = dim[in_pt]
        if ups:
            ph, pw_ = 2 * ph, 2 * pw_
        in_h, in_w, in_c = ph, pw_, dim[in_pt][2]
        for ln in lnames:
            l = L[ln]
            ph, pw_ = conv_shape(l, ph, pw_)
            dim[l["out_point"]] = (ph, pw_, l["out_channels"])
        out_pt = L[lnames[-1]]["out_point"]
        oh, ow, oc = dim[out_pt]
        if add == "res":
            assert res_src is not None, f"{pname}: residual add without a source"
            a = add_by_pair[(out_pt, res_src)]
            aux_pt, mode, add_rq = res_src, "ADD_OUT", a["rq_index"]
            assert dim[aux_pt][:2] == (oh, ow), f"{pname}: aux grid differs from the output"
        elif add == "skip":
            a = add_by_pair[(in_pt, 3)]
            aux_pt, mode, add_rq = 3, "ADD_IN", a["rq_index"]
            assert dim[aux_pt][:2] == (in_h, in_w), f"{pname}: aux grid differs from the input"
        else:
            aux_pt, mode, add_rq = None, "NONE", 0
        ptbl.append(dict(
            index=pi, name=pname, in_point=in_pt,
            aux_point=aux_pt, out_point=out_pt, upsample=bool(ups),
            add_mode=mode, add_rq=add_rq,
            first_layer=layers.index(L[lnames[0]]), n_layers=len(lnames),
            in_w=in_w, in_h=in_h, in_c=in_c, out_w=ow, out_h=oh, out_c=oc,
        ))
        if add == "res":
            res_src = out_pt

    for p in ptbl + [dict(name="pre", in_w=CAM_W, in_h=CAM_H, in_c=3,
                          out_w=dim[0][1], out_h=dim[0][0], out_c=dim[0][2])]:
        for k, bits in (("in_w", W_W), ("in_h", W_H), ("out_w", W_W), ("out_h", W_H),
                        ("in_c", W_CH), ("out_c", W_CH)):
            assert p[k] < (1 << bits), f"{p['name']}: {k} {p[k]} does not fit {bits} bits"

    pre = dict(index=0, name="pre", in_point=None, aux_point=None, out_point=0,
               upsample=False, add_mode="NONE", add_rq=0, first_layer=0, n_layers=0,
               in_w=CAM_W, in_h=CAM_H, in_c=3,
               out_w=dim[0][1], out_h=dim[0][0], out_c=dim[0][2])
    passes = [pre] + ptbl
    assert len(passes) == 15 and len(ptbl) == len(PASSES) == 14

    # ---- DDR regions: the points that cross a pass boundary
    points = sorted({p["in_point"] for p in ptbl})
    assert points == [0, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 24, 27], points
    cursor = DDR_BASE
    regions = []
    for pt in points:
        h, w, c = dim[pt]
        elem = 2 if pt in WIDE_POINTS else 1
        pb = roundup16(c * elem)
        base = align_up(cursor, REGION_ALIGN)
        size = w * h * pb
        assert base % REGION_ALIGN == 0
        assert w < (1 << W_RW) and h < (1 << W_RH) and c < (1 << W_CH), \
            f"point {pt}: region {w}x{h}x{c} does not fit the table fields"
        assert pb < (1 << W_PB), f"point {pt}: pixel bytes {pb} does not fit {W_PB} bits"
        regions.append(dict(point=pt, base=base, w=w, h=h, c=c, elem=elem, pb=pb,
                            bytes=size))
        cursor = base + size

    net = dict(
        format="st-net-v1",
        source=str(mdir),
        arch=m["arch"],
        manifest_sha256=hashlib.sha256((mdir / "manifest.json").read_bytes()).hexdigest(),
        img_w=iw, img_h=ih,
        pw_depth=len(pw_words), dw_depth=len(dw_words), rq_depth=len(rq_words),
        add_rq_base=add_rq_base,
        layers=ltbl,
        passes=passes,
        adds=add_tbl,
        regions=[dict(r, base_hex=f"0x{r['base']:08x}") for r in regions],
        region_bytes=cursor - DDR_BASE,
    )
    return net, pw_words, dw_words, rq_words, wts, m


# --------------------------------------------------------------- self check
def self_check(net, pw_words, dw_words, rq_words, wts, m, out: Path):
    layers = net["layers"]
    L = {l["name"]: l for l in m["layers"]}
    pw = parse_hex((out / "st_pw.hex").read_text())
    dw = parse_hex((out / "st_dw.hex").read_text())
    rq = parse_hex((out / "st_rq.hex").read_text())
    assert len(pw) == net["pw_depth"], (len(pw), net["pw_depth"])
    assert len(dw) == net["dw_depth"], (len(dw), net["dw_depth"])
    assert len(rq) == net["rq_depth"], (len(rq), net["rq_depth"])
    assert pw_words == pw and dw_words == dw and rq_words == rq, "ROM image mismatch"

    for lt in layers:
        l = L[lt["name"]]
        if lt["kind"] == KIND_DW:
            got = decode_dw(dw, lt["dw_base"], lt["cout"])
            want = dw_matrix(l, wts)
            assert len(got) == lt["cout"] * 9, f"{lt['name']}: decoded {len(got)} DW taps"
            for oc in range(lt["cout"]):
                for t in range(9):
                    assert got[(oc, t)] == int(want[oc, t]), \
                        f"{lt['name']} dw[{oc}][{t}]: {got[(oc, t)]} != {int(want[oc, t])}"
        else:
            got = decode_pw(pw, lt["pw_base"], lt["cout"], lt["cin"])
            want = pw_matrix(l, wts)
            assert len(got) == lt["cout"] * lt["cin"], f"{lt['name']}: decoded {len(got)} PW weights"
            for oc in range(lt["cout"]):
                for ic in range(lt["cin"]):
                    assert got[(oc, ic)] == int(want[oc, ic]), \
                        f"{lt['name']} pw[{oc}][{ic}]: {got[(oc, ic)]} != {int(want[oc, ic])}"
        # requant words: bias, mantissa and shift against f32_parts
        for oc in range(lt["cout"]):
            w = int.from_bytes(rq[lt["rq_base"] + oc], "little")
            bias = w & 0xFFFF_FFFF
            bias = bias - 2**32 if bias >= 2**31 else bias
            mant, k, spare = (w >> 32) & 0xFF_FFFF, (w >> 56) & 0x3F, (w >> 62) & 3
            want_mant, exp = f32_parts(l["requant"][oc])
            assert bias == l["bias_int32"][oc], f"{lt['name']}[{oc}]: bias {bias}"
            assert mant == want_mant and k == 24 - exp, f"{lt['name']}[{oc}]: mant/k"
            assert spare == 0 and mant >> 23 == 1, f"{lt['name']}[{oc}]: word layout"

    for a in net["adds"]:
        w = int.from_bytes(rq[a["rq_index"]], "little")
        assert w & 0xFFFF_FFFF == 0, "add word carries a bias"
        f = np.float32(m["point_scales"][a["src_point"]]) / np.float32(m["point_scales"][a["dst_point"]])
        mant, exp = f32_parts(f)
        assert (w >> 32) & 0xFF_FFFF == mant and (w >> 56) & 0x3F == 24 - exp, \
            f"add {a['src_point']}->{a['dst_point']}: factor word"

    # Depth bases tile each ROM exactly, and each ROM stays inside its budget.
    for key, depth, budget in (("pw", net["pw_depth"], 512),
                               ("dw", net["dw_depth"], 1024),
                               ("rq", net["add_rq_base"], 2048)):
        n = sum(lt[f"n_{key}_words"] for lt in layers)
        assert n == depth, f"{key}: {n} words but depth {depth}"
        assert depth <= budget, f"{key} ROM depth {depth} exceeds the {budget}-word budget"
        used = sorted(lt[f"{key}_base"] for lt in layers if lt[f"n_{key}_words"])
        assert used and used[0] == 0, f"{key}: first base is not 0"
    assert net["rq_depth"] == net["add_rq_base"] + len(net["adds"])

    # Pass/point tables agree with the manifest and the golden pass list.
    for p in net["passes"][1:]:
        l0 = m["layers"][p["first_layer"]]
        assert l0["name"] == PASSES[p["index"] - 1][1][0], f"pass {p['name']}: first layer"
        assert l0["in_point"] == p["in_point"], f"pass {p['name']}: input point"


# ---------------------------------------------------------- SV/JSON output
DEF_LAYER = "kind: 2'd0, cin: 7'd0, cout: 7'd0, stride: 2'd1, pw_base: 10'd0, " \
            "dw_base: 10'd0, rq_base: 11'd0, lo: 10'h000, hi: 10'h000"
DEF_PASS = ("in_point: 6'd63, aux_point: 6'd63, out_point: 5'd0, upsample: 1'b0, "
            "add_mode: 2'd0, add_rq: 11'd0, first_layer: 5'd0, n_layers: 5'd0, "
            "in_w: 12'd0, in_h: 12'd0, in_c: 7'd0, out_w: 12'd0, out_h: 12'd0, out_c: 7'd0")
DEF_REGION = "base: 32'h0000_0000, w: 10'd0, h: 10'd0, c: 7'd0, elem: 2'd1, pb: 8'd0"
PT_NONE = 63


def sv_pkg(net) -> str:
    o = []
    a = o.append
    a("// st_net_pkg.sv -- ST block engine network tables for "
      f"{net['arch']} ({net['source']}).")
    a("// Generated by tools/st_gen_params.py; do not edit.")
    a("//")
    a(f"// The network runs at {net['img_w']}x{net['img_h']} internally: 15 DDR passes")
    a(f"// ({len(net['passes'])} including pre), {len(net['layers'])} conv layers, "
      f"{len(net['adds'])} adds.  See docs/st-accel-engine-adr.md.")
    a("//")
    a("// The requant ROM holds one word per output channel of every conv layer in")
    a("// manifest order, then one word per add; ST_ADD_RQ_BASE is the first add word.")
    a("//")
    a("// The tables are function lookups with case statements, not localparam arrays:")
    a("// Efinity does not accept arrays of structs as parameters.")
    a("//")
    a("//   st_layer(i)     layer i in manifest order: kind, channels, ROM bases, clamp")
    a("//   st_pass(i)      pass i; pass 0 is pre, pass i is PASSES[i-1] of st_golden.py")
    a("//   st_region(pt)   DDR region of point pt; all-zero for a non-DDR point")
    a("//   st_region_point(i) i-th point that has a DDR region, for iteration")
    a("//")
    a("// lo/hi are 10-bit two's complement: relu 0..127, none -127..127, head 0..255.")
    a("// in_w/in_h of a pass describe the grid the engine works on; with upsample set")
    a("// the main DDR source region is in_w/2 x in_h/2 (see st_region).")
    a("package st_net_pkg;")
    a("")
    a(f"  localparam int PW_DEPTH = {net['pw_depth']};   // 1024-bit words")
    a(f"  localparam int DW_DEPTH = {net['dw_depth']};   // 288-bit words")
    a(f"  localparam int RQ_DEPTH = {net['rq_depth']};  // 64-bit words")
    a(f"  localparam int ST_N_LAYERS  = {len(net['layers'])};")
    a(f"  localparam int ST_N_PASSES  = {len(net['passes'])};")
    a(f"  localparam int ST_N_REGIONS = {len(net['regions'])};")
    a(f"  localparam int ST_ADD_RQ_BASE = {net['add_rq_base']};")
    a("")
    a("  // layer kinds")
    a(f"  localparam logic [1:0] ST_KIND_PW     = 2'd{KIND_PW};")
    a(f"  localparam logic [1:0] ST_KIND_DW     = 2'd{KIND_DW};")
    a(f"  localparam logic [1:0] ST_KIND_IM2COL = 2'd{KIND_IM2COL};")
    a("")
    a("  // pass add modes")
    a("  localparam logic [1:0] ST_ADD_NONE = 2'd0;   // no aux read")
    a("  localparam logic [1:0] ST_ADD_IN   = 2'd1;   // + requant(aux) before the DW stage")
    a("  localparam logic [1:0] ST_ADD_OUT  = 2'd2;   // + requant(aux) after the PW stage")
    a("")
    a(f"  localparam logic [5:0] ST_PT_NONE = 6'd{PT_NONE};")
    a("")
    a("  typedef struct packed {")
    a("    logic [1:0]        kind;      // ST_KIND_*")
    a("    logic [6:0]        cin;       // ROM lanes: 27 for the im2col stem")
    a("    logic [6:0]        cout;")
    a("    logic [1:0]        stride;")
    a("    logic [9:0]        pw_base;   // first st_pw.hex word, 0 if DW")
    a("    logic [9:0]        dw_base;   // first st_dw.hex word, 0 if not DW")
    a("    logic [10:0]       rq_base;   // first st_rq.hex word")
    a("    logic [9:0]        lo, hi;    // clamp, two's complement")
    a("  } st_layer_t;")
    a("")
    a("  typedef struct packed {")
    a("    logic [5:0]        in_point;  // ST_PT_NONE: pre reads the ISP slot")
    a("    logic [5:0]        aux_point; // ST_PT_NONE: no aux read")
    a("    logic [4:0]        out_point;")
    a("    logic              upsample;  // 2x nearest on the main input")
    a("    logic [1:0]        add_mode;  // ST_ADD_*")
    a("    logic [10:0]       add_rq;    // requant word of the add factor")
    a("    logic [4:0]        first_layer, n_layers;")
    a(f"    logic [{W_W-1}:0]        in_w, in_h;   // the ISP slot is 1280 wide")
    a("    logic [6:0]        in_c;")
    a(f"    logic [{W_W-1}:0]        out_w, out_h;")
    a("    logic [6:0]        out_c;")
    a("  } st_pass_t;")
    a("")
    a("  typedef struct packed {")
    a("    logic [31:0]       base;      // DDR byte address, 4 KiB aligned")
    a("    logic [9:0]        w, h;")
    a("    logic [6:0]        c;")
    a("    logic [1:0]        elem;      // bytes per element: 1, or 2 on WIDE_POINTS")
    a("    logic [7:0]        pb;        // pixel bytes, roundup16(c * elem)")
    a("  } st_region_t;")
    a("")
    a("  function automatic st_layer_t st_layer(input int i);")
    a("    case (i)")
    for lt in net["layers"]:
        a(f"      {lt['index']}: st_layer = '{{kind: 2'd{lt['kind']}, cin: 7'd{lt['cin']}, "
          f"cout: 7'd{lt['cout']}, stride: 2'd{lt['stride']}, ")
        a(f"                    pw_base: 10'd{lt['pw_base']}, dw_base: 10'd{lt['dw_base']}, "
          f"rq_base: 11'd{lt['rq_base']}, ")
        a(f"                    lo: 10'h{lt['lo'] & 0x3FF:03x}, hi: 10'h{lt['hi'] & 0x3FF:03x}}};")
    a(f"      default: st_layer = '{{{DEF_LAYER}}};")
    a("    endcase")
    a("  endfunction")
    a("")
    a("  function automatic st_pass_t st_pass(input int i);")
    a("    case (i)")
    for p in net["passes"]:
        ip = PT_NONE if p["in_point"] is None else p["in_point"]
        ap = PT_NONE if p["aux_point"] is None else p["aux_point"]
        mode = {"NONE": 0, "ADD_IN": 1, "ADD_OUT": 2}[p["add_mode"]]
        a(f"      {p['index']}: st_pass = '{{in_point: 6'd{ip}, aux_point: 6'd{ap}, "
          f"out_point: 5'd{p['out_point']}, upsample: 1'b{int(p['upsample'])}, ")
        a(f"                   add_mode: 2'd{mode}, add_rq: 11'd{p['add_rq']}, "
          f"first_layer: 5'd{p['first_layer']}, n_layers: 5'd{p['n_layers']}, ")
        a(f"                   in_w: 12'd{p['in_w']}, in_h: 12'd{p['in_h']}, "
          f"in_c: 7'd{p['in_c']}, out_w: 12'd{p['out_w']}, out_h: 12'd{p['out_h']}, "
          f"out_c: 7'd{p['out_c']}}};")
    a(f"      default: st_pass = '{{{DEF_PASS}}};")
    a("    endcase")
    a("  endfunction")
    a("")
    a("  function automatic logic [4:0] st_region_point(input int i);")
    a("    case (i)")
    for k, r in enumerate(net["regions"]):
        a(f"      {k}: st_region_point = 5'd{r['point']};")
    a("      default: st_region_point = 5'd0;")
    a("    endcase")
    a("  endfunction")
    a("")
    a("  function automatic st_region_t st_region(input int pt);")
    a("    case (pt)")
    for r in net["regions"]:
        a(f"      {r['point']}: st_region = '{{base: 32'h{r['base']:08x}, w: 10'd{r['w']}, "
          f"h: 10'd{r['h']}, c: 7'd{r['c']}, ")
        a(f"                     elem: 2'd{r['elem']}, pb: 8'd{r['pb']}}};")
    a(f"      default: st_region = '{{{DEF_REGION}}};")
    a("    endcase")
    a("  endfunction")
    a("")
    a("endpackage")
    return "\n".join(o) + "\n"


# --------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", type=Path, required=True, help="manifest directory")
    ap.add_argument("--out", type=Path, required=True, help="output directory")
    ap.add_argument("--width", type=int, default=IMG_W, help="network input width")
    ap.add_argument("--height", type=int, default=IMG_H, help="network input height")
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    net, pw_words, dw_words, rq_words, wts, m = build(args.manifest, args.width, args.height)

    (args.out / "st_pw.hex").write_text(hex_lines(pw_words))
    (args.out / "st_dw.hex").write_text(hex_lines(dw_words))
    (args.out / "st_rq.hex").write_text(hex_lines(rq_words))
    (args.out / "st_net.json").write_text(json.dumps(net, indent=1) + "\n")
    (args.out / "st_net_pkg.sv").write_text(sv_pkg(net))
    self_check(net, pw_words, dw_words, rq_words, wts, m, args.out)

    print(f"{args.out}: {len(net['layers'])} layers, {len(net['passes'])} passes, "
          f"PW_DEPTH {net['pw_depth']}, DW_DEPTH {net['dw_depth']}, "
          f"RQ_DEPTH {net['rq_depth']}")
    print(f"  DDR regions from 0x{DDR_BASE:08x} to "
          f"0x{DDR_BASE + net['region_bytes']:08x} ({net['region_bytes'] / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
