#!/usr/bin/env python3
"""Check that board RTL artifacts still describe the selected NNgen manifest."""
from __future__ import annotations
import hashlib, json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

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
    print(f"PASS manifest consistency: {profile['layer_count']} layers, {len(byte_lines)} weight bytes")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
