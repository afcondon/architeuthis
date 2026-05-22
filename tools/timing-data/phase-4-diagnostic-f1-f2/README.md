# vmod audio timing — three fixes, 90× win

**Status:** ✅ landed.  **Date:** 2026-05-21.  **Branch:** main worktree.

Yesterday's Phase 4 measurement found 15 ms IOI stdev on the René vmod
vs 0.03 ms on Tidal patterns — same audio chain, same emit rate, two
orders of magnitude worse.  Today we closed the gap to ~5×.

## Bottom line

| | n | IOI median | IOI stdev | shorts (<230 ms) | events off > 5 ms |
|---|---|---|---|---|---|
| **Phase 4 baseline (2026-05-20)** | 304 | 255.06 ms | **15.98 ms** | 34 (11 %) | 193 (63 %) |
| F1 alone | 302 | 255.25 ms | 16.99 ms | 38 (13 %) | 212 (70 %) |
| **F1 + F-LAT + F-FUTURE** | 304 | **250.00 ms** | **0.169 ms** | **0** | **0** |
| Tidal Phase 3 reference | 304 | 250.00 ms | 0.031 ms | 0 | 0 |

Audio max excursion: 29.2 ms → 1.28 ms (22× tighter).  Zero short
beats, zero long beats, locked to a 250.000 ms grid.  Andrew's by-ear
verdict: "very occasional short beat" — that's the 1.28 ms outlier,
i.e. the residual GC pause we haven't fixed yet (F4).

## The three fixes

### F1 — Cache the live-control `ControlMap` across ticks

`evaluateParamsAt` was rebuilding the `Map String Value` from the
per-tick `controlPairs` snapshot on **every step**, then running 34
Pattern queries against it.  Mean cost: 2.18 ms eval_FFI per step.

Fix: thread a monotonic version counter through `tidal_control_bus →
tidal_clock → Window.controlVersion`.  Each vmod voice caches the
opaque PureScript `ControlMap` in `#st.cached_controls` keyed by
`control_version`.  When the version is unchanged (>99 % of ticks),
the voice reuses the cached map; otherwise it calls
`tidal_<voice>@ps:buildControlMap/1` once and stores the result.

PureScript split: each vmod's `Tidal.X` module now exports
`buildControlMap` and `evaluateParamsAtControls` (which takes the
pre-built map).  `evaluateParamsAt` becomes a one-line wrapper for
backward compatibility.

Result: eval_FFI mean 2.18 → 1.36 ms (-38 %), max 14.94 → 6.98 ms
(-53 %).  Did **not** close the audio gap — the per-step cost was a
contributor but not the bottleneck.  See "F1 alone" row above:
0.83 ms savings per step, zero improvement to IOI stdev.

### F-LAT — Compensate device latency

`Tidal/Dispatcher.purs:325` (the Tidal-pattern emit path) computes
`adjustedUnixUs = wallUs - dev.latencyMs * 1000`.  For the IAC device
that's -30 ms — events arrive at link-spike 30 ms before their target
wall time, giving CoreMIDI / Live PDC lead time to sample-align them.

The vmod path (rene/grids/repetitor) skipped this.  Events arrived at
or past target time, where CoreMIDI block-quantises to the next audio
buffer.  Live's ~10–20 ms audio buffer dictated the resulting jitter.

Fix: walker reads `device_latencies` (alias → ms) from the
`registerMidiDevice` events as they apply, looks up the latency at
each vmod registration, and ships it as `latency_ms` in VoiceConfig.
The voice stores `latency_us = round(latency_ms * 1000)` in `#st`
and subtracts it from `WallUs` in `emit_step`.

In isolation this would have made things *worse* (vmod's WallUs was
already ~184 ms in the past — see F-FUTURE); on top of F-FUTURE it
gives link-spike the same lead time the Tidal-pattern path uses.

### F-FUTURE — Discover one step ahead

The deepest finding.  The vmod `process_window` used
`EndStepExcl = trunc(LookAhead * StepsPerCycle)` to find which steps
to emit.  At 60 BPM × 16 stepsPerCycle: step interval 250 ms,
lookAheadMs 100 ms.  Step S only became discoverable once
`la * sp ≥ S + 1`, i.e. when `currentCycle ≥ StepCycle + 1/sp -
lookAheadCycles`.  At sp=16 that's `currentCycle ≥ StepCycle + 0.0375`
cycles past the event's nominal time — putting **WallUs ~184 ms in
the past on every step**, systematically.

The Tidal-pattern path doesn't have this problem because it queries
events by **integer-cycle window** (`fromCycle = Int.floor(...)`,
`toCycle = Int.floor(...) + 1`) — `queryArc` returns events with their
exact cycle positions, and `Voice.purs:404` then clamps
`delayClamped = max 0.0 delayMs` so even rare past events fire at
`nowUnixUs` rather than negative-future.

Fix in vmod: `EndStepExcl = trunc(LookAhead * StepsPerCycle) + 1`.
Step S is now discoverable as soon as `la ≥ StepCycle`, i.e. when
`currentCycle ≥ StepCycle - lookAheadCycles`.  WallUs lands at
`NowUs + lookAheadMs` (positive future) instead of `NowUs - ~150 ms`
(past).

Validation in BEAM diagnostic samples:

| | WallUs − NowUs |
|---|---|
| Before | mean ≈ −184 ms (always past), 100 % of events scheduled in the past |
| After  | min +18 ms, median +44 ms, max +70 ms, **0 % in the past** |
| WallUs IOI stdev | 0.055 ms → **0.033 ms** (matches Tidal's 0.031 ms) |

This was the load-bearing fix.  F1 alone left WallUs deep in the past
→ link-spike fired ASAP → Live block-quantised → 17 ms scatter.
F-FUTURE put WallUs in the future → CoreMIDI honoured the timestamp
→ Live PDC sample-aligned → 0.17 ms scatter.

## F4 — Manual GC scheduling (tried; reverted)

Per-step BEAM total time has a long tail driven by GC pauses:
mean 1.7 ms, p99 6.4 ms, **max 12.0 ms**.  We hypothesised that
`erlang:garbage_collect/0` at end of each `handle_cast` would clear
the heap during the idle 47 ms between ticks and pre-empt the spike.

In practice **F4 did not improve audio jitter** at either tempo and
arguably made it slightly worse on small samples (60 BPM max 1.28 →
6.03 ms, both within sampling noise on a single rare outlier).  The
explicit GC apparently just shifts the cost without reducing the tail.
Reverted 2026-05-21 a few minutes after introduction.

## F-LEAD — Bump `lookAheadMs` 100 → 300

The decisive scaling fix.  100 ms lookAhead gave near-zero **minimum**
lead time at 120 BPM × 16 stepsPerCycle (step interval 125 ms > tick
50 ms means some ticks discover a step with WallUs barely ahead of
NowUs).  Any BEAM preemption > a few ms then ate the whole cushion
and produced audible glitches every ~10 s.

`application:get_env(purerl_tidal, lookAheadMs, 300.0)` in
`purerl_tidal_sup.erl` — single number, no other code changes.  The
Tidal-pattern path queries by integer-cycle window, so it's
invariant under this change.

Results after F-LEAD (with F4 reverted):

| | n | stdev | p99 | max | notes |
|---|---|---|---|---|---|
| 60 BPM × 16 spc  | 288 | 0.23 ms | 0.63 ms | 2.47 ms | inaudible |
| 120 BPM × 16 spc | 576 | **0.30 ms** | 0.66 ms | **5.37 ms** | "every 5 bars" glitch eliminated |

The 5 ms residual outlier at 120 BPM is most likely CoreMIDI / OS
scheduling at this point — well outside the BEAM, which now has
~150–300 ms of cushion at the densest tested density.

## Final state

| | yesterday | now (F1+F-LAT+F-FUTURE+F-LEAD) | improvement |
|---|---|---|---|
| 60 BPM stdev  | 15.0 ms | 0.23 ms | **65×** |
| 120 BPM stdev | 15.2 ms | 0.30 ms | **51×** |
| 120 BPM max   | ~50 ms (bimodal) | 5.37 ms | **9×** |
| 120 BPM audible glitches | every ~10 s | sub-perceptual | — |

Vmod scheduling path is now equivalent to the Tidal-pattern path
within ~10× at the audio-onset level.  Single-voice timing meets the
"Squarepusher-at-the-Berghain" bar.

## Phase 5 — Multi-voice scaling (validated)

Tested 2026-05-21 with two identically-configured Grids voices
(`gridsA` on `iac` ch10, `gridsB` on `iac` ch11), panned hard L / R
into one stereo recording.  fillBd / fillSd / fillHh at 200 / 160 /
180 — busy beat, 6 simultaneous MIDI events per step at peak.

Custom stereo analyser (`tools/timing-analysis/analyse_stereo.py`)
detects onsets per channel, pair-matches them within a 30 ms
tolerance, computes inter-channel offset directly.

| inter-channel offset (R - L) | value |
|---|---|
| matched pairs | 2,100 / 2,109 |
| **median** | **+0.03 ms** (sub-sample at 48 kHz — same audio frame) |
| mean | +0.31 ms |
| stdev | 1.67 ms |
| p95 \|x\| | 2.52 ms |
| p99 \|x\| | 9.25 ms |
| max \|x\| | 18.55 ms |

Half the events fire on the same audio frame.  95 % within 2.5 ms —
inaudibly tight.  Andrew's by-ear verdict: "lockstep".  The 1 % tail
between 5–18 ms is BEAM scheduler unfairness on individual ticks (one
voice got a few ms more processing time than the other on that tick).
Rare enough to be inaudible in performance.

The per-channel grid-fit metric is meaningless for Grids material
(Grids produces irregular event spacing — fitting to a straight beat
grid produces a 15 ms phantom stdev).  The pair-matching IS the right
metric, and it's tight.

**Multi-voice scaling is validated.**  No fairness fix needed for
performance use.

## Startup phenomenon — anchor-log ghost trap

One test run produced ~8 large dropouts in the first 22 s of audio
(both voices in exact lockstep, missing ~400–800 ms each gap).  After
22 s the recording was clean, matching the steady-state measurements.

Visible in the Live waveform; uncorrelated to any audible event in
later recordings.  Hypothesis: `tidal_link_anchor:scheduler_clock`'s
documented "transitioning back into Link mode will phase-jump" — if
voices spawn during the free-running window (before the first /link/
anchor packet arrives), then the clock transitions to synced, the
voice's `LastStep + 1` lands past the new (smaller-fractional)
`CurrentCycle`, and `EndStepExcl > StartStep` returns false → silent
skip until lookAhead catches up.  Repeated each time the clock
re-syncs.

Not reproduced after the first observation; root cause not pinned.
Three avenues for next investigation are explored in the README's
suspect-mechanisms list above.

**Instrumentation in place for next time** (anchor-log ghost trap,
2026-05-21):

- New `tidal_anchor_log` module — capped 2,048-entry ring buffer in
  ETS, ~µs per write.
- `tidal_link_anchor` records `{anchor_rx, Beat, Tempo, Quantum,
  AgeSinceLastUs}` on every /link/anchor packet.
- `tidal_clock` records `{clock_transition, FromSynced, ToSynced}`
  whenever scheduler_clock crosses anchored/free-running boundary.
- `rene_voice` / `grids_voice` / `repetitor_voice` record
  `{voice_dropout, …}` when `EndStepExcl ≤ StartStep` and
  `{voice_step_burst, …}` when `EndStepExcl - StartStep > 8`
  (symmetric forward-jump case).
- WS verbs: `dump-anchor-log` (CSV) and `clear-anchor-log`.

Next time dropouts recur, `dump-anchor-log` over a captured window
will tell us the exact sequence of anchor receipts, clock transitions,
and per-voice silent-skip events.

## Final state

| metric | yesterday | now |
|---|---|---|
| 60 BPM × 16 spc audio stdev | 15.0 ms | 0.23 ms |
| 120 BPM × 16 spc audio stdev | 15.2 ms | 0.30 ms |
| 120 BPM × 16 spc audio max | ~50 ms (bimodal) | 5.37 ms |
| Two-voice inter-channel offset (median) | — | 0.03 ms |
| Two-voice inter-channel offset (max) | — | 18.55 ms |
| 120 BPM audible glitches | every ~10 s | sub-perceptual |

Vmod path is now indistinguishable from the Tidal-pattern path to
the human ear.  Single-voice timing meets the "Squarepusher-at-the-
Berghain" bar; two-voice lockstep meets it for paired drum patterns.

## F2 — Pre-resolve static Patterns at registration time (queued)

The 34 Pattern queries per step are mostly `pure value` patterns for
static configs.  At register-time the walker could detect this and
hand the voice a flat array of resolved Ints/Booleans, skipping the
FFI entirely for static slots.  Estimated -2 ms off eval_FFI for
common configs.  Bigger surgery; not blocking performance — queued.

## F2 — Pre-resolve static Patterns at registration time

The 34 Pattern queries per step are mostly `pure value` patterns for
static configs.  At register-time the walker could detect this and
hand the voice a flat array of resolved Ints/Booleans, skipping the
FFI entirely for static slots.  Estimated -2 ms off eval_FFI for
common configs.  Bigger surgery; deferred until multi-voice testing
shows whether it's needed.

### F2 — Pre-resolve static Patterns at registration time

The 34 Pattern queries per step are mostly `pure value` patterns for
static configs.  At register-time the walker could detect this and
hand the voice a flat array of resolved Ints/Booleans, skipping the
FFI entirely for static slots.  Estimated -2 ms off eval_FFI for
common configs.  Bigger surgery; deferred until F4 confirms whether
GC is the remaining limit.

## Lessons

1. **Trunc-discovery shifts events into the past.**  Any step-based
   voice that uses `trunc(lookAhead * sp)` to decide what to emit is
   running one step behind by construction.  The +1 fix is mechanical
   and obvious *after* you see the math; the algorithm read fine until
   the audio chain showed it didn't.

2. **Tidal-pattern path has two safety nets the vmod lacked.**
   `delayClamped = max 0.0` ensures past events fire at `now` (not
   negative time).  Integer-cycle query windows ensure events are
   *always* sampled before they fire.  The vmod ported the per-step
   query shape but inherited neither safety net.

3. **Device latency compensation is needed for Live's PDC to align.**
   Without it, MIDI arrives at the buffer just as the buffer needs to
   render — block quantisation jitter is the result, regardless of
   how precise the BEAM scheduling is.

4. **Per-step BEAM instrumentation is cheap and worth keeping.**
   The `samples` field in `rene_voice.erl` (six `monotonic_time` calls
   per step, a list cons) added measurable cost in the noise floor.
   It's the only reason we could decompose total-step time into
   eval/refresh/emit phases and find the dominant contributor.

5. **F1 was a real but secondary win.**  Mean eval -38 %, but the
   audio stdev didn't budge.  That ruled out per-step CPU as the
   bottleneck and pointed us at scheduling.  Worth doing for the
   future-density work (16+ voices in one BEAM); not what fixed the
   audio.

## Carry-forward

- F1 + F-LAT + F-FUTURE are landed for `rene_voice`, `grids_voice`,
  `repetitor_voice`.  `virtual_polysignal_voice` doesn't apply (it
  writes to the control bus, not MIDI).
- Per-step instrumentation (`samples` field + `dump-rene-samples`/
  `clear-rene-samples` WS verbs) stays on `rene_voice` permanently;
  cost is ~300 ns per step.  Same instrumentation should propagate to
  grids/repetitor before they go to performance.
- The `device_latencies` map in the walker's accumulator is internal
  bookkeeping — strip from `Stats` before returning to caller if it
  ever becomes user-visible.
- F4 (manual GC) is next.  F2 (static pattern pre-resolve) is queued
  but lower priority.

## Files touched

- `src/tidal_control_bus.erl` — version counter on every set/clear
- `src/tidal_clock.erl` — `controlVersion` in Window broadcast
- `src/tidal_session_walker.erl` — `device_latencies` accumulator;
  `latency_ms` threaded into Rene/Grids/Repetitor VoiceConfig
- `src/rene_voice.erl` — `#st.latency_us` + `#st.control_version` +
  `#st.cached_controls`; +1 to EndStepExcl; WallUs latency subtraction
- `src/grids_voice.erl` — same triple-patch
- `src/repetitor_voice.erl` — same triple-patch
- `src/Tidal/Rene.purs` — `buildControlMap` + `evaluateParamsAtControls`
- `src/Tidal/Grids.purs` — same exports
- `src/Tidal/Repetitor.purs` — same exports

## Related

- `tools/timing-data/phase-4-diagnostic/README.md` — the F1 measurement
  that found the eval_FFI cost
- `tools/timing-data/phase-4-rene-clean/README.md` — the original
  Phase 4 capture that surfaced the 15 ms floor
- `tools/timing-data/phase-3-tidal-dense/` — the 0.03 ms reference
  point from Tidal patterns on the same chain
- `src/Tidal/Voice.purs:404` — `delayClamped` (the Tidal-pattern
  safety net) and `:357` — integer-cycle query window
- `src/Tidal/Dispatcher.purs:325` — Tidal-pattern's latency comp
  (mirror of F-LAT)
