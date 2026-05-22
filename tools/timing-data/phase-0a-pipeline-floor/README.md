# Phase 0a — pipeline floor

**Status:** ✅ passed.  **Date:** 2026-05-21.

## Hypothesis

Our analysis pipeline can measure inter-onset timing to <1 ms accuracy.
Necessary precondition for the rest of the investigation: if the tool
floor is bigger than the effect we're chasing, we can't see anything.

## Method

Generate a synthetic 60 BPM click track (60 seconds = 60 clicks),
sample-accurate impulses spaced exactly 48000 samples apart at 48 kHz.
Each click has a 5 ms exponentially-decaying noise tail so the onset
detector has spectral content to lock onto.

Run our transient-onset detector against the generated wav and
compare detected onset times against the known-perfect grid.

## Reproduction

```
.venv/bin/python analyse.py synth-click --bpm 60 --duration 60 \
  --out tools/timing-data/phase-0a-pipeline-floor/synth-60bpm.wav

.venv/bin/python analyse.py audio \
  tools/timing-data/phase-0a-pipeline-floor/synth-60bpm.wav \
  --bpm 60 \
  --out tools/timing-data/phase-0a-pipeline-floor \
  --title "Phase 0a — synthetic 60 BPM (pipeline floor)"
```

The wav itself is reproducible from one command and is gitignored.

## Result

| metric                | value         |
|-----------------------|---------------|
| n                     | 60            |
| stdev                 | 0.072 ms      |
| min / max             | -0.009 / +0.547 ms |
| p50                   | -0.009 ms     |
| p95                   | -0.009 ms     |
| p99                   | +0.219 ms     |
| drift                 | -0.001 ms/evt |

The max excursion of +0.55 ms is the *first* click — onset detection
at the leading edge of the recording has no pre-attack envelope to
anchor against, so its parabolic refinement is slightly less
accurate.  All other clicks are within ±0.01 ms.

## Conclusion

**Tool floor is ~0.07 ms stdev, single worst-case outlier 0.55 ms.**
Comfortably under the 1 ms acceptance threshold and three orders of
magnitude under the 25 ms BEAM-side jitter we're investigating.  We
can subtract this as analysis noise from every downstream phase.

Detector choice: the sample-accurate `transient` method (impulse-
threshold-crossing + parabolic refinement) replaced librosa's
spectral-flux detector for this purpose.  Librosa's default 512-sample
hop quantises onset times to ~10 ms frames which is unusable for our
case — librosa stays available via `--method librosa` for any later
phase involving polyphonic / sustained material where time-domain
transient detection won't work.
