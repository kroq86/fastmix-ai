"""Transcribe melodic stems to note events for FastMix (offline worker).

Usage:  python transcribe_stem.py <out_dir> <wav_path>:<id>:<kind> [...]
        kind = melodic (Basic Pitch) | drums (band-onset heuristic)

Loads Basic Pitch once, then for each stem writes, atomically:
  <out_dir>/<id>.notes.json   {"notes": [[start_s, end_s, midi_pitch, amplitude], ...]}
  <out_dir>/<id>.mid
FastMix polls for the .json files, so each stem appears as soon as it is done.

Post-processing: octave/fifth ghost filter (spikes/transcribe_octave_filter.py).
Amplitude is Basic Pitch's mean frame activation, a ranking signal, not a
calibrated probability.
"""
import json
import os
import sys

import librosa
import numpy as np
import pretty_midi

from basic_pitch import ICASSP_2022_MODEL_PATH
from basic_pitch.inference import Model, predict


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
            if min(e, e2) - max(s, s2) >= 0.5 * min(e - s, e2 - s2):
                ghost = True
                break
        if not ghost:
            kept.append(i)
    return [events[i] for i in sorted(kept)]


# GM percussion notes per band: (name, midi note, low Hz, high Hz)
DRUM_BANDS = [("kick", 36, 30, 120), ("snare", 38, 180, 2500), ("hihat", 42, 7000, 14000)]


def transcribe_drums(wav):
    """Onsets per frequency band -> GM drum hits. Unvalidated heuristic:
    bleed between bands (e.g. kick harmonics in the snare band) produces
    extra hits; amplitude = onset strength relative to the band's loudest."""
    y, sr = librosa.load(wav, sr=22050, mono=True)
    hop = 256
    spec = np.abs(librosa.stft(y, n_fft=2048, hop_length=hop))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    notes = []
    for _, pitch, lo, hi in DRUM_BANDS:
        band = librosa.amplitude_to_db(spec[(freqs >= lo) & (freqs < hi)], ref=np.max)
        env = librosa.onset.onset_strength(S=band, sr=sr, hop_length=hop)
        peaks = librosa.onset.onset_detect(onset_envelope=env, sr=sr, hop_length=hop, units="frames")
        if len(peaks) == 0:
            continue
        ref = np.percentile(env[peaks], 95) + 1e-9
        for f in peaks:
            amp = float(min(1.0, env[f] / ref))
            if amp < 0.15:  # ignore faint bleed
                continue
            t = float(librosa.frames_to_time(f, sr=sr, hop_length=hop))
            notes.append([t, t + 0.08, pitch, amp])
    notes.sort()
    return notes


def main():
    out_dir = sys.argv[1]
    model = Model(ICASSP_2022_MODEL_PATH)
    failures = 0
    for arg in sys.argv[2:]:
        wav, stem_id, kind = arg.rsplit(":", 2)
        try:
            if kind == "drums":
                raw = transcribe_drums(wav)
            else:
                _, _, events = predict(wav, model)
                raw = octave_fifth_filter(events)
            notes = [[round(float(s), 4), round(float(e), 4), int(p), round(float(a), 3)]
                     for s, e, p, a, *_ in raw]
            midi = pretty_midi.PrettyMIDI()
            inst = pretty_midi.Instrument(program=0, is_drum=(kind == "drums"))
            inst.notes = [pretty_midi.Note(velocity=max(1, int(round(127 * a))), pitch=p, start=s, end=e)
                          for s, e, p, a in notes]
            midi.instruments.append(inst)
            midi.write(os.path.join(out_dir, f"{stem_id}.mid"))
            tmp = os.path.join(out_dir, f"{stem_id}.notes.json.tmp")
            with open(tmp, "w") as f:
                json.dump({"notes": notes}, f)
            os.replace(tmp, os.path.join(out_dir, f"{stem_id}.notes.json"))
            print(f"transcribe: {wav} -> {len(notes)} notes", flush=True)
        except Exception as exc:  # keep going with the other stems
            failures += 1
            print(f"transcribe: FAILED {wav}: {exc}", file=sys.stderr, flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
