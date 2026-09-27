"""Spike 2: does an octave/fifth ghost filter fix Basic Pitch on monophonic stems?

Follows spikes/transcribe_basic_pitch.py, which found recall ~1.0 but precision
loss dominated by octave/fifth false positives. The filter was designed after
seeing that data, so it is evaluated here on a held-out set only (new seed,
new generators, new timbres, new bleed source).

Filter (frozen): notes overlapping >= 50% of the shorter one's duration with
|dpitch| mod 12 in {0, 7}, dpitch != 0, conflict; greedy by amplitude desc, the
higher-amplitude note survives.

Preregistered:
  F1  filter benefit: mean dF1 >= +0.05 and no condition drops > 0.02 -> SUPPORTED;
      mean dF1 < +0.02 or any condition drops > 0.05 -> REFUTED; else INCONCLUSIVE.
      Guard: recall must not drop > 0.03 in any condition.
  F2  go gate per part (bass, vocal), filtered F1: >= 0.8 in all conditions -> MVP;
      any < 0.6 -> close; else INCONCLUSIVE.
  Suno bass / lead vocal: descriptive only (overlaps before/after, chroma).

Run:  <venv>/bin/python spikes/transcribe_octave_filter.py <stems_dir> <out_dir>
Same environment as transcribe_basic_pitch.py.
"""
import json
import sys
from pathlib import Path

import librosa
import numpy as np
import pretty_midi
import soundfile as sf
from basic_pitch import ICASSP_2022_MODEL_PATH
from basic_pitch.inference import Model, predict

sys.path.insert(0, str(Path(__file__).parent))
from transcribe_basic_pitch import chroma_similarity, evaluate  # noqa: E402

SR = 44100
BPM = 73.0
SIXTEENTH = 60.0 / BPM / 4
SEED = 98765


def octave_fifth_filter(events):
    order = sorted(range(len(events)), key=lambda i: -events[i][3])
    kept = []
    for i in order:
        s, e, p = events[i][0], events[i][1], events[i][2]
        ghost = False
        for j in kept:
            s2, e2, p2 = events[j][0], events[j][1], events[j][2]
            d = abs(p - p2)
            if d == 0 or d % 12 not in (0, 7):
                continue
            overlap = min(e, e2) - max(s, s2)
            if overlap >= 0.5 * min(e - s, e2 - s2):
                ghost = True
                break
        if not ghost:
            kept.append(i)
    return [events[i] for i in sorted(kept)]


def count_overlaps(events):
    ev = sorted(events, key=lambda x: x[0])
    return sum(1 for i, a in enumerate(ev)
               if any(b[0] < a[1] - 0.02 and b[1] > a[0] + 0.02 for b in ev[i + 1:i + 8]))


# ---------- held-out generators ----------

def make_bass(rng, bars=20):
    scale = [0, 3, 5, 7, 10]  # minor pentatonic
    root = 33  # A1
    notes, t, deg = [], 0.0, 0
    while t < bars * 16 * SIXTEENTH:
        dur16 = int(rng.choice([1, 2, 3, 3, 4, 8]))
        deg = int(np.clip(deg + rng.choice([-2, -1, 1, 2, 5, -5]), 0, 9))
        pitch = root + 12 * (deg // 5) + scale[deg % 5]
        if rng.random() > 0.2:
            notes.append((t, t + dur16 * SIXTEENTH * 0.85, pitch))
        t += dur16 * SIXTEENTH
    return notes


def make_vocal(rng, bars=16):
    scale = [0, 2, 4, 5, 7, 9, 11]
    root = 45  # A2
    notes, t, deg = [], 0.0, 7
    while t < bars * 16 * SIXTEENTH:
        dur16 = int(rng.choice([2, 3, 4, 4, 6, 8]))
        deg = int(np.clip(deg + rng.choice([-2, -1, -1, 1, 1, 2, 3]), 0, 14))
        pitch = root + 12 * (deg // 7) + scale[deg % 7]
        if rng.random() > 0.15:
            notes.append((t, t + dur16 * SIXTEENTH - 0.03, pitch))
        t += dur16 * SIXTEENTH
    return notes


def render(notes, timbre, total_s, vib=False):
    out = np.zeros(int(total_s * SR) + SR)
    for s, e, p in notes:
        f0 = 440.0 * 2 ** ((p - 69) / 12)
        n = int((e - s) * SR)
        tt = np.arange(n) / SR
        cents = 30 * np.sin(2 * np.pi * 5.5 * tt) * np.clip((tt - 0.15) / 0.1, 0, 1) if vib else 0 * tt
        phase = 2 * np.pi * np.cumsum(f0 * 2 ** (cents / 1200)) / SR
        if timbre == "fm":
            index = 0.5 + 2.5 * np.exp(-tt / 0.08)
            y = np.sin(phase + index * np.sin(phase)) * np.exp(-tt / 0.6)
        elif timbre == "organ":
            amps = [1, 0.9, 0.3, 0.6, 0.1, 0.3]
            y = sum(a * np.sin(k * phase) for k, a in enumerate(amps, 1) if f0 * k < SR / 2)
        else:  # formant_a / formant_o: harmonic weights from two vowel formants
            f1, f2 = (700, 1200) if timbre == "formant_a" else (400, 800)
            y = np.zeros(n)
            for k in range(1, 40):
                fk = f0 * k
                if fk >= SR / 2:
                    break
                w = np.exp(-((fk - f1) / 120) ** 2) + 0.6 * np.exp(-((fk - f2) / 150) ** 2) + 0.05 / k
                y += w * np.sin(k * phase)
        att = np.minimum(1, tt / 0.015)
        rel = np.minimum(1, (n - np.arange(n)) / (0.02 * SR))
        i0 = int(s * SR)
        out[i0:i0 + n] += 0.3 * y * att * rel
    return out / (np.max(np.abs(out)) + 1e-9) * 0.8


def main():
    stems_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    model = Model(ICASSP_2022_MODEL_PATH)
    bleeds = {
        "drums-12dB": (librosa.load(stems_dir / "2 Drums.wav", sr=SR, mono=True, offset=60, duration=90)[0], -12),
        "guitar-18dB": (librosa.load(stems_dir / "4 Guitar.wav", sr=SR, mono=True, offset=60, duration=90)[0], -18),
    }
    results = {"synthetic": {}, "suno": {}}

    for part, maker, timbres, vib in [("bass", make_bass, ["fm", "organ"], False),
                                      ("vocal", make_vocal, ["formant_a", "formant_o"], True)]:
        ref = maker(rng)
        total = ref[-1][1] + 1
        for timbre in timbres:
            clean = render(ref, timbre, total, vib)
            conds = {"clean": clean}
            for name, (src, db) in bleeds.items():
                b = np.resize(src, len(clean))
                conds[name] = clean + b / (np.max(np.abs(b)) + 1e-9) * 0.8 * 10 ** (db / 20)
            for cond, audio in conds.items():
                wav = out_dir / f"ho_{part}_{timbre}_{cond}.wav"
                sf.write(wav, audio, SR)
                _, _, ev = predict(str(wav), model)
                raw, filt = evaluate(ref, ev), evaluate(ref, octave_fifth_filter(ev))
                key = f"{part}/{timbre}/{cond}"
                results["synthetic"][key] = {"raw": raw, "filtered": filt}
                print(key, "F1 %.3f -> %.3f  P %.3f -> %.3f  R %.3f -> %.3f" % (
                    raw["f1"], filt["f1"], raw["p"], filt["p"], raw["r"], filt["r"]), flush=True)

    for stem in ["3 Bass.wav", "0 Lead Vocals.wav"]:
        _, _, ev = predict(str(stems_dir / stem), model)
        fev = octave_fifth_filter(ev)
        tag = stem.split(" ", 1)[1].replace(".wav", "").replace(" ", "_")
        pm = pretty_midi.PrettyMIDI(initial_tempo=BPM)
        inst = pretty_midi.Instrument(0)
        inst.notes = [pretty_midi.Note(int(round(127 * a)), p, s, e) for s, e, p, a, *_ in fev]
        pm.instruments.append(inst)
        pm.write(str(out_dir / f"suno_{tag}_filtered.mid"))
        r = {"n_raw": len(ev), "n_filtered": len(fev),
             "overlaps_raw": count_overlaps(ev), "overlaps_filtered": count_overlaps(fev),
             "raw": chroma_similarity(stems_dir / stem, ev, np.random.default_rng(SEED)),
             "filtered": chroma_similarity(stems_dir / stem, fev, np.random.default_rng(SEED))}
        results["suno"][tag] = r
        print("suno", tag, r, flush=True)

    (out_dir / "results_octave_filter.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
