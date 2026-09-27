"""Spike 4: can transcription F1 be predicted WITHOUT ground truth, from the stem
and Basic Pitch's own output? If yes, apply it to the Suno bass stem.

Training data: BabySlakh bass, conditions A (isolated) and B (Demucs), with the
reference-scored filtered F1 from spike 3 (transcribe_slakh_bass.py).

Features (frozen, no reference needed), on octave/fifth-filtered notes:
  amp_median, low_amp_share (<0.5), overlap_share, removed_share, chroma_cos
Primary: ridge (alpha=1, standardized), leave-one-track-out (A+B of a track
share a fold).
Preregistered:
  estimator: Spearman >= 0.6 and MAE <= 0.10 -> SUPPORTED;
             Spearman < 0.3 or MAE > 0.15 -> REFUTED; else INCONCLUSIVE.
  secondary: logistic A-vs-B classifier, LOTO accuracy >= 0.8 -> SUPPORTED.
  Suno prediction counts only if every feature lies within the Slakh range.

Run:  <venv>/bin/python spikes/transcribe_quality_estimate.py <babyslakh_16k_dir> <spike3_out_dir> <suno_stems_dir>
"""
import json
import sys
from pathlib import Path

import numpy as np
from basic_pitch import ICASSP_2022_MODEL_PATH
from basic_pitch.inference import Model, predict
from scipy.stats import spearmanr
from sklearn.linear_model import LogisticRegression, Ridge
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).parent))
from transcribe_basic_pitch import chroma_similarity  # noqa: E402
from transcribe_octave_filter import count_overlaps, octave_fifth_filter  # noqa: E402

FEATURES = ["amp_median", "low_amp_share", "overlap_share", "removed_share", "chroma_cos"]


def features(wav, model):
    _, _, ev = predict(str(wav), model)
    fev = octave_fifth_filter(ev)
    amps = np.array([e[3] for e in fev]) if fev else np.array([0.0])
    return {
        "amp_median": float(np.median(amps)),
        "low_amp_share": float((amps < 0.5).mean()),
        "overlap_share": count_overlaps(fev) / max(1, len(fev)),
        "removed_share": (len(ev) - len(fev)) / max(1, len(ev)),
        "chroma_cos": chroma_similarity(wav, fev, np.random.default_rng(0), n_shuffles=1)["chroma_cos"],
    }


def main():
    out3, suno_dir = Path(sys.argv[2]), Path(sys.argv[3])
    scores = json.loads((out3 / "results_slakh_bass.json").read_text())
    model = Model(ICASSP_2022_MODEL_PATH)
    rows = []
    for track, r in scores.items():
        for cond, wav in [("A_isolated", out3 / f"{track}_bass_isolated.wav"),
                          ("B_demucs", out3 / "htdemucs" / track / "bass.wav")]:
            f = features(wav, model)
            rows.append({"track": track, "cond": cond, "f1": r[cond]["filtered"]["f1"], **f})
            print(track, cond, {k: round(v, 3) for k, v in f.items()}, "F1", r[cond]["filtered"]["f1"], flush=True)

    X = np.array([[r[k] for k in FEATURES] for r in rows])
    y = np.array([r["f1"] for r in rows])
    cls = np.array([r["cond"] == "B_demucs" for r in rows], dtype=int)
    groups = np.array([r["track"] for r in rows])
    pred, pcls = np.zeros_like(y), np.zeros_like(cls)
    for g in np.unique(groups):
        tr, te = groups != g, groups == g
        pred[te] = make_pipeline(StandardScaler(), Ridge(alpha=1.0)).fit(X[tr], y[tr]).predict(X[te])
        pcls[te] = make_pipeline(StandardScaler(), LogisticRegression()).fit(X[tr], cls[tr]).predict(X[te])
    rho = float(spearmanr(pred, y).statistic)
    mae = float(np.mean(np.abs(pred - y)))
    acc = float((pcls == cls).mean())
    per_feature = {k: round(float(spearmanr(X[:, i], y).statistic), 3) for i, k in enumerate(FEATURES)}

    suno_f = features(suno_dir / "3 Bass.wav", model)
    xs = np.array([[suno_f[k] for k in FEATURES]])
    in_range = {k: bool(X[:, i].min() <= xs[0, i] <= X[:, i].max()) for i, k in enumerate(FEATURES)}
    reg = make_pipeline(StandardScaler(), Ridge(alpha=1.0)).fit(X, y)
    clf = make_pipeline(StandardScaler(), LogisticRegression()).fit(X, cls)
    out = {
        "loto": {"spearman": round(rho, 3), "mae": round(mae, 3), "ab_accuracy": round(acc, 3),
                 "per_feature_spearman_vs_f1": per_feature},
        "suno_bass": {"features": {k: round(v, 3) for k, v in suno_f.items()}, "in_range": in_range,
                      "pred_f1": round(float(reg.predict(xs)[0]), 3),
                      "p_separated_like": round(float(clf.predict_proba(xs)[0, 1]), 3)},
        "rows": rows,
    }
    (out3 / "results_quality_estimate.json").write_text(json.dumps(out, indent=2))
    print(json.dumps({k: out[k] for k in ("loto", "suno_bass")}, indent=2))


if __name__ == "__main__":
    main()
