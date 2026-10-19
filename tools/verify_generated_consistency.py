#!/usr/bin/env python3
"""Check that board RTL artifacts still describe the selected NNgen manifest."""
from __future__ import annotations
import hashlib, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_st_bias_requant import encode, render  # noqa: E402

def main() -> int:
    profile = json.loads((ROOT / "docs/st_board_profile.json").read_text())
    manifest = Path(profile["manifest"])
    if not manifest.is_absolute():
        manifest = (ROOT / manifest).resolve()
    if not manifest.exists():
        raise SystemExit(f"manifest missing: {manifest}")
    digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
    assert digest == profile["manifest_sha256"], "manifest SHA256 differs from board profile"
    m = json.loads(manifest.read_text())
    names = [x["name"] if isinstance(x, dict) else x for x in m.get("layers", [])]
    selected = profile["layers"]
    assert all(name in names for name in selected), "board profile refers to an absent manifest layer"
    sv = ROOT / profile["rtl"]
    text = sv.read_text()
    cases = re.findall(r"\s+4'd\d+: begin.*?//\s*(.+)$", text, re.M)
    assert cases == selected, f"generated layer order differs: {cases}"
    weights = ROOT / profile["weights_hex"]
    assert weights.exists(), f"generated weights missing: {weights}"
    byte_lines = [x for x in weights.read_text().splitlines() if x.strip() and not x.lstrip().startswith("//")]
    assert len(byte_lines) == profile["weight_bytes"], f"weight bytes={len(byte_lines)}"
    assert len(byte_lines) <= profile["weight_capacity_bytes"]
    accel = ROOT / "rtl/st_accel/st_accel.v"
    assert "st_w8_sel_weights_generated.hex" in accel.read_text()
    xml = (ROOT / "fpga_src.xml").read_text()
    assert not re.search(r"design_file=.*\.hex", xml, re.I), "hex initialized data registered as design file"
    assert "rtl/st_accel/st_layer_sel_generated.v" in xml, "project XML does not use the generated layer selector"
    assert "rtl/st_accel/st_layer_sel.v" not in xml, "project XML still uses the hand-written layer selector"
    meta = json.loads((ROOT / "config/weights/st_w8_sel_meta.json").read_text())
    bias, requant = encode(meta)
    assert (ROOT / "rtl/st_accel/st_w8_bias.hex").read_text() == render(bias), "bias hex differs from metadata"
    assert (ROOT / "rtl/st_accel/st_w8_requant.hex").read_text() == render(requant), "requant hex differs from metadata"
    print(f"PASS manifest consistency: {profile['layer_count']} layers, {len(byte_lines)} weight bytes")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
