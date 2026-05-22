#!/usr/bin/env python3
"""Timing analysis for the purerl-tidal rig.

Run inside the venv at tools/timing-analysis/.venv.  See
docs/timing-investigation-plan.md for the protocol this module supports.

Three entry points:

    analyse.py audio <wav> --bpm <n> --out <dir>
        Detect onsets in a wav file, fit the bpm grid, report offsets.

    analyse.py midi <mid> --bpm <n> --out <dir>
        Parse a MIDI file, fit the bpm grid against note_on times.

    analyse.py synth-click --bpm <n> --duration <s> --out <wav>
        Generate a perfect synthetic metronome click track.  Used to
        validate the pipeline floor (Phase 0a).

Outputs per analysis dir:
    raw.csv         expected_ms, observed_ms, offset_ms
    summary.json    n, mean_ms, stdev_ms, min/max, p50/p95/p99,
                    drift_ms_per_event, worst_idx
    histogram.png   offset distribution
    timeseries.png  offset vs index, with linear-drift overlay
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import sys
from typing import Sequence

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import soundfile as sf


def expected_ioi_ms(bpm: float) -> float:
    return 60_000.0 / bpm


def fit_grid(
    observed_ms: np.ndarray, bpm: float
) -> tuple[float, np.ndarray, np.ndarray]:
    """Fit a fixed-spacing grid to observed onset times.

    The grid step is locked to 60_000 / bpm; we solve only for the
    phase offset that minimises sum of squared (observed - grid)
    distances, with each observed event assigned to its nearest
    integer grid index.

    Returns (phase_ms, assigned_indices, expected_ms_per_event).
    """
    step = expected_ioi_ms(bpm)
    # Initial guess: align to first onset.
    phase = float(observed_ms[0]) % step

    # Iterate a couple of passes — re-assign nearest grid index,
    # re-solve phase as the mean residual.  Converges fast.
    for _ in range(8):
        indices = np.round((observed_ms - phase) / step).astype(np.int64)
        residuals = observed_ms - (phase + indices * step)
        delta = float(residuals.mean())
        if abs(delta) < 1e-9:
            break
        phase += delta

    expected = phase + indices * step
    return phase, indices, expected


def stats(offsets_ms: np.ndarray) -> dict:
    n = len(offsets_ms)
    if n == 0:
        return {"n": 0}
    indices = np.arange(n, dtype=np.float64)
    # Least-squares linear drift: offset = a + b * index.  We report
    # b as drift_ms_per_event.
    A = np.vstack([np.ones(n), indices]).T
    sol, *_ = np.linalg.lstsq(A, offsets_ms, rcond=None)
    intercept_ms, drift_per_event_ms = float(sol[0]), float(sol[1])
    worst_idx = int(np.argmax(np.abs(offsets_ms)))
    return {
        "n": n,
        "mean_ms": float(np.mean(offsets_ms)),
        "median_ms": float(np.median(offsets_ms)),
        "stdev_ms": float(np.std(offsets_ms, ddof=1)) if n > 1 else 0.0,
        "min_ms": float(np.min(offsets_ms)),
        "max_ms": float(np.max(offsets_ms)),
        "p50_ms": float(np.percentile(offsets_ms, 50)),
        "p95_ms": float(np.percentile(offsets_ms, 95)),
        "p99_ms": float(np.percentile(offsets_ms, 99)),
        "intercept_ms": intercept_ms,
        "drift_ms_per_event": drift_per_event_ms,
        "worst_idx": worst_idx,
        "worst_offset_ms": float(offsets_ms[worst_idx]),
    }


def write_artifacts(
    out_dir: pathlib.Path,
    expected_ms: Sequence[float],
    observed_ms: Sequence[float],
    summary: dict,
    title: str,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    expected_ms = np.asarray(expected_ms, dtype=np.float64)
    observed_ms = np.asarray(observed_ms, dtype=np.float64)
    offsets_ms = observed_ms - expected_ms

    with (out_dir / "raw.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["index", "expected_ms", "observed_ms", "offset_ms"])
        for i, (e, o, d) in enumerate(zip(expected_ms, observed_ms, offsets_ms)):
            w.writerow([i, f"{e:.6f}", f"{o:.6f}", f"{d:.6f}"])

    with (out_dir / "summary.json").open("w") as f:
        json.dump({"title": title, **summary}, f, indent=2)

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.hist(offsets_ms, bins=40, color="#444", edgecolor="white")
    ax.axvline(0.0, color="#c00", linewidth=1.0)
    ax.set_xlabel("offset from grid (ms)")
    ax.set_ylabel("count")
    ax.set_title(f"{title} — offset histogram")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_dir / "histogram.png", dpi=150)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(9, 4))
    idx = np.arange(len(offsets_ms))
    ax.scatter(idx, offsets_ms, s=12, color="#444")
    drift_line = summary["intercept_ms"] + summary["drift_ms_per_event"] * idx
    ax.plot(idx, drift_line, color="#c00", linewidth=1.0, label="linear drift")
    ax.axhline(0.0, color="#888", linewidth=0.5)
    ax.set_xlabel("event index")
    ax.set_ylabel("offset from grid (ms)")
    ax.set_title(
        f"{title} — offset over time "
        f"(stdev={summary['stdev_ms']:.3f} ms, drift={summary['drift_ms_per_event']:.4f} ms/evt)"
    )
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_dir / "timeseries.png", dpi=150)
    plt.close(fig)


# -------------------------------------------------------------------------
# Audio onset detection
# -------------------------------------------------------------------------

def detect_audio_onsets_transient(
    audio: np.ndarray,
    sr: int,
    min_separation_s: float,
    threshold_db: float = -30.0,
) -> np.ndarray:
    """Sample-accurate onset detection for clean transients.

    Suitable for metronome clicks, drum samples, and anything with a
    sharp leading edge.  For each candidate onset region we locate the
    first sample where |x| crosses an absolute threshold, then refine
    via parabolic interpolation across three neighbouring envelope
    samples for sub-sample precision.

    `min_separation_s` is enforced so a transient with multiple peaks
    within its tail counts as one onset.

    Returns onset times in seconds.
    """
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    abs_audio = np.abs(audio).astype(np.float64)
    # Light smoothing — a 1-ms box filter knocks single-sample noise
    # spikes flat without smearing transients.
    win = max(1, int(round(0.001 * sr)))
    if win > 1:
        kernel = np.ones(win, dtype=np.float64) / win
        envelope = np.convolve(abs_audio, kernel, mode="same")
    else:
        envelope = abs_audio

    peak = envelope.max()
    if peak <= 0.0:
        return np.array([], dtype=np.float64)
    threshold = peak * (10.0 ** (threshold_db / 20.0))
    min_sep = max(1, int(round(min_separation_s * sr)))

    # Walk forward.  Each onset is the first envelope sample that
    # crosses the threshold after a quiet gap.
    onsets_samples: list[int] = []
    above = envelope > threshold
    i = 0
    n = len(envelope)
    while i < n:
        if above[i] and (not onsets_samples or i - onsets_samples[-1] >= min_sep):
            onsets_samples.append(i)
            i += min_sep
        else:
            i += 1

    # Sub-sample refinement via parabolic interpolation on the
    # envelope's leading-edge slope.  We pick the sample with the
    # steepest forward rise inside a short window after the crossing,
    # then interpolate.
    refine_win = max(1, int(round(0.0005 * sr)))  # 0.5 ms search
    times_s: list[float] = []
    for s in onsets_samples:
        end = min(s + refine_win, n - 2)
        if end <= s + 1:
            times_s.append(s / sr)
            continue
        slope = envelope[s + 1 : end + 1] - envelope[s : end]
        local = int(np.argmax(slope))
        idx = s + local
        # Parabolic interpolation around the peak of the derivative.
        if 1 <= idx < n - 1:
            y0 = envelope[idx - 1]
            y1 = envelope[idx]
            y2 = envelope[idx + 1]
            denom = y0 - 2.0 * y1 + y2
            sub = 0.5 * (y0 - y2) / denom if denom != 0 else 0.0
            times_s.append((idx + sub) / sr)
        else:
            times_s.append(idx / sr)
    return np.asarray(times_s, dtype=np.float64)


def detect_audio_onsets(
    wav_path: pathlib.Path,
    bpm: float,
    method: str = "transient",
) -> tuple[np.ndarray, int]:
    """Return (onset_times_s, sr).

    method="transient" — sample-accurate threshold-crossing detector,
    best for clean material (metronomes, drum hits, isolated notes).

    method="librosa" — spectral-flux onset detection, best for
    musically complex / polyphonic material where transients are not
    individually visible in the time-domain envelope.
    """
    audio, sr = sf.read(str(wav_path), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if method == "transient":
        min_sep_s = 0.5 * 60.0 / bpm  # half an IOI
        onset_times = detect_audio_onsets_transient(audio, sr, min_sep_s)
    elif method == "librosa":
        import librosa  # type: ignore
        onset_frames = librosa.onset.onset_detect(
            y=audio, sr=sr, units="frames", backtrack=True
        )
        onset_times = librosa.frames_to_time(onset_frames, sr=sr)
    else:
        raise ValueError(f"unknown method: {method}")
    return np.asarray(onset_times, dtype=np.float64), sr


def analyse_audio(
    wav_path: pathlib.Path,
    bpm: float,
    out_dir: pathlib.Path,
    title: str = "audio",
    method: str = "transient",
) -> dict:
    onset_s, sr = detect_audio_onsets(wav_path, bpm, method=method)
    if len(onset_s) < 4:
        raise SystemExit(f"too few onsets detected ({len(onset_s)}) in {wav_path}")
    observed_ms = onset_s * 1000.0
    phase, idx, expected_ms = fit_grid(observed_ms, bpm)
    summary = stats(observed_ms - expected_ms)
    summary["bpm"] = bpm
    summary["sample_rate"] = int(sr)
    summary["source"] = str(wav_path)
    write_artifacts(out_dir, expected_ms, observed_ms, summary, title)
    return summary


# -------------------------------------------------------------------------
# MIDI parsing
# -------------------------------------------------------------------------

def extract_midi_note_on_times(midi_path: pathlib.Path) -> np.ndarray:
    """Return note_on times in seconds, in event order."""
    import mido  # type: ignore
    mid = mido.MidiFile(str(midi_path))
    # mid.length and event iteration handle tempo + division.
    times: list[float] = []
    t = 0.0
    for msg in mid:  # iterator emits time-deltas in seconds
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0:
            times.append(t)
    return np.asarray(times, dtype=np.float64)


def analyse_midi(midi_path: pathlib.Path, bpm: float, out_dir: pathlib.Path, title: str = "midi") -> dict:
    times_s = extract_midi_note_on_times(midi_path)
    if len(times_s) < 4:
        raise SystemExit(f"too few note_on events ({len(times_s)}) in {midi_path}")
    observed_ms = times_s * 1000.0
    phase, idx, expected_ms = fit_grid(observed_ms, bpm)
    summary = stats(observed_ms - expected_ms)
    summary["bpm"] = bpm
    summary["source"] = str(midi_path)
    write_artifacts(out_dir, expected_ms, observed_ms, summary, title)
    return summary


# -------------------------------------------------------------------------
# Synthetic click generator (for pipeline self-validation)
# -------------------------------------------------------------------------

def synth_click(bpm: float, duration_s: float, out_wav: pathlib.Path, sr: int = 48000) -> None:
    """Write a perfect click track to wav: sample-accurate impulses on
    the grid, with a short exponentially-decaying noise tail so the
    onset detector has something with spectral content to find.
    """
    n_samples = int(round(duration_s * sr))
    audio = np.zeros(n_samples, dtype=np.float32)
    ioi_samples = int(round(60.0 / bpm * sr))
    # Tail: 5 ms of decaying noise per click.
    tail_len = int(round(0.005 * sr))
    rng = np.random.default_rng(seed=42)
    tail = rng.standard_normal(tail_len).astype(np.float32) * 0.5
    decay = np.exp(-np.arange(tail_len) / (tail_len / 4)).astype(np.float32)
    click = tail * decay

    n_clicks = n_samples // ioi_samples
    for i in range(n_clicks):
        start = i * ioi_samples
        end = min(start + tail_len, n_samples)
        audio[start:end] += click[: end - start]

    audio = np.clip(audio, -0.99, 0.99)
    out_wav.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_wav), audio, sr, subtype="PCM_24")


# -------------------------------------------------------------------------
# CLI
# -------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Timing analysis for purerl-tidal.")
    sub = p.add_subparsers(dest="cmd", required=True)

    pa = sub.add_parser("audio", help="Analyse a wav recording.")
    pa.add_argument("wav", type=pathlib.Path)
    pa.add_argument("--bpm", type=float, required=True)
    pa.add_argument("--out", type=pathlib.Path, required=True)
    pa.add_argument("--title", default="audio")
    pa.add_argument(
        "--method",
        choices=("transient", "librosa"),
        default="transient",
        help="Onset detection method.  'transient' for clean material "
        "(metronome / drums), 'librosa' for polyphonic.",
    )

    pm = sub.add_parser("midi", help="Analyse a MIDI file.")
    pm.add_argument("mid", type=pathlib.Path)
    pm.add_argument("--bpm", type=float, required=True)
    pm.add_argument("--out", type=pathlib.Path, required=True)
    pm.add_argument("--title", default="midi")

    ps = sub.add_parser("synth-click", help="Write a perfect-grid click track.")
    ps.add_argument("--bpm", type=float, required=True)
    ps.add_argument("--duration", type=float, default=60.0)
    ps.add_argument("--sr", type=int, default=48000)
    ps.add_argument("--out", type=pathlib.Path, required=True)

    args = p.parse_args(argv)
    if args.cmd == "audio":
        s = analyse_audio(args.wav, args.bpm, args.out, args.title, method=args.method)
    elif args.cmd == "midi":
        s = analyse_midi(args.mid, args.bpm, args.out, args.title)
    elif args.cmd == "synth-click":
        synth_click(args.bpm, args.duration, args.out, args.sr)
        print(f"wrote {args.out}")
        return 0
    print(json.dumps(s, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
