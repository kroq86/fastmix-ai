#!/usr/bin/env python3
"""Live A–D evidence for master FX / master compressor on 999 stems.

Usage (with fastmix-ai already running --load 999.fastmix.json):
  python3 spikes/live_master_abcd.py
"""
from __future__ import annotations

import json
import os
import socket
import sys
import time

SOCK = "/tmp/fastmix-ai.sock"
START = 4_000_000
LENGTH = 100_000
OUT = ".cache/audition/p1_live_master_abcd.json"


def send(cmd: dict) -> dict:
    payload = (json.dumps(cmd, separators=(",", ":")) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(300)
    s.connect(SOCK)
    s.sendall(payload)
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.split(b"\n", 1)[0].decode())


def req(nid: int, cmd: str, args: dict | None = None) -> dict:
    return send({"id": nid, "cmd": cmd, "args": args or {}})


_nid = 1


def next_id() -> int:
    global _nid
    n = _nid
    _nid += 1
    return n


def wait_job(job_id: int, timeout_s: float = 180.0) -> dict:
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        r = req(next_id(), "get_job", {"job_id": job_id})
        st = (r.get("result") or {}).get("status")
        if st == "succeeded":
            return r
        if st == "failed" or (r.get("ok") is False and st != "running"):
            return r
        time.sleep(0.05)
    raise TimeoutError(f"job {job_id}")


def call_heavy(cmd: str, args: dict) -> dict:
    """Call measure/audition/assess; poll get_job when transport is playing."""
    r = req(next_id(), cmd, args)
    job = (r.get("result") or {}).get("job_id")
    if job is not None and (r.get("result") or {}).get("status") in ("running", "queued"):
        done = wait_job(job)
        # Prefer assess payload as sync-shaped result for consumers.
        payload = (done.get("result") or {}).get("payload")
        if isinstance(payload, dict):
            return {
                "ok": done.get("ok", True),
                "revision": done.get("revision"),
                "result": payload,
                "job": done.get("result"),
            }
        return done
    return r


def measure(target: dict | None = None) -> dict:
    args: dict = {"start_frame": START, "length_frames": LENGTH}
    if target is not None:
        args["target"] = target
    return call_heavy("measure", args)


def main() -> int:
    for _ in range(80):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("socket not ready:", SOCK, file=sys.stderr)
        return 1

    out: dict = {"start_frame": START, "length_frames": LENGTH, "cases": {}}

    # Ensure playing so fill gaps are measured during heavy work.
    req(next_id(), "transport", {"action": "play"})
    req(next_id(), "reset_audio_diag")

    ins = req(next_id(), "insert_effect", {
        "target": {"kind": "master"},
        "kind": "compressor",
        "threshold_db": -12,
        "ratio": 4,
        "attack_ms": 10,
        "release_ms": 80,
        "knee_db": 6,
        "makeup_db": 0,
        "mix": 1,
    })
    print("insert master compressor:", json.dumps(ins)[:400])
    if not ins.get("ok"):
        return 1
    effect_id = ins["result"]["effect_id"]
    out["effect_id"] = effect_id

    base = measure({"kind": "master", "signal_point": "master_output"})
    print("baseline master_output:", json.dumps(base.get("result") or base)[:500])
    out["baseline"] = base.get("result") or base

    # --- A commit ---
    case_a = call_heavy("master_compressor_assess_and_adjust", {
        "effect_id": effect_id,
        "start_frame": START,
        "length_frames": LENGTH,
        "param": "threshold_db",
        "value": -24,
        "constraints": {
            "gr_peak_min_db": 0.5,
            "gr_peak_max_db": 40,
            "gr_mean_active_max_db": 40,
            "max_rms_change_db": 40,
            "max_peak_dbfs": 6,
            "max_active_ratio": 1.0,
        },
        "require_human_listening": False,
    })
    print("A:", json.dumps(case_a)[:700])
    out["cases"]["A_commit"] = case_a.get("result") or case_a

    # --- B rollback ---
    case_b = call_heavy("master_compressor_assess_and_adjust", {
        "effect_id": effect_id,
        "start_frame": START,
        "length_frames": LENGTH,
        "param": "threshold_db",
        "value": -60,
        "constraints": {
            "gr_peak_min_db": 0,
            "gr_peak_max_db": 2,
            "gr_mean_active_max_db": 1,
            "max_rms_change_db": 0.2,
            "max_peak_dbfs": -6,
            "max_active_ratio": 0.05,
        },
    })
    print("B:", json.dumps(case_b)[:700])
    out["cases"]["B_rollback"] = case_b.get("result") or case_b
    remeasure = measure({"kind": "master", "signal_point": "master_output"})
    out["cases"]["B_remeasure"] = remeasure.get("result") or remeasure

    # --- C needs_human (attack) ---
    # Set a moderate threshold first so objectives can pass.
    req(next_id(), "set_effect_param", {
        "target": {"kind": "master"},
        "effect_id": effect_id,
        "param": "threshold_db",
        "value": -18,
    })
    case_c = call_heavy("master_compressor_assess_and_adjust", {
        "effect_id": effect_id,
        "start_frame": START,
        "length_frames": LENGTH,
        "param": "attack_ms",
        "value": 25,
        "constraints": {
            "gr_peak_min_db": 0,
            "gr_peak_max_db": 40,
            "gr_mean_active_max_db": 40,
            "max_rms_change_db": 40,
            "max_peak_dbfs": 6,
            "max_active_ratio": 1.0,
        },
    })
    print("C:", json.dumps(case_c)[:700])
    out["cases"]["C_needs_human"] = case_c.get("result") or case_c
    # Close human trial so further calls work
    tid = (case_c.get("result") or {}).get("trial_id")
    if tid is not None:
        req(next_id(), "confirm_trial", {"trial_id": tid})

    # --- D path consistency ---
    pre = measure({"kind": "master", "signal_point": "master_pre_fx"})
    post = measure({"kind": "master", "signal_point": "master_post_fx"})
    output = measure({"kind": "master", "signal_point": "master_output"})
    aud = call_heavy("audition", {
        "target": {"kind": "master", "signal_point": "master_output"},
        "start_frame": START,
        "length_frames": LENGTH,
        "path": ".cache/audition/p1_live_master_d_output.wav",
    })
    out["cases"]["D_path"] = {
        "pre": pre.get("result") or pre,
        "post": post.get("result") or post,
        "output": output.get("result") or output,
        "audition": aud.get("result") or aud,
    }
    pre_r = (pre.get("result") or {})
    post_r = (post.get("result") or {})
    out_r = (output.get("result") or {})
    aud_r = (aud.get("result") or {})
    print("D pre rms", pre_r.get("rms_dbfs"), "post", post_r.get("rms_dbfs"), "out", out_r.get("rms_dbfs"), "aud", aud_r.get("rms_dbfs"))

    live = req(next_id(), "get_live_state")
    out["audio_diag"] = (live.get("result") or {}).get("audio_diag")

    req(next_id(), "transport", {"action": "stop"})

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(out, f, indent=2)
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
