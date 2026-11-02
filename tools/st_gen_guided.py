#!/usr/bin/env python3
"""Generate the ST block-engine ROMs and network package for the guided net.

The guided counterpart of tools/st_gen_params.py (docs/st-guided-adr.md):
the same ROM formats (st_pw.hex, st_dw.hex, st_rq.hex -- see that file's
docstring), the pass table of the ADR, and st_net_pkg.sv / st_net.json in
--out (default rtl/st_accel_new/gen/guided).

The pass list (PASSES below) names the layers of each pass and its extra
stages; everything else -- shapes, ROM bases, DDR regions, add factors -- is
derived from the manifest and checked against tools/st_guided.py.

Pass fields beyond st_gen_params':
  src_isp   the main input is the ISP slot, through st_pre (else a DDR point)
  pre_pool  st_pre mode: 1 POOL (pool(p0) at H/2), 0 FULL (p0)
  isp_last  the last pass that reads the ISP slot: pre_done after it
  norm      st_norm before the DW stage: 0 off, 1 LayerNorm, 2 FiLM
  gap       GAP tap on the st_pack input; the FiLM MLP runs after the pass
  post      the output goes through st_post to the PROC slot
A pass with no layers (pool) sends the st_pre stream straight to st_pack.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from st_gen_params import (DDR_BASE, DW_LANES, KIND_DW, KIND_IM2COL, KIND_PW,  # noqa: E402
                           PW_IN, PW_LANES, REGION_ALIGN, align_up, ceil_div, conv_shape,
                           decode_dw, decode_pw, dw_matrix, dw_word, f32_parts, hex_lines,
                           layer_clamp, layer_kind, load_manifest, parse_hex, pw_matrix,
                           pw_word, roundup16, rq_word)
from st_guided import CAM_H, CAM_W, NET_H, NET_W, Guided  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = Path("/data/competition/2026fpga/st_work/p90_ln_w8a8")
DEFAULT_OUT = ROOT / "rtl/st_accel_new/gen/guided"

NORM = {None: 0, "ln": 1, "film": 2}

# (name, layers, options).  in: main input point ("isp" = the ISP slot),
# up: 2x upsample of the main input, add: (mode, aux point).
PASSES = [
    ("pool",   [],                            dict(src="isp", pool=True)),
    ("guide",  ["guide"],                     dict(src="isp", isp_last=True)),
    ("stem",   ["stem"],                      dict()),
    ("h2g",    ["h2_guide", "h2_proj"],       dict()),
    ("enc0",   ["enc0.dw", "enc0.pw"],        dict()),
    ("enc1",   ["enc1.dw", "enc1.pw"],        dict()),
    ("res_a",  ["res0.s1.dw", "res0.s1.pw"],  dict()),
    ("res_b",  ["res0.s2.dw", "res0.s2.pw"],  dict(add=("ADD_OUT", 6))),
    ("dec_h4", ["dec_h4.dw", "dec_h4.pw"],    dict(norm="ln", src=10)),
    ("dec_h2", ["dec_h2.dw", "dec_h2.pw"],    dict(up=True, add=("ADD_OUT", 16), gap=True)),
    ("film",   ["to_guide"],                  dict(norm="film", src=17)),
    ("head",   ["head.dw", "head.pw"],        dict(up=True, add=("ADD_IN", 20), post=True)),
]

# st_net_pkg field widths
W_CIN, W_COUT, W_CH = 7, 7, 7
W_W, W_H = 12, 12
W_RW, W_RH = 10, 10
W_PB = 8
PW_BUDGET, DW_BUDGET, RQ_BUDGET = 256, 256, 2048
PT_NONE = 63


def build(mdir: Path):
    m, wts = load_manifest(mdir)
    layers = m["layers"]
    L = {l["name"]: l for l in layers}
    qmax, oqmax = int(m["act_qmax"]), int(m["output_qmax"])
    scales = m["point_scales"]
    gold = Guided(mdir)

    pw_words, dw_words, rq_words, ltbl = [], [], [], []
    for l in layers:
        kind = layer_kind(l)
        lo, hi = layer_clamp(l, qmax, oqmax)
        cout = l["out_channels"]
        if kind == KIND_DW:
            cin, pw_base, dw_base = cout, 0, len(dw_words)
            w2d = dw_matrix(l, wts)
            for g in range(ceil_div(cout, DW_LANES)):
                dw_words.append(dw_word(w2d, g))
            n_pw = 0
        else:
            w2d = pw_matrix(l, wts)
            cin, pw_base, dw_base = w2d.shape[1], len(pw_words), 0
            n_in = ceil_div(cin, PW_IN)
            for ot in range(ceil_div(cout, PW_LANES)):
                for it in range(n_in):
                    pw_words.append(pw_word(w2d, ot, it, cout))
            n_pw = ceil_div(cout, PW_LANES) * n_in
        # Requant words are read 4 at a time from 4 banks (a DW group, a PW
        # half tile): channel 0 of every layer sits on a multiple of 4.
        while len(rq_words) % 4:
            rq_words.append(rq_word(0, 1 << 23, 24))
        rq_base = len(rq_words)
        for oc in range(cout):
            mant, exp = f32_parts(l["requant"][oc])
            k = 24 - exp
            assert 16 <= k <= 47, f"{l['name']}[{oc}]: k={k} outside the lane's 16..47"
            rq_words.append(rq_word(int(l["bias_int32"][oc]), mant, k))
        assert cin < (1 << W_CIN) and cout < (1 << W_COUT), f"{l['name']}: channels"
        ltbl.append(dict(index=layers.index(l), name=l["name"], kind=kind, cin=cin, cout=cout,
                         stride=l["stride"][0], pw_base=pw_base, dw_base=dw_base,
                         rq_base=rq_base, lo=lo, hi=hi, n_pw_words=n_pw,
                         n_dw_words=ceil_div(cout, DW_LANES) if kind == KIND_DW else 0))
    lt_by_name = {lt["name"]: lt for lt in ltbl}

    # adds: one requant word each, graph order
    adds = [(int(g["point"]), int(g["source_point"])) for g in m["graph"] if g["op"] == "add"]
    add_rq_base = len(rq_words)
    add_tbl = {}
    for dst, src in adds:
        f = np.float32(scales[src]) / np.float32(scales[dst])
        mant, exp = f32_parts(f)
        k = 24 - exp
        assert 16 <= k <= 47, f"add {src}->{dst}: k={k}"
        rq_words.append(rq_word(0, mant, k))
        add_tbl[src] = dict(dst_point=dst, src_point=src, rq_index=len(rq_words) - 1,
                            factor=float(f), mant=mant, k=k)

    # shapes of every point from the golden graph on a NET_W x NET_H input
    rgb = np.zeros((NET_H, NET_W, 3), np.uint8)
    gold.run(rgb)
    dim = {p: (t.shape[1], t.shape[2], t.shape[0]) for p, t in gold.ddr.items()}   # (h, w, c)

    ptbl = []
    for pi, (name, lnames, o) in enumerate(PASSES):
        src = o.get("src")
        isp = src == "isp"
        if isp:
            # st_pre output grid: p0 (FULL) or p1 (POOL)
            in_pt = None
            gh, gw, gc = dim[1] if o.get("pool") else dim[0]
        else:
            in_pt = src if isinstance(src, int) else L[lnames[0]]["in_point"]
            gh, gw, gc = dim[in_pt]
            if o.get("up"):
                gh, gw = 2 * gh, 2 * gw
        in_h, in_w, in_c = gh, gw, gc
        ph, pw_ = gh, gw
        for ln in lnames:
            ph, pw_ = conv_shape(L[ln], ph, pw_)
        if lnames:
            out_pt = L[lnames[-1]]["out_point"]
            out_c = L[lnames[-1]]["out_channels"]
        else:
            out_pt, out_c = 1, gc                      # pool writes p1
        if not o.get("post"):
            assert dim[out_pt][:2] == (ph, pw_), f"{name}: output grid {ph}x{pw_} vs {dim[out_pt]}"
        add = o.get("add")
        if add:
            mode, aux = add
            a = add_tbl[aux]
            want_grid = (in_h, in_w) if mode == "ADD_IN" else (ph, pw_)
            assert dim[aux][:2] == want_grid, f"{name}: aux grid"
            add_rq = a["rq_index"]
        else:
            mode, aux, add_rq = "NONE", None, 0
        if lnames:
            l0 = lt_by_name[lnames[0]]
            pn = len(lnames) - (1 if l0["kind"] == KIND_DW else 0)
            assert 1 <= pn <= 2, f"{name}: {pn} PW layers"
            assert l0["kind"] != KIND_IM2COL or in_c == 3, f"{name}: im2col needs 3 channels"
            for ln in lnames[1:]:
                assert lt_by_name[ln]["kind"] == KIND_PW, f"{name}: {ln} must be 1x1"
        ptbl.append(dict(
            index=pi, name=name, in_point=in_pt, aux_point=aux, out_point=out_pt,
            upsample=bool(o.get("up")), add_mode=mode, add_rq=add_rq,
            first_layer=lt_by_name[lnames[0]]["index"] if lnames else 0, n_layers=len(lnames),
            in_w=in_w, in_h=in_h, in_c=in_c, out_w=pw_, out_h=ph, out_c=out_c,
            src_isp=isp, pre_pool=bool(o.get("pool")), isp_last=bool(o.get("isp_last")),
            norm=NORM[o.get("norm")], gap=bool(o.get("gap")), post=bool(o.get("post")),
        ))
        for k, bits in (("in_w", W_W), ("in_h", W_H), ("out_w", W_W), ("out_h", W_H),
                        ("in_c", W_CH), ("out_c", W_CH)):
            assert ptbl[-1][k] < (1 << bits), f"{name}: {k}"
    assert sum(p["isp_last"] for p in ptbl) == 1 and ptbl[-1]["post"]
    assert all(p["src_isp"] for p in ptbl[:2])

    # DDR regions: every point a pass reads or writes
    pts = sorted({p["in_point"] for p in ptbl if p["in_point"] is not None}
                 | {p["aux_point"] for p in ptbl if p["aux_point"] is not None}
                 | {p["out_point"] for p in ptbl if not p["post"]})
    written = {p["out_point"] for p in ptbl if not p["post"]}
    for pt in pts:
        assert pt in written, f"point {pt} is read but no pass writes it"
    cursor, regions = DDR_BASE, []
    for pt in pts:
        h, w, c = dim[pt]
        elem = 2 if pt in gold.wide else 1
        pb = roundup16(c * elem)
        base = align_up(cursor, REGION_ALIGN)
        assert w < (1 << W_RW) and h < (1 << W_RH) and c < (1 << W_CH) and pb < (1 << W_PB)
        regions.append(dict(point=pt, base=base, w=w, h=h, c=c, elem=elem, pb=pb, bytes=w * h * pb))
        cursor = base + w * h * pb

    assert len(pw_words) <= PW_BUDGET and len(dw_words) <= DW_BUDGET and len(rq_words) <= RQ_BUDGET
    net = dict(
        format="st-net-guided-v1", source=str(mdir), arch=m["arch"],
        manifest_sha256=hashlib.sha256((mdir / "manifest.json").read_bytes()).hexdigest(),
        img_w=NET_W, img_h=NET_H, cam_w=CAM_W, cam_h=CAM_H,
        pw_depth=len(pw_words), dw_depth=len(dw_words), rq_depth=len(rq_words),
        add_rq_base=add_rq_base, layers=ltbl, passes=ptbl, adds=list(add_tbl.values()),
        regions=[dict(r, base_hex=f"0x{r['base']:08x}") for r in regions],
        region_bytes=cursor - DDR_BASE,
    )
    return net, pw_words, dw_words, rq_words, wts, m


def self_check(net, out: Path, wts, m):
    L = {l["name"]: l for l in m["layers"]}
    pw = parse_hex((out / "st_pw.hex").read_text())
    dw = parse_hex((out / "st_dw.hex").read_text())
    rq = parse_hex((out / "st_rq.hex").read_text())
    for lt in net["layers"]:
        l = L[lt["name"]]
        if lt["kind"] == KIND_DW:
            got, want = decode_dw(dw, lt["dw_base"], lt["cout"]), dw_matrix(l, wts)
            assert all(got[(o, t)] == int(want[o, t]) for o in range(lt["cout"]) for t in range(9))
        else:
            got, want = decode_pw(pw, lt["pw_base"], lt["cout"], lt["cin"]), pw_matrix(l, wts)
            assert all(got[(o, i)] == int(want[o, i])
                       for o in range(lt["cout"]) for i in range(lt["cin"]))
        assert lt["rq_base"] % 4 == 0, lt["name"]
        for oc in range(lt["cout"]):
            w = int.from_bytes(rq[lt["rq_base"] + oc], "little")
            bias = w & 0xFFFF_FFFF
            bias = bias - 2**32 if bias >= 2**31 else bias
            mant, exp = f32_parts(l["requant"][oc])
            assert bias == l["bias_int32"][oc] and (w >> 32) & 0xFF_FFFF == mant \
                and (w >> 56) & 0x3F == 24 - exp, f"{lt['name']}[{oc}] rq word"


def sv_pkg(net) -> str:
    o = []
    a = o.append
    a(f"// st_net_pkg.sv -- ST block engine tables for {net['arch']} ({net['source']}).")
    a("// Generated by tools/st_gen_guided.py; do not edit.  See docs/st-guided-adr.md.")
    a("//")
    a(f"// The network runs at {net['img_w']}x{net['img_h']}: {len(net['passes'])} passes, "
      f"{len(net['layers'])} conv layers, {len(net['adds'])} adds.")
    a("// Requant ROM: one word per output channel of every conv layer in manifest order")
    a("// (every layer starts on a multiple of 4), then one word per add.")
    a("//")
    a("//   st_layer(i)   layer i in manifest order")
    a("//   st_pass(i)    pass i (st_gen_guided.PASSES)")
    a("//   st_region(pt) DDR region of point pt; all-zero for a non-DDR point")
    a("//   st_region_point(i) i-th point that has a DDR region, for iteration")
    a("//")
    a("// Pass fields: in_w/in_h/in_c are the grid the DW stage works on (with")
    a("// upsample the DDR source is half of it; with src_isp it is st_pre's output).")
    a("// src_isp: the main input is the ISP slot through st_pre (pre_pool: POOL mode);")
    a("// isp_last: pre_done after this pass; norm: st_norm mode (0 off, 1 LN, 2 FiLM);")
    a("// gap: FiLM GAP tap on the st_pack input, MLP after the pass; post: st_post to")
    a("// the PROC slot.  n_layers = 0: st_pre straight to st_pack.")
    a("package st_net_pkg;")
    a("")
    a(f"  localparam int PW_DEPTH = {net['pw_depth']};   // 1024-bit words")
    a(f"  localparam int DW_DEPTH = {net['dw_depth']};   // 288-bit words")
    a(f"  localparam int RQ_DEPTH = {net['rq_depth']};  // 64-bit words")
    a(f"  localparam int ST_N_LAYERS  = {len(net['layers'])};")
    a(f"  localparam int ST_N_PASSES  = {len(net['passes'])};")
    a(f"  localparam int ST_N_REGIONS = {len(net['regions'])};")
    a(f"  localparam int ST_ADD_RQ_BASE = {net['add_rq_base']};")
    a(f"  localparam int ST_NET_W = {net['img_w']};")
    a(f"  localparam int ST_NET_H = {net['img_h']};")
    a("")
    a(f"  localparam logic [1:0] ST_KIND_PW     = 2'd{KIND_PW};")
    a(f"  localparam logic [1:0] ST_KIND_DW     = 2'd{KIND_DW};")
    a(f"  localparam logic [1:0] ST_KIND_IM2COL = 2'd{KIND_IM2COL};")
    a("  localparam logic [1:0] ST_ADD_NONE = 2'd0;   // no aux read")
    a("  localparam logic [1:0] ST_ADD_IN   = 2'd1;   // + requant(aux) before the DW stage")
    a("  localparam logic [1:0] ST_ADD_OUT  = 2'd2;   // + requant(aux) after the PW stage")
    a("  localparam logic [1:0] ST_NORM_OFF  = 2'd0;")
    a("  localparam logic [1:0] ST_NORM_LN   = 2'd1;")
    a("  localparam logic [1:0] ST_NORM_FILM = 2'd2;")
    a(f"  localparam logic [5:0] ST_PT_NONE = 6'd{PT_NONE};")
    a("")
    a("  typedef struct packed {")
    a("    logic [1:0]        kind;      // ST_KIND_*")
    a("    logic [6:0]        cin;       // ROM lanes: 27 for an im2col layer")
    a("    logic [6:0]        cout;")
    a("    logic [1:0]        stride;")
    a("    logic [9:0]        pw_base;")
    a("    logic [9:0]        dw_base;")
    a("    logic [10:0]       rq_base;")
    a("    logic [9:0]        lo, hi;    // clamp, two's complement")
    a("  } st_layer_t;")
    a("")
    a("  typedef struct packed {")
    a("    logic [5:0]        in_point;  // ST_PT_NONE with src_isp")
    a("    logic [5:0]        aux_point; // ST_PT_NONE: no aux read")
    a("    logic [5:0]        out_point;")
    a("    logic              upsample;")
    a("    logic [1:0]        add_mode;  // ST_ADD_*")
    a("    logic [10:0]       add_rq;")
    a("    logic [4:0]        first_layer, n_layers;")
    a(f"    logic [{W_W-1}:0]        in_w, in_h;")
    a("    logic [6:0]        in_c;")
    a(f"    logic [{W_W-1}:0]        out_w, out_h;")
    a("    logic [6:0]        out_c;")
    a("    logic              src_isp, pre_pool, isp_last, gap, post;")
    a("    logic [1:0]        norm;      // ST_NORM_*")
    a("  } st_pass_t;")
    a("")
    a("  typedef struct packed {")
    a("    logic [31:0]       base;")
    a("    logic [9:0]        w, h;")
    a("    logic [6:0]        c;")
    a("    logic [1:0]        elem;      // bytes per element")
    a("    logic [7:0]        pb;        // pixel bytes, roundup16(c * elem)")
    a("  } st_region_t;")
    a("")
    a("  typedef struct packed {")
    a("    logic [23:0]       mant;      // factor = mant * 2**(-k)")
    a("    logic [5:0]        k;")
    a("  } st_add_factor_t;")
    a("")
    a("  function automatic st_layer_t st_layer(input int i);")
    a("    case (i)")
    for lt in net["layers"]:
        a(f"      {lt['index']}: st_layer = '{{kind: 2'd{lt['kind']}, cin: 7'd{lt['cin']}, "
          f"cout: 7'd{lt['cout']}, stride: 2'd{lt['stride']}, pw_base: 10'd{lt['pw_base']}, "
          f"dw_base: 10'd{lt['dw_base']}, rq_base: 11'd{lt['rq_base']}, "
          f"lo: 10'h{lt['lo'] & 0x3FF:03x}, hi: 10'h{lt['hi'] & 0x3FF:03x}}};   // {lt['name']}")
    a("      default: st_layer = '0;")
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
          f"out_point: 6'd{p['out_point']}, upsample: 1'b{int(p['upsample'])},   // {p['name']}")
        a(f"                   add_mode: 2'd{mode}, add_rq: 11'd{p['add_rq']}, "
          f"first_layer: 5'd{p['first_layer']}, n_layers: 5'd{p['n_layers']},")
        a(f"                   in_w: 12'd{p['in_w']}, in_h: 12'd{p['in_h']}, in_c: 7'd{p['in_c']}, "
          f"out_w: 12'd{p['out_w']}, out_h: 12'd{p['out_h']}, out_c: 7'd{p['out_c']},")
        a(f"                   src_isp: 1'b{int(p['src_isp'])}, pre_pool: 1'b{int(p['pre_pool'])}, "
          f"isp_last: 1'b{int(p['isp_last'])}, gap: 1'b{int(p['gap'])}, post: 1'b{int(p['post'])}, "
          f"norm: 2'd{p['norm']}}};")
    a("      default: st_pass = '0;")
    a("    endcase")
    a("  endfunction")
    a("")
    a("  function automatic logic [5:0] st_region_point(input int i);")
    a("    case (i)")
    for k, r in enumerate(net["regions"]):
        a(f"      {k}: st_region_point = 6'd{r['point']};")
    a("      default: st_region_point = 6'd0;")
    a("    endcase")
    a("  endfunction")
    a("")
    a("  function automatic st_region_t st_region(input int pt);")
    a("    case (pt)")
    for r in net["regions"]:
        a(f"      {r['point']}: st_region = '{{base: 32'h{r['base']:08x}, w: 10'd{r['w']}, "
          f"h: 10'd{r['h']}, c: 7'd{r['c']}, elem: 2'd{r['elem']}, pb: 8'd{r['pb']}}};")
    a("      default: st_region = '0;")
    a("    endcase")
    a("  endfunction")
    a("")
    a("  function automatic st_add_factor_t st_add_factor(input int i);")
    a("    case (i)")
    for ad in net["adds"]:
        a(f"      {ad['rq_index']}: st_add_factor = '{{mant: 24'h{ad['mant']:06x}, k: 6'd{ad['k']}}};")
    a("      default: st_add_factor = '0;")
    a("    endcase")
    a("  endfunction")
    a("")
    a("endpackage")
    return "\n".join(o) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    net, pw_words, dw_words, rq_words, wts, m = build(a.manifest)
    (a.out / "st_pw.hex").write_text(hex_lines(pw_words))
    (a.out / "st_dw.hex").write_text(hex_lines(dw_words))
    (a.out / "st_rq.hex").write_text(hex_lines(rq_words))
    (a.out / "st_net.json").write_text(json.dumps(net, indent=1) + "\n")
    (a.out / "st_net_pkg.sv").write_text(sv_pkg(net))
    self_check(net, a.out, wts, m)
    print(f"{a.out}: {len(net['layers'])} layers, {len(net['passes'])} passes, "
          f"PW {net['pw_depth']}, DW {net['dw_depth']}, RQ {net['rq_depth']} words; "
          f"DDR 0x{DDR_BASE:08x}..0x{DDR_BASE + net['region_bytes']:08x} "
          f"({net['region_bytes'] / 1e6:.2f} MB)")
    for p in net["passes"]:
        print(f"  {p['index']:2d} {p['name']:7s} in {p['in_point']} aux {p['aux_point']} "
              f"out {p['out_point']} grid {p['in_w']}x{p['in_h']}x{p['in_c']} -> "
              f"{p['out_w']}x{p['out_h']}x{p['out_c']} norm {p['norm']} gap {int(p['gap'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
