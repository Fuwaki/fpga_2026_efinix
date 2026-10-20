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
                # Bytes 18[7:4], 24[7:4] and 27 together carry the low 16 bits
                # of the capture-side words-per-frame counter.
                # 1280x720 -> 230400 (0x38400, low16 = 0x8400)
                # 1080p    -> 518400 (0x7E900, low16 = 0xE900)
                # 2-lane   -> 115200 (0x1C200, low16 = 0xC200)
                "status": raw[18] & 0x0F,
                "frame_pix_num": (raw[27] << 8)
                                 | ((raw[18] >> 4) << 4)
                                 | (raw[24] >> 4),
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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", default="/dev/ttyUSB2")
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--json", action="store_true", help="emit JSON only")
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
    ok = bool(latest and delta and latest["status"] == 0x0F and
              25000 <= delta["de"] <= 40000 and
              27000 <= delta["hs"] <= 42000 and
              20 <= delta["vs"] <= 40 and
              400 <= delta["slow_hb"] <= 750 and
              180 <= delta["video_hb"] <= 400 and
              1 <= delta["st_tiles"] <= 32 and
              delta["cap_samples"] % 256 == 0 and
              delta["cap_tiles"] == delta["commit_count"] and
              latest["last_cap_addr"] == 255 and
              1200 <= latest["de_width_core_cycles"] <= 1400)
    result = {"ok": ok, "frames": len(got), "latest": latest, "delta": delta}
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
