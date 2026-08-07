#!/usr/bin/env python3
"""Live A–D evidence for bus/send routing on 999 stems.

Usage (with fastmix-ai already running --load 999.fastmix.json):
  python3 spikes/live_routing_abcd.py
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
OUT = ".cache/audition/p1_live_routing_abcd.json"


def send(cmd: dict) -> dict:
    payload = (json.dumps(cmd, separators=(",", ":")) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(180)
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


def req(nid: int, cmd: str, args: dict | None = None) -> dict:
    return send({"id": nid, "cmd": cmd, "args": args or {}})


def main() -> int:
    for _ in range(80):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("socket not ready:", SOCK, file=sys.stderr)
        return 1

    summary = req(1, "get_project_summary")
    tracks = summary["result"]["tracks"]
    print("tracks=", [(t["id"], t["name"], t["effect_count"]) for t in tracks])
    drums = next(t for t in tracks if "Drums" in t["name"])
    bass = next(t for t in tracks if "Bass" in t["name"])
    lead = next(t for t in tracks if "Lead Vocals" in t["name"])

    # Fresh Drum Bus + Delay Bus for this session (idempotent-ish: add always)
    drum_bus = req(2, "add_bus", {"name": "Drum Bus"})
    print("add Drum Bus:", json.dumps(drum_bus)[:300])
    if not drum_bus.get("ok"):
        return 1
    drum_bus_id = drum_bus["result"]["bus_id"]

    delay_bus = req(3, "add_bus", {"name": "Delay Bus"})
    print("add Delay Bus:", json.dumps(delay_bus)[:300])
    if not delay_bus.get("ok"):
        return 1
    delay_bus_id = delay_bus["result"]["bus_id"]

    s1 = req(4, "add_send", {
        "source_track_id": drums["id"],
        "destination_bus_id": drum_bus_id,
        "gain_db": 0,
        "tap": "post_fader",
    })
    s2 = req(5, "add_send", {
        "source_track_id": bass["id"],
        "destination_bus_id": drum_bus_id,
        "gain_db": 0,
        "tap": "post_fader",
    })
    print("sends:", s1.get("ok"), s2.get("ok"))

    ins = req(6, "insert_effect", {
        "bus_id": drum_bus_id,
        "kind": "compressor",
        "threshold_db": -12,
        "ratio": 4,
        "attack_ms": 10,
        "release_ms": 80,
        "knee_db": 6,
        "makeup_db": 0,
        "mix": 1,
    })
    print("insert bus compressor:", json.dumps(ins)[:400])
    if not ins.get("ok"):
        return 1
    effect_id = ins["result"]["effect_id"]

    baseline_bus = req(7, "measure", {
        "target": {"kind": "bus", "bus_id": drum_bus_id, "signal_point": "bus_post_fx"},
        "start_frame": START,
        "length_frames": LENGTH,
    })
    baseline_master = req(8, "measure", {
        "start_frame": START,
        "length_frames": LENGTH,
    })
    print("baseline bus signal_point=", baseline_bus.get("result", {}).get("signal_point"))
    print("baseline bus:", json.dumps(baseline_bus)[:700])

    # --- Case A: commit threshold ---
    case_a = req(10, "bus_compressor_assess_and_adjust", {
        "bus_id": drum_bus_id,
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
            "max_master_rms_change_db": 20,
            "max_master_peak_dbfs": 6,
            "max_active_ratio": 1.0,
        },
        "require_human_listening": False,
    })
    print("CASE A:", json.dumps(case_a)[:1400])

    # Soften for B/C
    _ = req(11, "set_effect_param", {
        "bus_id": drum_bus_id,
        "effect_id": effect_id,
        "threshold_db": -18,
    })

    # --- Case B: rollback ---
    case_b = req(20, "bus_compressor_assess_and_adjust", {
        "bus_id": drum_bus_id,
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
            "max_master_rms_change_db": 0.25,
            "max_master_peak_dbfs": -6,
            "max_active_ratio": 0.05,
        },
    })
    print("CASE B:", json.dumps(case_b)[:1400])

    after_b = req(21, "measure", {
        "target": {"kind": "bus", "bus_id": drum_bus_id, "signal_point": "bus_post_fx"},
        "start_frame": START,
        "length_frames": LENGTH,
    })
    print("after B re-measure:", json.dumps(after_b)[:800])

    # --- Case C: attack → needs_human_listening ---
    case_c = req(30, "bus_compressor_assess_and_adjust", {
        "bus_id": drum_bus_id,
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
            "max_master_rms_change_db": 40,
            "max_master_peak_dbfs": 6,
            "max_active_ratio": 1.0,
        },
    })
    print("CASE C:", json.dumps(case_c)[:1600])

    # --- Case D: delay return (unmute dry lead; send to 100% wet delay bus) ---
    _ = req(39, "set_track_param", {"track_id": lead["id"], "mute": False})
    delay_ins = req(40, "insert_effect", {
        "bus_id": delay_bus_id,
        "kind": "delay",
        "time_ms": 180,
        "feedback": 0.25,
        "damping": 0.4,
        "mix": 1.0,
    })
    print("insert delay:", json.dumps(delay_ins)[:400])
    if not delay_ins.get("ok"):
        return 1

    vocal_send = req(41, "add_send", {
        "source_track_id": lead["id"],
        "destination_bus_id": delay_bus_id,
        "gain_db": -6,
        "tap": "post_fader",
    })
    print("vocal send:", json.dumps(vocal_send)[:300])
    if not vocal_send.get("ok"):
        return 1
    vocal_send_id = vocal_send["result"]["send_id"]

    # Ensure send enabled for wet measure
    _ = req(41, "set_send_param", {"send_id": vocal_send_id, "enabled": True})

    dry_only = req(42, "measure", {
        "target": {"kind": "track", "track_id": lead["id"]},
        "start_frame": START,
        "length_frames": LENGTH,
    })
    master_with_send = req(43, "measure", {
        "start_frame": START,
        "length_frames": LENGTH,
    })
    bus_wet = req(44, "measure", {
        "target": {"kind": "bus", "bus_id": delay_bus_id, "signal_point": "bus_post_fx"},
        "start_frame": START,
        "length_frames": LENGTH,
    })

    _ = req(45, "set_send_param", {
        "send_id": vocal_send_id,
        "enabled": False,
    })
    master_send_off = req(46, "measure", {
        "start_frame": START,
        "length_frames": LENGTH,
    })
    bus_disabled = req(47, "measure", {
        "target": {"kind": "bus", "bus_id": delay_bus_id, "signal_point": "bus_post_fx"},
        "start_frame": START,
        "length_frames": LENGTH,
    })
    dry_after = req(48, "measure", {
        "target": {"kind": "track", "track_id": lead["id"]},
        "start_frame": START,
        "length_frames": LENGTH,
    })
    print("CASE D dry track rms=", dry_only.get("result", {}).get("rms_dbfs"),
          "master wet=", master_with_send.get("result", {}).get("rms_dbfs"),
          "master dry=", master_send_off.get("result", {}).get("rms_dbfs"),
          "bus wet=", bus_wet.get("result", {}).get("rms_dbfs"),
          "bus off=", bus_disabled.get("result", {}).get("rms_dbfs"))

    # Assert no dry duplication on return: delay mix=1; enabling send adds wet (bus active)
    # Disabling send zeros bus wet while track dry measure stays.

    routing = req(50, "get_routing_state")
    print("routing buses=", len(routing.get("result", {}).get("buses", [])))

    # Realtime proxy while playing
    play = req(60, "transport", {"action": "play"})
    time.sleep(1.0)
    live1 = req(61, "get_live_state")
    time.sleep(1.5)
    live2 = req(62, "get_live_state")
    during = req(63, "measure", {
        "target": {"kind": "bus", "bus_id": drum_bus_id, "signal_point": "bus_post_fx"},
        "start_frame": START,
        "length_frames": LENGTH,
    })
    stop = req(64, "transport", {"action": "stop"})
    print("play/measure/stop:", play.get("ok"), during.get("ok"), stop.get("ok"))

    def diag(live: dict) -> dict:
        r = live.get("result") or {}
        ad = r.get("audio_diag") or {}
        return {
            "audio_callback_count": ad.get("audio_callback_count", r.get("audio_callback_count")),
            "max_callback_gap_ms": ad.get("max_callback_gap_ms", r.get("max_callback_gap_ms")),
            "underrun_count": ad.get("underrun_count", r.get("underrun_count")),
        }

    print("live1 diag:", diag(live1))
    print("live2 diag:", diag(live2))

    evidence = {
        "sources": {
            "drums": {"id": drums["id"], "name": drums["name"]},
            "bass": {"id": bass["id"], "name": bass["name"]},
            "lead": {"id": lead["id"], "name": lead["name"]},
        },
        "drum_bus_id": drum_bus_id,
        "delay_bus_id": delay_bus_id,
        "effect_id": effect_id,
        "window": {"start_frame": START, "length_frames": LENGTH},
        "baseline_bus": baseline_bus,
        "baseline_master": baseline_master,
        "case_a_commit": case_a,
        "case_b_rollback": case_b,
        "after_b_remeasure": after_b,
        "case_c_needs_human": case_c,
        "case_d_delay": {
            "track_dry": dry_only,
            "master_with_send": master_with_send,
            "bus_wet": bus_wet,
            "master_send_off": master_send_off,
            "bus_disabled": bus_disabled,
            "track_dry_after": dry_after,
            "delay_mix": 1.0,
        },
        "routing_state": routing,
        "live1": live1,
        "live2": live2,
        "measure_during_play": during,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(evidence, f, indent=2)
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
