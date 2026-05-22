# Phase 1 — Tidal sparse, Tidal → IAC → Live → audio

**Status:** ✅ passed.  **Date:** 2026-05-21.

## Hypothesis

A sparse Tidal pattern (one note per cycle) through the full chain
should add <5 ms jitter over Phase 0's recording floor.  This is the
first phase where our code (purerl-tidal pattern eval, BEAM emit,
link-spike, CoreMIDI, IAC) is in the loop.

## Method

Calypso session `Phase1Sparse` — a single Part `bass1Sparse = on
"bass" bass1 (mini "c2")` on IAC ch1.  Live MIDI track listens on
IAC ch1, plays a sharp percussive sample, master recorded into an
audio track.  Same recording substrate as Phase 0 (sample-accurate
floor proven there).

Why we collapsed Phase 1 + Phase 2: Phase 0 demonstrated Live's
audio pipeline is sample-accurate (3.7 µs stdev), so recording audio
of MIDI-driven instrument firing measures the Phase 1 + Phase 2
chain at single-microsecond resolution — no need to separately
instrument MIDI-receive timing via M4L.  We can split later if a
specific phase shows reason to.

Cycle structure: purerl-tidal's default cycle is 4 beats wide.
- 60 BPM → 4 s/cycle → 1 note per 4 s (IOI 4000 ms)
- 120 BPM → 2 s/cycle → 1 note per 2 s (IOI 2000 ms)

## Reproduction

Switch session to `Sessions/Phase1Sparse` (cp into
`Calypso/Generated/Session.purs` + update the persisted
`calypso-session.json`).  Set tempo, fire `bass1Sparse`, record
master out into a Live audio track for ~70 s.  Then:

```
.venv/bin/python analyse.py audio /path/to/recording.aif \
  --bpm 15 \  # for 60 BPM session (4 s IOI)
  --out tools/timing-data/phase-1-tidal-sparse/60bpm
```

Use `--bpm 30` for the 120 BPM session (2 s IOI).

## Results

### 60 BPM (n=18 notes, 72 s recording)

| metric         | value           |
|----------------|-----------------|
| stdev          | 0.13 ms         |
| min / max      | -0.19 / +0.25 ms |
| p50 / p95 / p99 | +0.02 / +0.17 / +0.23 ms |
| drift          | 0.019 ms/event  |
| worst case     | +0.25 ms @ idx 10 |

### 120 BPM (n=37 notes, 74 s recording)

| metric         | value           |
|----------------|-----------------|
| stdev          | 0.47 ms         |
| min / max      | -0.29 / +2.65 ms |
| p50 / p95 / p99 | -0.10 / +0.29 / +1.88 ms |
| drift          | 0.016 ms/event  |
| worst case     | +2.65 ms @ idx 33 |

## Conclusion

**Sub-millisecond jitter on the full chain at sparse rates** —
Tidal → BEAM → link-spike → CoreMIDI → IAC → Live → synth → audio
adds essentially nothing measurable over the recording floor.

| measurement        | stdev   |
|--------------------|---------|
| Phase 0a synth floor | 0.07 ms |
| Phase 0 Live floor   | 0.004 ms |
| Phase 1 60 BPM       | 0.13 ms |
| Phase 1 120 BPM      | 0.47 ms |

**Acceptance:** <5 ms target.  ✅ passed with an order of magnitude
margin.

## Observations worth carrying forward

1. **The 25 ms BEAM-side floor we saw with René yesterday is NOT in
   this path.** Sparse Tidal patterns are essentially perfect through
   the whole rig.  The floor must be emit-rate-specific (Phase 3 will
   test this) or vmod-specific (Phase 4 will test this).

2. **120 BPM stdev is ~6x higher than 60 BPM** (0.47 vs 0.13 ms),
   but the median is only 0.10 ms — the increase is driven by a
   single 2.65 ms outlier near the end of the recording (idx 33 of
   37).  This is the kind of long-tail event a GC pause or BEAM
   scheduler pre-emption would produce.  Worth watching as the
   density increases in later phases — if it scales, it points at
   BEAM scheduler behaviour rather than something structural.

3. **Both runs show ~0.02 ms/event positive drift.**  Cumulative
   over 18 events that's 0.34 ms (60 BPM) and 0.59 ms over 37
   events (120 BPM) — well under what we'd notice musically, but
   measurable.  Could be Link clock drift relative to Live's
   transport, or a rounding asymmetry in the scheduler arithmetic.
   Noting for later — not a Phase 1 concern.

Next: **Phase 3** — dense pattern (16 notes/cycle) at the same
tempo, same chain.  This is the phase the plan doc predicted would
first show the 25 ms floor if it's emit-rate related.  (Skipping
the plan's Phase 2 because Phase 1 above already includes audio —
Phase 0 proved Live's audio adds no measurable variance, so we
don't need a separate Phase 2 unless something downstream surprises
us.)
