#!/usr/bin/env python3
"""Controlled realtime fill-gap matrix (Unit 0 / re-prove after worker).

Requires fastmix-ai already running (Unix socket /tmp/fastmix-ai.sock).

Usage:
  python3 spikes/live_realtime_gap_matrix.py
"""
from __future__ import annotations

import json
import os
import socket
import sys
import time

SOCK = "/tmp/fastmix-ai.sock"
OUT = ".cache/audition/p1_live_realtime_gap_matrix.json"
START = 4_000_000
LENGTH = 100_000  # ~2.27s @ 44.1k — keep ≤10s policy


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


def wait_job(nid_start: int, job_id: int, timeout_s: float = 120.0) -> dict:
    nid = nid_start
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        r = req(nid, "get_job", {"job_id": job_id})
        nid += 1
        st = (r.get("result") or {}).get("status")
        if st in ("succeeded", "failed") or r.get("ok") is False and st != "running":
            return r
        time.sleep(0.05)
    raise TimeoutError(f"job {job_id} did not finish")


def measure_or_poll(nid: int, args: dict) -> tuple[dict, int]:
    r = req(nid, "measure", args)
    nid += 1
    job = (r.get("result") or {}).get("job_id")
    if job is not None and (r.get("result") or {}).get("status") in ("running", "queued"):
        done = wait_job(nid, job)
        return done, nid + 20
    return r, nid


def diag_snapshot(nid: int) -> tuple[dict, int]:
    r = req(nid, "get_live_state")
    d = (r.get("result") or {}).get("audio_diag") or {}
    return d, nid + 1


def reset(nid: int) -> int:
    req(nid, "reset_audio_diag")
    return nid + 1


def cell(name: str, d: dict, extra: dict | None = None) -> dict:
    row = {
        "name": name,
        "max_fill_gap_ms": d.get("max_fill_gap_ms", d.get("max_callback_gap_ms")),
        "buffer_underrun_events": d.get("buffer_underrun_events", d.get("underrun_count")),
        "buffer_low_watermark_frames": d.get("buffer_low_watermark_frames"),
        "audio_fill_count": d.get("audio_fill_count", d.get("audio_callback_count")),
        "command_duration_ms": d.get("command_duration_ms"),
        "max_command_duration_ms": d.get("max_command_duration_ms"),
        "measure_duration_ms": d.get("measure_duration_ms"),
        "audition_duration_ms": d.get("audition_duration_ms"),
        "level_match_duration_ms": d.get("level_match_duration_ms"),
        "trial_duration_ms": d.get("trial_duration_ms"),
    }
    if extra:
        row.update(extra)
    return row


def main() -> int:
    for _ in range(80):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("socket not ready:", SOCK, file=sys.stderr)
        return 1

    nid = 1
    rows: list[dict] = []

    # --- idle play 30s ---
    nid = reset(nid)
    req(nid, "transport", {"action": "play"})
    nid += 1
    time.sleep(30)
    d, nid = diag_snapshot(nid)
    rows.append(cell("idle_play_30s", d, {"audible_glitch": "n/a"}))
    print("idle_play_30s max_fill_gap_ms=", rows[-1]["max_fill_gap_ms"])

    # --- play + get_live_state only ---
    nid = reset(nid)
    time.sleep(2)
    d, nid = diag_snapshot(nid)
    rows.append(cell("play_get_live_state", d))

    # --- play + measure (async when playing) ---
    nid = reset(nid)
    t0 = time.time()
    mr, nid = measure_or_poll(nid, {"start_frame": START, "length_frames": LENGTH})
    wall = (time.time() - t0) * 1000
    d, nid = diag_snapshot(nid)
    rows.append(cell("play_measure", d, {
        "wall_ms": wall,
        "ok": mr.get("ok"),
        "job_status": (mr.get("result") or {}).get("status"),
    }))
    print("play_measure max_fill_gap_ms=", rows[-1]["max_fill_gap_ms"], "measure_duration_ms=", rows[-1]["measure_duration_ms"])

    # --- play + master audition ---
    nid = reset(nid)
    t0 = time.time()
    ar = req(nid, "audition", {
        "target": {"kind": "master", "signal_point": "master_output"},
        "start_frame": START,
        "length_frames": min(LENGTH, 50_000),
        "path": ".cache/audition/gap_matrix_master.wav",
    })
    nid += 1
    job = (ar.get("result") or {}).get("job_id")
    if job is not None and (ar.get("result") or {}).get("status") in ("running", "queued"):
        ar = wait_job(nid, job)
        nid += 20
    wall = (time.time() - t0) * 1000
    d, nid = diag_snapshot(nid)
    rows.append(cell("play_master_audition", d, {"wall_ms": wall, "ok": ar.get("ok")}))

    # --- play + analyze_master_program (offline worker) ---
    nid = reset(nid)
    t0 = time.time()
    an = req(nid, "analyze_master_program", {"start_frame": START, "length_frames": LENGTH})
    nid += 1
    job = (an.get("result") or {}).get("job_id")
    if job is not None and (an.get("result") or {}).get("status") in ("running", "queued"):
        an = wait_job(nid, job)
        nid += 20
    wall = (time.time() - t0) * 1000
    d, nid = diag_snapshot(nid)
    rows.append(cell("play_analyze_master_program", d, {"wall_ms": wall, "ok": an.get("ok")}))
    print("play_analyze max_fill_gap_ms=", rows[-1]["max_fill_gap_ms"])

    # --- play + validate_master_delivery ---
    nid = reset(nid)
    t0 = time.time()
    vq = req(nid, "validate_master_delivery", {
        "start_frame": START,
        "length_frames": LENGTH,
        "profile": {"name": "custom", "target_integrated_lufs": -14, "tolerance_lu": 40, "max_true_peak_dbtp": 6},
    })
    nid += 1
    job = (vq.get("result") or {}).get("job_id")
    if job is not None and (vq.get("result") or {}).get("status") in ("running", "queued"):
        vq = wait_job(nid, job)
        nid += 20
    wall = (time.time() - t0) * 1000
    d, nid = diag_snapshot(nid)
    rows.append(cell("play_validate_master_delivery", d, {"wall_ms": wall, "ok": vq.get("ok")}))

    # --- play + master_limiter_assess ---
    nid = reset(nid)
    ins = req(nid, "insert_effect", {
        "target": {"kind": "master"},
        "kind": "limiter",
        "ceiling_dbfs": -1,
        "threshold_db": -2,
        "release_ms": 50,
    })
    nid += 1
    eid = (ins.get("result") or {}).get("effect_id")
    if eid is None:
        st = req(nid, "get_state")
        nid += 1
        effects = ((st.get("result") or {}).get("project") or {}).get("master_effects") or []
        for e in reversed(effects):
            if e.get("kind") == "limiter":
                eid = e.get("id")
                break
    if eid is not None:
        t0 = time.time()
        asr = req(nid, "master_limiter_assess_and_adjust", {
            "effect_id": eid,
            "start_frame": START,
            "length_frames": min(LENGTH, 50_000),
            "param": "threshold_db",
            "value": -3,
            "constraints": {
                "target_integrated_lufs_min": -60,
                "target_integrated_lufs_max": 0,
                "max_true_peak_dbtp": 6,
                "max_lra_loss_lu": 99,
                "max_crest_factor_loss_db": 99,
                "max_limiter_gr_peak_db": 40,
            },
            "require_human_listening": False,
        })
        nid += 1
        job = (asr.get("result") or {}).get("job_id")
        if job is not None and (asr.get("result") or {}).get("status") in ("running", "queued"):
            asr = wait_job(nid, job, timeout_s=300)
            nid += 20
        wall = (time.time() - t0) * 1000
        d, nid = diag_snapshot(nid)
        rows.append(cell("play_master_limiter_assess", d, {
            "wall_ms": wall,
            "ok": asr.get("ok"),
            "decision": ((asr.get("result") or {}).get("payload") or asr.get("result") or {}).get("decision"),
        }))

    # --- recording blocks heavy ---
    req(nid, "transport", {"action": "stop"})
    nid += 1
    tr = req(nid, "transport", {"action": "record"})
    nid += 1
    blocked = req(nid, "measure", {"start_frame": START, "length_frames": 1000})
    nid += 1
    blocked2 = req(nid, "analyze_master_program", {})
    nid += 1
    rows.append({
        "name": "record_blocks_measure",
        "transport_ok": tr.get("ok"),
        "error": blocked.get("error"),
        "expected": "heavy_command_blocked_while_recording",
    })
    rows.append({
        "name": "record_blocks_analyze_master",
        "error": blocked2.get("error"),
        "expected": "heavy_command_blocked_while_recording",
    })
    req(nid, "transport", {"action": "stop"})
    nid += 1

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({"rows": rows}, f, indent=2)
    print("wrote", OUT)
    for r in rows:
        print(json.dumps(r)[:240])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
