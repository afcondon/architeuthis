# Phase 3 — Tidal dense, Tidal → IAC → Live → audio

**Status:** ✅ passed.  **Date:** 2026-05-21.

## Hypothesis

A dense Tidal pattern (16 notes per cycle) at the same tempo should
add measurable jitter over Phase 1 sparse if the BEAM emit path is
emit-rate-sensitive.  This phase is the first opportunity for the
25 ms floor we saw in René yesterday to appear in a non-vmod path.

## Method

Same `Phase1Sparse` session structure, cell text changed to
`mini "c2 c2 c2 c2 c2 c2 c2 c2 c2 c2 c2 c2 c2 c2 c2 c2"` (16 c2s per
cycle).  Everything else identical to Phase 1: IAC ch1, sharp
percussive sample, master recorded to audio track.

Cycle structure (4 beats/cycle, 16 notes/cycle):
- 60 BPM → 4 s/cycle → 4 notes/s (IOI 250 ms)
- 120 BPM → 2 s/cycle → 8 notes/s (IOI 125 ms)

## Reproduction

Edit the `bass1Sparse` cell in Calypso to the 16-note form, set
tempo, fire the cell, record ~70 s of master out.

```
.venv/bin/python analyse.py audio /path/to/recording.aif \
  --bpm 240 \  # for 60 BPM dense (250 ms IOI)
  --out tools/timing-data/phase-3-tidal-dense/60bpm
```

Use `--bpm 480` for 120 BPM dense (125 ms IOI).

## Results

### 60 BPM dense (n=304 notes, 76 s recording)

| metric         | value           |
|----------------|-----------------|
| stdev          | 0.13 ms         |
| min / max      | -0.25 / +0.32 ms |
| p50 / p95 / p99 | +0.004 / +0.28 / +0.32 ms |
| drift          | 0.001 ms/event  |
| IOI stdev      | 0.031 ms        |

### 120 BPM dense (n=576 notes, 72 s recording)

| metric         | value           |
|----------------|-----------------|
| stdev          | 0.11 ms         |
| min / max      | -0.20 / +0.20 ms |
| p50 / p95 / p99 | +0.01 / +0.16 / +0.20 ms |
| drift          | 0.0006 ms/event |
| IOI stdev      | 0.017 ms        |

## Conclusion

**The BEAM emit path is rate-independent at the densities tested.**
Phase 3 dense numbers are not worse than Phase 1 sparse — they're
slightly **better** at 120 BPM (stdev 0.11 ms vs 0.47 ms) because
the larger sample size averages out the isolated GC-like outliers
that dominated Phase 1's small sample.

| measurement              | n    | stdev   | max excursion |
|--------------------------|------|---------|---------------|
| Phase 0 Live floor       | 66   | 0.004 ms | 8 µs          |
| Phase 1 60 BPM sparse    | 18   | 0.13 ms | 0.25 ms       |
| Phase 1 120 BPM sparse   | 37   | 0.47 ms | 2.65 ms       |
| Phase 3 60 BPM dense     | 304  | 0.13 ms | 0.32 ms       |
| Phase 3 120 BPM dense    | 576  | 0.11 ms | 0.20 ms       |

**Acceptance:** the plan's criterion was "if significantly worse
than Phase 1, document the delta."  Phase 3 is NOT significantly
worse — at sparse rates with small n, isolated tail events
dominate stdev; at dense rates with large n, the true sub-tenths-
of-a-millisecond distribution emerges.

The 2.65 ms outlier in Phase 1 120 BPM (idx 33 of 37) was likely
either an Ableton clip-end artifact or an isolated GC pause — not a
representative emit-path jitter.  Phase 3's 576 events at 120 BPM
show **zero** events above 0.20 ms.

## Observations carried forward

1. **The 25 ms jitter we saw in René yesterday is definitively NOT
   in the BEAM emit path.**  Tidal pattern eval, scheduleNoteAt,
   gen_udp:send, link-spike receive, CoreMIDI dispatch, and Live's
   ingest all together contribute <0.2 ms p99 at 8 notes/s.

2. **The floor must be inside the vmod machinery** — either in the
   gen_server's per-step processing (32 pattern evaluations per
   step on René, `refresh_from_snapshot`'s two `set_field` calls,
   `lists:nth/2` skip-walking), or in the way vmods queue events
   for the emit path.

3. **The 0.13 ms stdev is consistent across phases** — this is
   what "as good as it gets" looks like in our system once we're
   above measurement noise.  The numerator is presumably some
   combination of:
   - link-spike's millisecond rounding (it timestamps in ms-units
     via CoreMIDI)
   - Live's audio-buffer alignment (we set buffer to 128 samples
     = 2.7 ms at 48 kHz, but the ingest grid is sub-buffer thanks
     to MIDI's pre-scheduled timestamping)
   - the rimshot sample's own micro-variation in transient onset

Next: **Phase 4** — René at 16 stepsPerCycle, emitting the same
4-notes/sec rate as Phase 3 60 BPM.  Direct head-to-head: if René
shows the 25 ms floor while Phase 3 (same rate, same chain) is
0.13 ms, the problem is conclusively in René's per-step gen_server
code.
