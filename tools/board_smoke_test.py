#!/usr/bin/env python3
"""Read the optional FPGA telemetry UART and return a machine-checkable result.

Protocol: AA 55, the original video counters, followed by capture/commit
diagnostics and an XOR checksum.  The counters are cumulative snapshots over
a 0.5 s interval, so this tool accepts small clock/USB scheduling jitter.
"""
import argparse
import json
import sys
import time


def frames(port, seconds):
    import serial

    end = time.monotonic() + seconds
    buf = bytearray()
    port.reset_input_buffer()
    while time.monotonic() < end:
        buf.extend(port.read(256))
        while True:
            pos = buf.find(b"\xaa\x55")
            if pos < 0:
                if len(buf) > 1:
                    del buf[:-1]
                break
            if pos:
                del buf[:pos]
            if len(buf) < 48:
                break
            raw = bytes(buf[:48])
            del buf[:48]
            crc = 0
            for b in raw[:46]:
                crc ^= b
            if raw[46] != crc:
                continue
            yield {
                "de": int.from_bytes(raw[2:6], "big"),
                "hs": int.from_bytes(raw[6:10], "big"),
                "vs": int.from_bytes(raw[10:14], "big"),
                "slow_hb": int.from_bytes(raw[14:16], "big"),
                "video_hb": int.from_bytes(raw[16:18], "big"),
                "status": raw[18] & 0x0F,
                "seq": raw[19],
                "st_tiles": int.from_bytes(raw[20:24], "big"),
                "st_busy": bool(raw[24] & 1),
                "de_width_core_cycles": int.from_bytes(raw[25:27], "big"),
                "cap_samples": int.from_bytes(raw[28:32], "big"),
                "cap_tiles": int.from_bytes(raw[32:36], "big"),
                "commit_count": int.from_bytes(raw[36:40], "big"),
                "last_x": int.from_bytes(raw[40:42], "big"),
                "last_y": int.from_bytes(raw[42:44], "big"),
                "last_cap_addr": raw[44],
                "last_commit_addr": raw[45],
                "cpu_heartbeat": (raw[47] << 8) | raw[27],
            }


def decode_vid(got, clk_hz):
    """vid_subsystem telemetry: page = seq & 3, see the TELEM_VID branch in
    rtl/fpga_src_top.v.  Uses the latest frame of each page."""
    pages = {}
    for f in got:
        pages[f["seq"] & 3] = f
    vid = {}
    p = pages.get(0)
    if p:
        vid["display"] = {
            "frame_brightness_sum": p["cap_samples"],
            "brightness_jumps":     p["last_y"],
            "ddr_rd_lat_max":       p["cap_tiles"] >> 16,
            "ddr_rd_lat_last":      p["cap_tiles"] & 0xFFFF,
            "frames_written":       p["commit_count"] & 0xFFFF,
            "frames_read":          p["commit_count"] >> 16,
            "misses":               p["last_x"],
            "late":                 p["last_commit_addr"],
            "comp_bad_lines":       p["st_tiles"] >> 16,
            "comp_resyncs":         p["st_tiles"] & 0xFFFF,
            "writer_skips":         p["last_cap_addr"] & 0x7F,
            "isp_ring_err":         bool(p["last_cap_addr"] & 0x80),
        }
    p = pages.get(1)
    if p:
        vid["camera"] = {
            "cap_frames":   p["cap_samples"] >> 16,
            "cap_lines":    p["cap_samples"] & 0xFFFF,
            "cap_beats":    p["cap_tiles"] >> 16,
            "cap_dropped":  p["cap_tiles"] & 0xFFFF,
            "writer_errors": p["commit_count"] >> 16,
            "isp_dropped":  p["commit_count"] & 0xFFFF,
            "frame_sig":    f"{p['st_tiles']:#010x}",
            "ddr_wr_lat_max": p["last_x"],
            "frames_written": p["last_y"],
            "rel_holes":    p["last_cap_addr"],
            "isp_ring_err": bool(p["last_commit_addr"] & 0x80),
        }
    p = pages.get(2)
    if p:
        n = 1280 * 720 // 4
        sums = [p["cap_samples"], p["cap_tiles"], p["commit_count"], p["st_tiles"]]
        vid["raw"] = {
            # mean raw value of each 2x2 CFA position {row, column} parity
            "mean_00": round(sums[0] / n, 1), "mean_01": round(sums[1] / n, 1),
            "mean_10": round(sums[2] / n, 1), "mean_11": round(sums[3] / n, 1),
            "clipped": p["last_x"] << 4,
            "dark":    p["last_y"] << 4,
            # CSI-2 RX error flags, sticky: {receive, frame_vc0, line_vc0,
            # undersize, ecc2, ecc1, crc, pixel_fifo_full}
            "csi_errors": f"{p['last_commit_addr']:#04x}",
        }
    p = pages.get(3)
    if p:
        vid["selftest"] = {
            "frames_checked": p["cap_samples"] >> 16,
            "bad_frames":     p["cap_samples"] & 0xFFFF,
            "bad_words":      p["cap_tiles"],
            "frames_written": p["commit_count"] >> 16,
            "writer_errors":  p["commit_count"] & 0xFFFF,
            "ring_proto_err": bool(p["last_commit_addr"] & 0x80),
        }
        vid["proc"] = {
            "frames_written": p["last_x"],
            "errors":         p["last_cap_addr"],
            "skipped":        p["last_commit_addr"] & 0x3F,
            "ring_err":       bool(p["last_commit_addr"] & 0x40),
            "layer1_reads":   p["st_tiles"] >> 16,
            "layer1_bad_lines": p["st_tiles"] & 0xFFFF,
            "seq_gap":        p["last_y"],
            # ENABLE_ST_ACCEL builds: bad_words carries the block engine's
            # cycles for the last frame (sys_clk)
            "st_cycles":      p["cap_tiles"],
            "st_fps_bound":   round(clk_hz / p["cap_tiles"], 1) if p["cap_tiles"] else None,
        }
    errs = [vid.get("display", {}).get("isp_ring_err"), vid.get("camera", {}).get("isp_ring_err"),
            vid.get("selftest", {}).get("ring_proto_err"), vid.get("proc", {}).get("ring_err")]
    vid["ok"] = len(pages) == 4 and not any(errs)
    return vid


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", default="/dev/ttyUSB2")
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--json", action="store_true", help="emit JSON only")
    ap.add_argument("--vid", action="store_true",
                    help="decode the vid_subsystem status slots (TELEM_VID=1 builds)")
    ap.add_argument("--clk-mhz", type=float, default=125.0,
                    help="sys_clk of the build (100 before feat/st-fmax)")
    args = ap.parse_args()
    try:
        import serial
        ser = serial.Serial(args.port, 115200, timeout=0.2)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 2
    with ser:
        got = list(frames(ser, args.seconds))
    latest = got[-1] if got else None
    # The RTL counters are cumulative.  Validate the increment between two
    # snapshots (the snapshots are emitted every 0.5 s), not the absolute
    # counter value, which would fail after a few seconds of uptime.
    delta = None
    if len(got) >= 2:
        prev = got[-2]
        delta = {k: latest[k] - prev[k]
                 for k in ("de", "hs", "vs", "slow_hb", "video_hb", "st_tiles",
                           "cap_samples", "cap_tiles", "commit_count")}
    # Board alive: clocks, resets, camera configured, 720p60 on HDMI.
    #   R = {PLLs locked, DDR calibrated, video reset released, camera I2C done}
    #   per 0.5 s: 21600 DE and 22500 HS rising edges, 30 VS, heartbeats
    #   ~283 (74.25 MHz) on both slow and vid_clk_dvi2; one DE is 1280 px
    #   = 17.24 us of sys_clk (1724 cycles at 100 MHz, 2155 at 125 MHz)
    de_cyc = 17.24 * args.clk_mhz
    ok = bool(latest and delta and latest["status"] == 0x0F and
              20000 <= delta["de"] <= 23000 and
              21000 <= delta["hs"] <= 24000 and
              28 <= delta["vs"] <= 32 and
              250 <= delta["slow_hb"] <= 320 and
              250 <= delta["video_hb"] <= 320 and
              0.96 * de_cyc <= latest["de_width_core_cycles"] <= 1.04 * de_cyc)
    result = {"ok": ok, "frames": len(got), "latest": latest, "delta": delta}
    if args.vid and latest is not None:
        result["vid"] = decode_vid(got, args.clk_mhz * 1e6)
        result["ok"] = ok and result["vid"]["ok"]
    if args.json:
        print(json.dumps(result, separators=(",", ":")))
    elif latest is None:
        print(f"FAIL: {args.port} 在 {args.seconds:g}s 内没有收到遥测帧")
    elif delta is None:
        print(f"FAIL: {args.port} 只收到一帧，无法计算计数增量")
    else:
        state = "PASS" if ok else "FAIL"
        print(f"{state}: 帧={len(got)} ΔDE={delta['de']} ΔHS={delta['hs']} "
              f"ΔVS={delta['vs']} Δslow_hb={delta['slow_hb']} "
              f"Δvideo_hb={delta['video_hb']} status=0x{latest['status']:02x} "
              f"ST_tiles={latest['st_tiles']} ΔST={delta['st_tiles']} "
              f"ST_busy={int(latest['st_busy'])} seq={latest['seq']} "
              f"Δcap={delta['cap_samples']} Δtiles={delta['cap_tiles']} "
              f"Δcommit={delta['commit_count']} last_xy=({latest['last_x']},{latest['last_y']})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
