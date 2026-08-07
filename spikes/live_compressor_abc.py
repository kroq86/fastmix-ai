#!/usr/bin/env python3
"""Live A/B/C evidence client for compressor_assess_and_adjust on 999 stems.

Usage (with fastmix-ai already running --load 999.fastmix.json):
  python3 spikes/live_compressor_abc.py
"""
from __future__ import annotations

import json
import os
import socket
import sys
import time

SOCK = "/tmp/fastmix-ai.sock"
START = 4_000_000
LENGTH = 100_000  # ~2.27s @ 44.1kHz
OUT = ".cache/audition/p1_live_abc.json"


def send(cmd: dict) -> dict:
    # One request per connection — Server holds a single client_fd.
    payload = (json.dumps(cmd, separators=(",", ":")) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(120)
    s.connect(SOCK)
    s.sendall(payload)
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    line = buf.split(b"\n", 1)[0].decode()
    return json.loads(line)


def main() -> int:
    for _ in range(60):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("socket not ready:", SOCK, file=sys.stderr)
        return 1

    summary = send({"id": 1, "cmd": "get_project_summary", "args": {}})
    print("summary ok=", summary.get("ok"), "tracks=", [
        (t["id"], t["name"], t["effect_count"]) for t in summary["result"]["tracks"]
    ])
    drums = next(t for t in summary["result"]["tracks"] if "Drums" in t["name"])
    track_id = drums["id"]

    ins = send({
        "id": 2,
        "cmd": "insert_effect",
        "args": {
            "track_id": track_id,
            "kind": "compressor",
            "threshold_db": -12,
            "ratio": 4,
            "attack_ms": 10,
            "release_ms": 80,
            "knee_db": 6,
            "makeup_db": 0,
            "mix": 1,
        },
    })
    print("insert:", json.dumps(ins)[:400])
    if not ins.get("ok"):
        return 1
    effect_id = ins["result"]["effect_id"]

    baseline = send({
        "id": 3,
        "cmd": "measure",
        "args": {"track_id": track_id, "start_frame": START, "length_frames": LENGTH},
    })
    print("baseline measure:", json.dumps(baseline)[:800])

    # Case A — commit threshold into GR band
    case_a = send({
        "id": 10,
        "cmd": "compressor_assess_and_adjust",
        "args": {
            "track_id": track_id,
            "effect_id": effect_id,
            "start_frame": START,
            "length_frames": LENGTH,
            "param": "threshold_db",
            "value": -24,
            "constraints": {
                "gr_peak_min_db": 0.5,
                "gr_peak_max_db": 24,
                "gr_mean_active_max_db": 20,
                "max_rms_change_db": 20,
                "max_peak_dbfs": 6,
                "max_active_ratio": 1.0,
            },
            "require_human_listening": False,
        },
    })
    print("CASE A:", json.dumps(case_a)[:1200])

    # Soften threshold again so B / C start from a working compressor
    _ = send({
        "id": 11,
        "cmd": "set_effect_param",
        "args": {
            "track_id": track_id,
            "effect_id": effect_id,
            "threshold_db": -18,
        },
    })

    # Case B — extreme change → rolled_back
    case_b = send({
        "id": 20,
        "cmd": "compressor_assess_and_adjust",
        "args": {
            "track_id": track_id,
            "effect_id": effect_id,
            "start_frame": START,
            "length_frames": LENGTH,
            "param": "threshold_db",
            "value": -60,
            "constraints": {
                "gr_peak_min_db": 0,
                "gr_peak_max_db": 2,
                "gr_mean_active_max_db": 1,
                "max_rms_change_db": 0.25,
                "max_peak_dbfs": -6,
                "max_active_ratio": 0.05,
            },
        },
    })
    print("CASE B:", json.dumps(case_b)[:1200])

    after_b = send({
        "id": 21,
        "cmd": "measure",
        "args": {"track_id": track_id, "start_frame": START, "length_frames": LENGTH},
    })
    print("after B re-measure:", json.dumps(after_b)[:800])

    # Case C — attack_ms → needs_human_listening
    case_c = send({
        "id": 30,
        "cmd": "compressor_assess_and_adjust",
        "args": {
            "track_id": track_id,
            "effect_id": effect_id,
            "start_frame": START,
            "length_frames": LENGTH,
            "param": "attack_ms",
            "value": 35,
            "constraints": {
                "gr_peak_min_db": 0,
                "gr_peak_max_db": 40,
                "gr_mean_active_max_db": 40,
                "max_rms_change_db": 40,
                "max_peak_dbfs": 6,
                "max_active_ratio": 1.0,
            },
        },
    })
    print("CASE C:", json.dumps(case_c)[:1400])

    # Minimal realtime note: start play, then measure while playing
    play = send({"id": 40, "cmd": "transport", "args": {"action": "play"}})
    print("transport play:", play.get("ok"), play.get("error"))
    time.sleep(0.3)
    during = send({
        "id": 41,
        "cmd": "measure",
        "args": {"track_id": track_id, "start_frame": START, "length_frames": LENGTH},
    })
    stop = send({"id": 42, "cmd": "transport", "args": {"action": "stop"}})
    print("measure-during-play ok=", during.get("ok"), "stop=", stop.get("ok"))

    evidence = {
        "track": {"id": track_id, "name": drums["name"]},
        "effect_id": effect_id,
        "window": {"start_frame": START, "length_frames": LENGTH},
        "baseline": baseline,
        "case_a_commit": case_a,
        "case_b_rollback": case_b,
        "after_b_remeasure": after_b,
        "case_c_needs_human": case_c,
        "measure_during_play": during,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(evidence, f, indent=2)
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
