#!/usr/bin/env python3
"""Live A–E evidence for master limiter + loudness / delivery QC on 999 stems.

Usage (fastmix-ai already running --load 999.fastmix.json):
  python3 spikes/live_mastering_qc_abcde.py
"""
from __future__ import annotations

import json
import os
import socket
import sys
import time

SOCK = "/tmp/fastmix-ai.sock"
OUT = ".cache/audition/p2_live_mastering_qc_abcde.json"
# Prefer a short representative window when full-program is too slow for interactive runs;
# pass FULL=1 for length_frames=null full-program analysis.
USE_FULL = os.environ.get("FULL", "0") == "1"
START = 4_000_000
LENGTH = 200_000  # ~4.5s @ 44.1k — enough for short-term / windows; FULL=1 for integrated


def send(cmd: dict) -> dict:
    payload = (json.dumps(cmd, separators=(",", ":")) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(600)
    s.connect(SOCK)
    s.sendall(payload)
    buf = b""
    while b"\n" not in buf and len(buf) < 8_000_000:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    text = buf.split(b"\n", 1)[0].decode(errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Tolerate truncated trails / accidental concatenated objects.
        dec = json.JSONDecoder()
        obj, _ = dec.raw_decode(text)
        return obj


_nid = 1


def next_id() -> int:
    global _nid
    n = _nid
    _nid += 1
    return n


def req(cmd: str, args: dict | None = None) -> dict:
    return send({"id": next_id(), "cmd": cmd, "args": args or {}})


def wait_job(job_id: int, timeout_s: float = 500.0) -> dict:
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        r = req("get_job", {"job_id": job_id})
        st = (r.get("result") or {}).get("status")
        if st == "succeeded":
            return r
        if st == "failed" or (r.get("ok") is False and st != "running"):
            return r
        time.sleep(0.1)
    raise TimeoutError(f"job {job_id}")


def call_heavy(cmd: str, args: dict) -> dict:
    r = req(cmd, args)
    if r.get("ok") is False:
        return r
    job = (r.get("result") or {}).get("job_id")
    if job is not None and (r.get("result") or {}).get("status") in ("running", "queued"):
        done = wait_job(job)
        res = done.get("result") or {}
        payload = res.get("payload")
        if isinstance(payload, dict):
            return {
                "ok": done.get("ok", True),
                "revision": done.get("revision"),
                "result": payload,
                "job": res,
            }
        return done
    return r


def find_or_insert_limiter() -> int:
    st = req("get_state", {"level": "summary"})
    # Prefer get_project path via measure of master effects from insert.
    r = req(
        "insert_effect",
        {
            "target": {"kind": "master"},
            "kind": "limiter",
            "ceiling_dbfs": -1.0,
            "threshold_db": -1.0,
            "release_ms": 80,
            "lookahead_ms": 1,
            "link_channels": True,
        },
    )
    if not r.get("ok"):
        # Already have limiters / error — try get_state full
        full = req("get_state")
        effects = ((full.get("result") or {}).get("project") or {}).get("master_effects") or []
        for e in effects:
            if e.get("kind") == "limiter":
                return int(e["id"])
        raise RuntimeError(f"insert limiter failed: {r}")
    eid = (r.get("result") or {}).get("effect_id")
    if eid is None:
        # Some responses only bump revision — re-fetch
        full = req("get_state")
        effects = ((full.get("result") or {}).get("project") or {}).get("master_effects") or []
        for e in reversed(effects):
            if e.get("kind") == "limiter":
                return int(e["id"])
        raise RuntimeError("no limiter id")
    return int(eid)


def window_args() -> dict:
    if USE_FULL:
        return {"start_frame": 0}
    return {"start_frame": START, "length_frames": LENGTH}


def main() -> int:
    for _ in range(80):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("socket not ready:", SOCK, file=sys.stderr)
        return 1

    os.makedirs(".cache/audition", exist_ok=True)
    out: dict = {"use_full": USE_FULL, "cases": {}}

    req("transport", {"action": "stop"})
    eid = find_or_insert_limiter()
    out["effect_id"] = eid

    # E path consistency baseline (measure vs analyze render path)
    print("E path consistency…")
    m = call_heavy("measure", {**window_args(), "target": {"kind": "master", "signal_point": "master_output"}})
    a = call_heavy("analyze_master_program", window_args())
    out["cases"]["E_path"] = {
        "measure_peak": (m.get("result") or {}).get("peak_dbfs"),
        "measure_true_peak": (m.get("result") or {}).get("true_peak_dbtp"),
        "analyze": a.get("result"),
    }

    # A technical commit
    print("A commit…")
    req("set_effect_param", {"effect_id": eid, "threshold_db": -2.0, "ceiling_dbfs": -1.0})
    base = call_heavy("analyze_master_program", window_args())
    il = (base.get("result") or {}).get("integrated_lufs")
    # Wide custom constraints around whatever we measure (+/− 6 LU) so commit is reachable.
    if il is None:
        il = -14.0
    commit = call_heavy(
        "master_limiter_assess_and_adjust",
        {
            "effect_id": eid,
            **window_args(),
            "param": "threshold_db",
            "value": -4.0,
            "constraints": {
                "target_integrated_lufs_min": float(il) - 6,
                "target_integrated_lufs_max": float(il) + 6,
                "max_true_peak_dbtp": 6.0,
                "max_lra_loss_lu": 20,
                "max_crest_factor_loss_db": 20,
                "max_limiter_gr_peak_db": 40,
            },
            "require_human_listening": False,
        },
    )
    out["cases"]["A_commit"] = commit.get("result")

    # B rollback — impossible true-peak
    print("B rollback…")
    rb = call_heavy(
        "master_limiter_assess_and_adjust",
        {
            "effect_id": eid,
            **window_args(),
            "param": "threshold_db",
            "value": -12.0,
            "constraints": {
                "target_integrated_lufs_min": -60,
                "target_integrated_lufs_max": 0,
                "max_true_peak_dbtp": -40.0,
                "max_lra_loss_lu": 99,
                "max_crest_factor_loss_db": 99,
                "max_limiter_gr_peak_db": 40,
            },
            "require_human_listening": False,
        },
    )
    out["cases"]["B_rollback"] = rb.get("result")

    # C needs human — release
    print("C needs_human…")
    # Ensure no open trial
    try:
        req("abort_trial", {"trial_id": 0})
    except Exception:
        pass
    # Close via reject if needed
    hu = call_heavy(
        "master_limiter_assess_and_adjust",
        {
            "effect_id": eid,
            **window_args(),
            "param": "release_ms",
            "value": 120.0,
            "constraints": {
                "target_integrated_lufs_min": -60,
                "target_integrated_lufs_max": 0,
                "max_true_peak_dbtp": 6.0,
                "max_lra_loss_lu": 99,
                "max_crest_factor_loss_db": 99,
                "max_limiter_gr_peak_db": 40,
            },
        },
    )
    out["cases"]["C_needs_human"] = hu.get("result")
    # Clear trial so later cmds work
    tid = (hu.get("result") or {}).get("trial_id")
    if tid is not None:
        req("abort_trial", {"trial_id": tid})

    # D delivery QC
    print("D validate…")
    soft = call_heavy(
        "validate_master_delivery",
        {
            **window_args(),
            "profile": {
                "name": "custom",
                "target_integrated_lufs": -14,
                "tolerance_lu": 40,
                "max_true_peak_dbtp": 6,
                "source": "live evidence permissive product policy",
            },
        },
    )
    fail = call_heavy(
        "validate_master_delivery",
        {
            **window_args(),
            "profile": {
                "name": "custom",
                "target_integrated_lufs": -14,
                "tolerance_lu": 40,
                "max_true_peak_dbtp": -40,
                "source": "synthetic fail fixture",
            },
        },
    )
    out["cases"]["D_qc_passish"] = soft.get("result")
    out["cases"]["D_qc_fail_tp"] = fail.get("result")

    with open(OUT, "w") as f:
        json.dump(out, f, indent=2)
    print("wrote", OUT)
    summary = {}
    for k, v in out["cases"].items():
        if not isinstance(v, dict):
            summary[k] = v
            continue
        summary[k] = v.get("decision") or v.get("status") or ("ok" if "analyze" in v or "measure_peak" in v else v)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
