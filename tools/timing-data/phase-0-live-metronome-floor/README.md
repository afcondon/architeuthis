# Phase 0 — Live audio-pipeline floor

**Status:** ✅ passed.  **Date:** 2026-05-21.

## Hypothesis

Live's internal MIDI → instrument → master-bus → audio-track path is
sample-accurate (per Ableton's spec).  If true, anything we record
back into Live will not contribute measurable jitter; it becomes the
neutral substrate for Phase 2+ where we record our own MIDI emissions
played by Live.

## Method

A 1-bar MIDI clip in 4/4 with quarter notes at C3, instrument is a
short rimshot sample.  Looped while recording the master bus into an
audio track inside Live.  Sample rate 48 kHz, 24-bit AIFF.

The Ableton "metronome" widget is unrecordable (it's post-master); a
recorded MIDI clip with a percussive sound is functionally identical
for our purposes — what matters is "Live's clock drives a sound; how
stable is the resulting recording on its own grid?"

## Reproduction

Open Live, set tempo as specified, record a master clip of a sharp
percussive sample triggered by a quarter-note MIDI clip in 4/4 for
the specified duration.  Then:

```
.venv/bin/python analyse.py audio /path/to/recording.aif \
  --bpm 60 --out tools/timing-data/phase-0-live-metronome-floor/60bpm \
  --title "Phase 0 — Live 60 BPM metronome"
```

(repeat with bpm=120 → 120bpm subdir)

## Results

### 60 BPM (n=66 hits, 66 s recording)

| metric         | value           |
|----------------|-----------------|
| stdev          | 3.7 µs          |
| min / max      | -7.3 / +8.4 µs  |
| p50 / p95 / p99 | -0.0 / 5.1 / 7.8 µs |
| drift          | 0.9 ns/event    |
| worst case     | +8.4 µs @ idx 32 |

### 120 BPM (n=212 hits, 106 s recording)

| metric         | value           |
|----------------|-----------------|
| stdev          | 3.7 µs          |
| min / max      | -11.8 / +11.6 µs |
| p50 / p95 / p99 | +0.0 / 5.2 / 8.9 µs |
| drift          | 0.3 ns/event    |
| worst case     | -11.8 µs @ idx 66 |

## Conclusion

**Live's audio pipeline is sample-accurate, BPM-independent.**  Stdev
is identical at both tempos (3.7 µs) — and one sample at 48 kHz is
20.8 µs, so we're seeing *sub-sample* jitter after parabolic
interpolation.

The max excursion is ±12 µs at 120 BPM — half a sample at 48 kHz.
This is at the resolution limit of both Live and our pipeline.

Significance for the rest of the investigation: every later phase
that records Live's master out *inherits this floor*.  Any jitter we
measure is contributed by something upstream of Live — our code,
link-spike, IAC, CoreMIDI, network — not by the recording substrate.
Subtract ~4 µs in quadrature from later phase stdevs if you want a
pure-pipeline reading, but practically it's negligible (three+ orders
of magnitude under the 25 ms we're chasing).

**Acceptance:** <1 ms target → measured 0.004 ms.  ✅ passed.

Next: **Phase 1** — Tidal → MIDI only.  First phase with our code in
the loop.  Same recording substrate; this is when we expect numbers
to start moving.
