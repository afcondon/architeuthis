# tools/timing-analysis

Python tooling for the rig-wide timing investigation.  See
`docs/timing-investigation-plan.md` for the full protocol; this is
the analysis substrate every phase runs through.

## Setup (one-time)

```
python3 -m venv .venv
.venv/bin/pip install librosa matplotlib mido soundfile numpy scipy
```

Library versions are pinned by whatever resolves; the venv directory
is gitignored.

## Use

```
# Generate a perfect synthetic click track (pipeline self-test).
.venv/bin/python analyse.py synth-click --bpm 60 --duration 60 \
  --out /tmp/click.wav

# Analyse an audio recording against a known BPM grid.
.venv/bin/python analyse.py audio /path/to/recording.wav \
  --bpm 60 --out /path/to/output/dir

# Analyse a MIDI file.
.venv/bin/python analyse.py midi /path/to/file.mid \
  --bpm 60 --out /path/to/output/dir
```

Outputs per analysis dir:

- `raw.csv` — per-event expected / observed / offset (ms)
- `summary.json` — n, mean, stdev, min/max, percentiles, drift
- `histogram.png` — offset distribution
- `timeseries.png` — offset over time with drift overlay

## Detector choice

`--method transient` (default) — sample-accurate impulse-threshold
+ parabolic refinement.  Best for clean material: metronome clicks,
isolated drum hits, sharp transient samples.  Floor ~0.07 ms.

`--method librosa` — spectral-flux onset detection.  Best for
polyphonic / sustained material where time-domain transients aren't
individually visible.  Floor ~3 ms (limited by 512-sample hop).
