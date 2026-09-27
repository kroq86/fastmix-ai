"""Spike: is Basic Pitch accurate enough on Suno-like stems to be worth a
TRANSCRIBE feature? (offline, nothing in src/ depends on this)

Preregistered before running:
  C1  synthetic ground truth, note F1 (onset +-50ms, pitch +-50c, no offset),
      default params: bass >= 0.8 -> proceed to MVP; < 0.6 -> close; else inconclusive.
      Poly keys judged separately with the same thresholds.
  C2  Basic Pitch `amplitude` (mean frame activation) as per-note confidence:
      AUC(TP vs FP) >= 0.75 supported, <= 0.6 refuted.
  C3  real Suno stems (no ground truth): chroma cosine(transcription, stem) must
      exceed the same transcription randomly time-shifted. Sanity only, not accuracy.
Controls: two synthetic timbres; a "bleed" condition mixing the real Suno drum
stem at -12 dB. No tuning: defaults + one declared bass config (30-400 Hz).

Run:  <venv>/bin/python spikes/transcribe_basic_pitch.py <stems_dir> <out_dir>
Needs: basic-pitch 0.4.0, mir_eval, pretty_midi, soundfile, librosa (Python 3.11),
and setuptools<81 (resampy still imports pkg_resources).
"""
import json
import sys
import time
from pathlib import Path

import librosa
import mir_eval
import numpy as np
import pretty_midi
import soundfile as sf
from basic_pitch import ICASSP_2022_MODEL_PATH
from basic_pitch.inference import Model, predict

SR = 44100
BPM = 73.0
SIXTEENTH = 60.0 / BPM / 4
SEED = 1234


# ---------- synthetic ground truth ----------

def make_bass_line(rng, bars=24):
    scale = [0, 2, 3, 5, 7, 8, 10]  # natural minor
    root = 28  # E1
    notes, t = [], 0.0
    degree = 0
    end = bars * 16 * SIXTEENTH
    while t < end:
        dur16 = int(rng.choice([2, 2, 4, 4, 6, 8]))
        degree = int(np.clip(degree + rng.choice([-2, -1, 0, 1, 2, 3]), 0, 13))
        pitch = root + 12 * (degree // 7) + scale[degree % 7]
        gap = SIXTEENTH * 0.15
        if rng.random() > 0.12:  # some rests
            notes.append((t, t + dur16 * SIXTEENTH - gap, pitch))
        t += dur16 * SIXTEENTH
    return notes


def make_keys(rng, bars=24):
    roots = [52, 48, 55, 50]  # E3 C3 G3 D3 progression
    notes = []
    for bar in range(bars):
        r = roots[bar % 4]
        minor = bar % 4 in (0, 3)
        chord = [r, r + (3 if minor else 4), r + 7, r + 12]
        t0 = bar * 16 * SIXTEENTH
        if bar % 2 == 0:  # block chord, 2 beats x2
            for k in (0, 8):
                for p in chord:
                    notes.append((t0 + k * SIXTEENTH, t0 + (k + 7) * SIXTEENTH, p))
        else:  # arpeggio 8ths
            for i in range(8):
                p = chord[i % 4] + (12 if i >= 4 and rng.random() < 0.5 else 0)
                notes.append((t0 + 2 * i * SIXTEENTH, t0 + (2 * i + 1.8) * SIXTEENTH, p))
    return notes


def render(notes, timbre, total_s):
    out = np.zeros(int(total_s * SR) + SR)
    for s, e, p in notes:
        f0 = 440.0 * 2 ** ((p - 69) / 12)
        n = int((e - s) * SR)
        tt = np.arange(n) / SR
        if timbre == "saw":  # bandlimited additive saw, ADSR
            y = sum(np.sin(2 * np.pi * f0 * k * tt) / k for k in range(1, 20) if f0 * k < SR / 2)
            env = np.minimum(1, tt / 0.01) * (0.7 + 0.3 * np.exp(-tt / 0.15))
            rel = np.minimum(1, (n - np.arange(n)) / (0.02 * SR))
            y = y * env * rel
        else:  # Karplus-Strong pluck
            period = max(2, int(round(SR / f0)))
            buf = np.random.default_rng(p).uniform(-1, 1, period)
            y = np.empty(n)
            for i in range(n):
                y[i] = buf[i % period]
                buf[i % period] = 0.996 * 0.5 * (buf[i % period] + buf[(i + 1) % period])
            y *= np.minimum(1, (n - np.arange(n)) / (0.01 * SR))
        i0 = int(s * SR)
        out[i0:i0 + n] += 0.25 * y
    return out / (np.max(np.abs(out)) + 1e-9) * 0.8


def notes_to_arrays(notes):
    iv = np.array([[s, e] for s, e, _ in notes])
    hz = np.array([440.0 * 2 ** ((p - 69) / 12) for _, _, p in notes])
    return iv, hz


def evaluate(ref_notes, est_events):
    ref_iv, ref_hz = notes_to_arrays(ref_notes)
    est = [(s, e, p) for s, e, p, *_ in est_events]
    if not est:
        return dict(p=0, r=0, f1=0, f1_offset=0, auc=None, n_est=0, n_ref=len(ref_notes))
    est_iv, est_hz = notes_to_arrays(est)
    p, r, f1, _ = mir_eval.transcription.precision_recall_f1_overlap(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=0.05, offset_ratio=None)
    _, _, f1o, _ = mir_eval.transcription.precision_recall_f1_overlap(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=0.05, offset_ratio=0.2)
    match = mir_eval.transcription.match_notes(
        ref_iv, ref_hz, est_iv, est_hz, onset_tolerance=0.05, offset_ratio=None)
    tp_idx = {j for _, j in match}
    amps = np.array([ev[3] for ev in est_events])
    is_tp = np.array([j in tp_idx for j in range(len(est_events))])
    return dict(p=round(p, 3), r=round(r, 3), f1=round(f1, 3), f1_offset=round(f1o, 3),
                auc=auc(amps[is_tp], amps[~is_tp]), n_est=len(est), n_ref=len(ref_notes),
                amp_tp_median=float(np.median(amps[is_tp])) if is_tp.any() else None,
                amp_fp_median=float(np.median(amps[~is_tp])) if (~is_tp).any() else None)


def auc(pos, neg):
    if len(pos) == 0 or len(neg) == 0:
        return None
    ranks = np.argsort(np.argsort(np.concatenate([pos, neg]))) + 1
    return round((ranks[:len(pos)].sum() - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg)), 3)


# ---------- real-stem sanity (C3) ----------

def chroma_similarity(audio_path, events, rng, n_shuffles=20):
    y, sr = librosa.load(audio_path, sr=22050, mono=True)
    hop = 2048
    C = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop)
    T = C.shape[1]

    def roll(shift):
        R = np.zeros_like(C)
        for s, e, p, a, *_ in events:
            i0, i1 = int((s + shift) * sr / hop), int((e + shift) * sr / hop) + 1
            i0, i1 = i0 % T, min(T, i1 % T if i1 % T > i0 % T else T)
            R[p % 12, i0:i1] += a
        return R

    def cos(R):
        num = (R * C).sum(0)
        den = np.linalg.norm(R, axis=0) * np.linalg.norm(C, axis=0) + 1e-9
        active = np.linalg.norm(R, axis=0) > 0
        return float((num / den)[active].mean()) if active.any() else 0.0

    real = cos(roll(0.0))
    dur = T * hop / sr
    shuffled = [cos(roll(float(rng.uniform(5, dur - 5)))) for _ in range(n_shuffles)]
    return dict(chroma_cos=round(real, 3), shuffled_mean=round(float(np.mean(shuffled)), 3),
                shuffled_max=round(float(np.max(shuffled)), 3))


def grid_hit_rate(events):
    onsets = np.array([e[0] for e in events])
    if len(onsets) == 0:
        return None
    # phase fitted over 16 candidates -- reported as descriptive only
    best = 0
    for ph in np.linspace(0, SIXTEENTH, 16, endpoint=False):
        d = np.abs(((onsets - ph + SIXTEENTH / 2) % SIXTEENTH) - SIXTEENTH / 2)
        best = max(best, float((d < 0.03).mean()))
    return round(best, 3)


def main():
    stems_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    model = Model(ICASSP_2022_MODEL_PATH)
    results = {"synthetic": {}, "suno": {}}

    drums, _ = librosa.load(stems_dir / "2 Drums.wav", sr=SR, mono=True, duration=90)
    configs = {"default": {}, "bass_30_400": dict(minimum_frequency=30, maximum_frequency=400)}

    for part, maker, timbres in [("bass", make_bass_line, ["saw", "pluck"]),
                                 ("keys", make_keys, ["saw", "pluck"])]:
        ref = maker(rng)
        total = ref[-1][1] + 1
        pm = pretty_midi.PrettyMIDI(initial_tempo=BPM)
        inst = pretty_midi.Instrument(0)
        inst.notes = [pretty_midi.Note(100, p, s, e) for s, e, p in ref]
        pm.instruments.append(inst)
        pm.write(str(out_dir / f"synth_{part}_ref.mid"))
        for timbre in timbres:
            clean = render(ref, timbre, total)
            bleed_src = np.resize(drums, len(clean))
            bleed = clean + bleed_src / (np.max(np.abs(bleed_src)) + 1e-9) * 0.8 * 10 ** (-12 / 20)
            for cond, audio in [("clean", clean), ("bleed-12dB", bleed)]:
                wav = out_dir / f"synth_{part}_{timbre}_{cond}.wav"
                sf.write(wav, audio, SR)
                for cname, kw in configs.items():
                    if cname != "default" and part != "bass":
                        continue
                    _, _, ev = predict(str(wav), model, **kw)
                    key = f"{part}/{timbre}/{cond}/{cname}"
                    results["synthetic"][key] = evaluate(ref, ev)
                    print(key, results["synthetic"][key], flush=True)

    for stem, kw in [("3 Bass.wav", configs["bass_30_400"]), ("3 Bass.wav", {}),
                     ("4 Guitar.wav", {}), ("5 Synth.wav", {}), ("7 Woodwinds.wav", {}),
                     ("0 Lead Vocals.wav", {})]:
        t0 = time.time()
        _, midi, ev = predict(str(stems_dir / stem), model, **kw)
        dt = time.time() - t0
        tag = stem.split(" ", 1)[1].replace(".wav", "").replace(" ", "_") + ("_30_400" if kw else "")
        midi.write(str(out_dir / f"suno_{tag}.mid"))
        amps = np.array([e[3] for e in ev]) if ev else np.array([0.0])
        pitches = [e[2] for e in ev]
        pcs = np.bincount([p % 12 for p in pitches], minlength=12) if pitches else np.zeros(12)
        r = dict(n_notes=len(ev), secs=round(dt, 1), notes_per_s=round(len(ev) / 210.6, 2),
                 pitch_range=[int(min(pitches)), int(max(pitches))] if pitches else None,
                 top7_pc_share=round(float(np.sort(pcs)[-7:].sum() / max(1, pcs.sum())), 3),
                 amp_quantiles=[round(float(q), 3) for q in np.quantile(amps, [0.1, 0.5, 0.9])],
                 grid16_hit=grid_hit_rate(ev),
                 **chroma_similarity(stems_dir / stem, ev, rng))
        results["suno"][tag] = r
        print("suno", tag, r, flush=True)

    (out_dir / "results.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
