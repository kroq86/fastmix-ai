"""Spike 3: Basic Pitch (+ frozen octave/fifth filter) on real sample-library bass
with aligned ground-truth MIDI (BabySlakh, 20 tracks, CC BY 4.0).

Conditions:
  A  isolated rendered bass stem(s) from Slakh (clean instrument)
  B  bass separated from the full mix by Demucs htdemucs (separation artifacts +
     bleed; assumed Suno-like, not established)
Reference = union of all rendered Slakh stems with inst_class == "Bass", each
shifted to its SOUNDING octave: Slakh bass MIDI is written an octave above what
the patches play (found in the first run, which is INVALID; confirmed with pYIN,
independent of Basic Pitch). Per stem: shift = 12*round(median(pyin - midi)/12),
accepted only with >= 20 voiced notes and >= 70% of deltas within +-1 of shift;
otherwise the track is excluded as "reference undetermined".

Preregistered (same thresholds as spike 2):
  filter: mean dF1 >= +0.05 and no track drops > 0.02 -> SUPPORTED;
          mean dF1 < +0.02 or any track drops > 0.05 -> REFUTED; else INCONCLUSIVE.
  gate:   median filtered F1 over tracks in condition B >= 0.8 -> MVP (bass);
          < 0.6 -> close; else INCONCLUSIVE.

Run:  <venv>/bin/python spikes/transcribe_slakh_bass.py <babyslakh_16k_dir> <out_dir>
Extra deps over the other transcription spikes: demucs, pyyaml.
"""
import json
import subprocess
import sys
from pathlib import Path

import librosa
import numpy as np
import pretty_midi
import soundfile as sf
import yaml
from basic_pitch import ICASSP_2022_MODEL_PATH
from basic_pitch.inference import Model, predict

sys.path.insert(0, str(Path(__file__).parent))
from transcribe_basic_pitch import evaluate  # noqa: E402
from transcribe_octave_filter import octave_fifth_filter  # noqa: E402


def sounding_shift(y, sr, notes):
    f0, voiced, _ = librosa.pyin(y, fmin=25, fmax=500, sr=sr, frame_length=2048)
    times = librosa.times_like(f0, sr=sr)
    deltas = []
    for n in notes:
        if n.end - n.start < 0.12:
            continue
        m = (times > n.start + 0.04) & (times < n.end - 0.02) & voiced
        if m.sum() >= 3:
            deltas.append(float(np.median(librosa.hz_to_midi(f0[m]))) - n.pitch)
    if len(deltas) < 20:
        return None
    shift = 12 * round(float(np.median(deltas)) / 12)
    return shift if np.mean(np.abs(np.array(deltas) - shift) <= 1) >= 0.7 else None


def load_bass(track_dir):
    meta = yaml.safe_load((track_dir / "metadata.yaml").read_text())
    # BabySlakh metadata says audio_rendered: false even for stems whose wav/mid
    # exist and are non-silent, so file presence + level decides instead.
    ids = [sid for sid, st in meta["stems"].items()
           if st.get("inst_class") == "Bass"
           and (track_dir / "stems" / f"{sid}.wav").exists()
           and (track_dir / "MIDI" / f"{sid}.mid").exists()]
    ref, audio, sr = [], None, None
    for sid in ids:
        y, sr = sf.read(track_dir / "stems" / f"{sid}.wav", always_2d=True)
        y = y.mean(1)
        if np.max(np.abs(y)) < 10 ** (-60 / 20):
            continue
        notes = [n for inst in pretty_midi.PrettyMIDI(str(track_dir / "MIDI" / f"{sid}.mid")).instruments
                 for n in inst.notes]
        shift = sounding_shift(y, sr, notes)
        if shift is None:
            return None, None
        ref += [(n.start, n.end, n.pitch + shift) for n in notes]
        audio = y if audio is None else audio[:len(y)] + y[:len(audio)]
    return sorted(ref), (audio, sr)


def main():
    root, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    model = Model(ICASSP_2022_MODEL_PATH)
    results = {}
    for track in sorted(p for p in root.iterdir() if p.name.startswith("Track")):
        ref, stem = load_bass(track)
        if not ref:
            print(track.name, "no bass stem or reference undetermined, excluded", flush=True)
            continue
        iso = out_dir / f"{track.name}_bass_isolated.wav"
        sf.write(iso, stem[0], stem[1])
        sep = out_dir / "htdemucs" / track.name / "bass.wav"
        if not sep.exists():
            mix = out_dir / f"{track.name}.wav"
            mix.symlink_to(track / "mix.wav") if not mix.exists() else None
            subprocess.run([sys.executable, "-m", "demucs", "-n", "htdemucs", "--two-stems", "bass",
                            "-o", str(out_dir), str(mix)], check=True, capture_output=True)
        r = {"n_ref": len(ref)}
        for cond, wav in [("A_isolated", iso), ("B_demucs", sep)]:
            _, _, ev = predict(str(wav), model)
            r[cond] = {"raw": evaluate(ref, ev), "filtered": evaluate(ref, octave_fifth_filter(ev))}
        results[track.name] = r
        print(track.name, r["n_ref"], {c: (r[c]["raw"]["f1"], r[c]["filtered"]["f1"]) for c in
                                       ("A_isolated", "B_demucs")}, flush=True)
    (out_dir / "results_slakh_bass.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
