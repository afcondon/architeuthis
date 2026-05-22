# Phase 4 diagnostic — per-step instrumentation of rene_voice

**Status:** ✅ root cause identified.  **Date:** 2026-05-21.

## What we did

Instrumented `rene_voice.erl`'s `emit_step/7` with four
`erlang:monotonic_time(microsecond)` markers, capturing per-step
samples to a bounded list in the gen_server state.  Added WS verbs
`dump-rene-samples <voice>` and `clear-rene-samples <voice>` to
extract / reset.

Captured 449 steps over ~112 s with phase4Rene running at 60 BPM
on IAC ch7, BD-style sample triggering in Live for audio
correlation.

Per-step tuple: `{NowUs, TRecv, TEvalDone, TRefreshDone, TEmitDone,
WallUs}` — all microseconds.

## Phase distribution (n=449)

| phase             | mean    | stdev   | min     | max      | p99      |
|-------------------|---------|---------|---------|----------|----------|
| eval_FFI          | 2.18 ms | 1.66 ms | 0.31 ms | 14.94 ms | 7.24 ms  |
| refresh + engine  | 0.02 ms | 0.16 ms | 0.001 ms| 3.42 ms  | 0.015 ms |
| emit_send         | 0.81 ms | 0.93 ms | 0.10 ms | 8.32 ms  | 4.87 ms  |
| **total step**    | **3.00 ms** | **2.29 ms** | 0.42 ms | **23.27 ms** | **10.43 ms** |
| cast arrival var  | —       | 0.44 ms | —       | 6.84 ms  | —        |

Audio recording of the same run: grid stdev **15.18 ms**, max
30.47 ms.  Consistent: the per-step tail variance (worst 23 ms) is
the audio's worst-case excursion.

## Where the 15 ms comes from

Three orthogonal contributors, in order of impact:

1. **`evaluateParamsAt` FFI call dominates** — 2.18 ms mean, 1.66 ms
   stdev, p99 7.24 ms.  This is 73 % of mean total step time.

   The implementation in `src/Tidal/Rene.purs`:

   ```purescript
   evaluateParamsAt cfg controlPairs pos =
     let controls = pairsToControlMap controlPairs  -- rebuilds Map every step!
         sampleN p = sampleIntAt controls 60 p pos
         sampleS p = sampleBoolAt controls false p pos
     in { stepYNow: sampleBoolAt controls false cfg.stepYNow pos
        , notes:    map sampleN cfg.notes        -- 16 queries
        , skip:     map sampleS cfg.skip         -- 16 queries
        , advance:  sampleBoolAt controls true cfg.advance pos
        }
   ```

   Every step: rebuild ControlMap from the entire live-control-bus
   snapshot **PLUS** run 34 `Pattern` query evaluations.  For our
   test all patterns are `pure value` so the queries should be
   cheap — yet the FFI crossing + Map.insert per controlPair + arc
   computation still costs ~2 ms per call.

2. **`scheduleNoteAt` (gen_udp:send) is the secondary cost** — 0.81
   ms mean, 0.93 ms stdev, p99 4.87 ms.  Some of this is the FFI
   crossing back into the bridge module, some is the actual UDP
   write to link-spike on port 57122.

3. **GC pauses cause the worst-case tail** — the 7 steps that
   exceed 10 ms total tend to have BOTH eval AND emit phases
   spike simultaneously.  Worst step: 14.94 ms eval + 8.32 ms
   emit = 23.27 ms total.  Classic minor-GC signature: a GC pause
   pre-empts the gen_server mid-emit, so all in-progress phases
   pick up the same delay.

## Where the 15 ms *isn't*

- **Not gen_server cast queue depth** — cast arrival variability is
  0.44 ms stdev, max 6.84 ms.  Mailbox isn't backed up.
- **Not BEAM scheduler granularity** — each tick contributes
  exactly 1 event (mean events/tick = 1.00, max = 1).  No batching.
- **Not refresh_from_snapshot or rene_engine** — 0.02 ms mean
  cost.  Negligible.
- **Not CPU starvation** — total emit_step CPU is 1.2 % of one
  core for this single voice.  Plenty of headroom.

## Fix surface (in order of cost/benefit)

### F1 — Cache `ControlMap` in voice state

`pairsToControlMap controlPairs` is recomputed every step from the
same controlPairs (the tidal_clock broadcasts one snapshot per
tick).  Cache the result.  Even better: make the bus emit a
versioned snapshot, and the voice only rebuilds when the version
changes.

Estimated impact: -1 ms off mean eval_FFI.  Cheap, localized to
PureScript.

### F2 — Pre-resolve static `Pattern` values at registration time

For voices whose config has only `pure value` patterns (the common
case), the walker can resolve the values once at register time and
hand the voice flat Erlang arrays of `Int`/`Boolean`.  The voice
skips the FFI altogether and reads directly from its state.

Dynamic patterns (`liveIntOr`, mini-notation rhythms, etc.) still
need per-step evaluation — but only those slots that are dynamic.

Estimated impact: -2 ms off mean eval_FFI for static configs, no
change for fully-dynamic configs.  Medium architectural change to
the walker.

### F3 — Schedule `scheduleNoteAt` via `erlang:send_after`

Currently the gen_udp:send happens immediately and link-spike
schedules via CoreMIDI timestamp.  Alternative: have the voice
gen_server hold the event in its own scheduler and send via
`erlang:send_after`, making each emit lightweight (just enqueue, no
syscall in the hot path).

Estimated impact: -0.8 ms off mean emit_send, removes the UDP
syscall from the hot path.

### F4 — Suppress GC during emit_step

`erlang:garbage_collect/0` before each emit_step ensures the GC
runs at a known time, not mid-emit.  Trades a 100 µs cost per step
for elimination of the 10+ ms GC tail.

Estimated impact: -23 ms worst-case (eliminates the GC tail spike).
Cheap to try.  May be undesirable architecturally — it's a tuning
knob on a foundational substrate ([[feedback_dont_patch_foundational_substrate]]).

### F5 — Move per-voice work off the gen_server

Spawn a worker per emit so the voice gen_server's mailbox only
queues lightweight messages.  Worker handles its own GC
independently.

Estimated impact: removes GC tail from the voice; adds spawn cost
(~10 µs per spawn).  Bigger architectural shift.

## Recommended attack order

1. **F1 (ControlMap cache)** — quick, low-risk, easy to validate.
   Should drop mean eval to ~1 ms, audio stdev to ~8 ms.
2. **F2 (pre-resolve static patterns)** — for our common
   single-vmod-static-pattern test case, eliminates the FFI cost
   entirely for static slots.  Should drop audio stdev to ~3 ms
   for static configs.
3. **F4 (manual GC scheduling)** — try it, measure, decide.  If
   it cleanly removes tail spikes without other side effects, ship
   it.  If it has bad interactions with other vmod voices, drop.
4. **F3 (send_after-based emit)** — bigger surgery, do later if
   1+2+4 don't get us to the target.

Target: audio grid stdev < 1 ms, p99 < 2 ms, max < 5 ms.  That
matches what Tidal patterns already achieve through the same chain.

## Carry-forward

- Instrumented `rene_voice.erl` lives on this branch; should
  probably stay (cheap, no measurable cost) as a permanent
  diagnostic facility.  Same instrumentation should be added to
  `grids_voice.erl` / `repetitor_voice.erl` / `virtual_polysignal_voice.erl`
  before they go to production.
- WS verbs `dump-rene-samples` and `clear-rene-samples` need
  generalisation to all vmod voices (or a single `dump-voice-samples`).
- The walker should grow a `static_pattern?` predicate that the
  voice consults at register time to decide F2's pre-resolve path.

## Related

- [[project_timing_jitter_investigation_queued]]
- [[reference_purerl_array_is_erlang_array_module]] — relevant for
  the FFI ControlPairs marshalling
- [[feedback_dont_patch_foundational_substrate]] — guides F4's
  appropriateness
