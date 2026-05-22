#!/usr/bin/env python3
"""
Stereo timing analysis — for multi-voice tests where two BEAM voices
are panned hard L/R into a single stereo recording.

Detects onsets in each channel independently, runs the grid-fit pass
on each, and computes the inter-channel offset: for each event whose
nominal target time has a corresponding onset on both channels, how
far apart are the two onsets?

That inter-channel offset is the key signal for multi-voice scheduling
fairness — it tells us whether voice A and voice B stay in lockstep
when firing on the same nominal tick.
"""
import argparse
import json
import pathlib
import statistics
import sys
import tempfile

import numpy as np
import soundfile as sf

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from analyse import detect_audio_onsets_transient, fit_grid


def analyse_channel(audio, sr, bpm, label):
    """Run onset detection + grid-fit on a mono audio array."""
    min_sep_s = 0.5 * 60.0 / bpm
    onset_s = detect_audio_onsets_transient(audio, sr, min_sep_s)
    if len(onset_s) < 4:
        raise SystemExit(f"too few onsets on {label}: {len(onset_s)}")
    observed_ms = np.asarray(onset_s, dtype=np.float64) * 1000.0
    phase, idx, expected_ms = fit_grid(observed_ms, bpm)
    offsets_ms = observed_ms - expected_ms
    n = len(offsets_ms)
    s = sorted(offsets_ms)
    return {
        "label": label,
        "n": n,
        "stdev_ms": float(statistics.pstdev(offsets_ms)),
        "p50_ms": float(s[n // 2]),
        "p95_ms": float(s[int(n * 0.95)]),
        "p99_ms": float(s[int(n * 0.99)]),
        "max_abs_ms": float(max(abs(x) for x in offsets_ms)),
        "observed_ms": observed_ms,
        "expected_ms": expected_ms,
        "idx": idx,
    }


def pair_onsets(obs_l, obs_r, tol_ms):
    """Match L and R onsets that fall within `tol_ms` of each other.
    Returns list of (idx_l, idx_r, offset_ms) for the matched pairs.
    Greedy nearest-neighbour walk; both arrays assumed sorted (they
    are by construction)."""
    pairs = []
    i = j = 0
    while i < len(obs_l) and j < len(obs_r):
        dl = obs_l[i]
        dr = obs_r[j]
        delta = dr - dl
        if abs(delta) <= tol_ms:
            pairs.append((i, j, float(delta)))
            i += 1
            j += 1
        elif delta < 0:
            j += 1
        else:
            i += 1
    return pairs


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("wav")
    p.add_argument("--bpm", type=float, required=True,
                   help="effective event-grid BPM "
                        "(e.g. 240 for 60 BPM x 16 spc x quarter clock)")
    p.add_argument("--tol-ms", type=float, default=30.0,
                   help="L/R onset pairing tolerance "
                        "(default 30 ms — covers any plausible offset)")
    p.add_argument("--out", type=pathlib.Path, required=True)
    args = p.parse_args()

    audio, sr = sf.read(args.wav, dtype="float32", always_2d=True)
    if audio.shape[1] != 2:
        raise SystemExit(
            f"expected stereo, got {audio.shape[1]} channel(s)"
        )
    args.out.mkdir(parents=True, exist_ok=True)

    L = analyse_channel(audio[:, 0], sr, args.bpm, "L (voice A)")
    R = analyse_channel(audio[:, 1], sr, args.bpm, "R (voice B)")

    print(json.dumps({
        "L": {k: v for k, v in L.items() if k not in ("observed_ms", "expected_ms", "idx")},
        "R": {k: v for k, v in R.items() if k not in ("observed_ms", "expected_ms", "idx")},
    }, indent=2))

    pairs = pair_onsets(
        L["observed_ms"].tolist(),
        R["observed_ms"].tolist(),
        args.tol_ms,
    )
    if not pairs:
        print("no L/R onset pairs matched within tolerance")
        return

    deltas = [d for (_, _, d) in pairs]
    s = sorted(deltas)
    n = len(s)
    print()
    print(f"== inter-channel offset (R - L), {n} matched pairs ==")
    print(f"  mean        = {sum(deltas)/n:+.4f} ms")
    print(f"  stdev       = {statistics.pstdev(deltas):.4f} ms")
    print(f"  median      = {s[n//2]:+.4f} ms")
    print(f"  p95 (|x|)   = {sorted([abs(d) for d in deltas])[int(n*0.95)]:.4f} ms")
    print(f"  p99 (|x|)   = {sorted([abs(d) for d in deltas])[int(n*0.99)]:.4f} ms")
    print(f"  max  |x|    = {max(abs(d) for d in deltas):.4f} ms")
    print(f"  unmatched L = {L['n'] - n}")
    print(f"  unmatched R = {R['n'] - n}")

    csv_path = args.out / "pairs.csv"
    with open(csv_path, "w") as f:
        f.write("idx_L,idx_R,L_ms,R_ms,delta_R_minus_L_ms\n")
        for (iL, iR, d) in pairs:
            f.write(f"{iL},{iR},"
                    f"{L['observed_ms'][iL]:.4f},"
                    f"{R['observed_ms'][iR]:.4f},"
                    f"{d:+.4f}\n")
    print(f"\nWrote pair-by-pair CSV → {csv_path}")


if __name__ == "__main__":
    main()
