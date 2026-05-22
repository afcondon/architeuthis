# Phase 4 — René vmod, clean BEAM, ch7

**Status:** ✅ measured.  **Date:** 2026-05-21.

## Hypothesis

If the BEAM emit path is sub-millisecond for Tidal patterns (Phase 3)
but ~25 ms for René yesterday, the difference must be in the vmod
voice gen_server's per-step work.  Head-to-head: René at 16
stepsPerCycle, same emit rate as Phase 3 (4 notes/s at 60 BPM, 8
notes/s at 120 BPM), same MIDI device, same recording substrate.

## Method

`phase4Rene = reneWith { ..., stepsPerCycle: 16, notes: [36;16],
skip: replicate16 false, gate: replicate16 true, navMode:
NavForward, config: { advance: pure true, ... } }` on IAC ch7.

Fresh deepstar restart between takes (kills any orphan voices).
Calypso closed entirely (no WS subscription consuming BEAM cycles).
Live MIDI track filtering on ch7 only — orphans on other channels
wouldn't reach the recording even if they existed.

Direct WS bypass for arming — `wscat ws://localhost:3012/ws`,
sending `reload-baseline` to trigger the walker.  Live drives BPM
via Link.

## Results

### 60 BPM ch7 (n=304 notes, 76 s recording)

| metric            | value     |
|-------------------|-----------|
| IOI median        | 255 ms (~5 ms above nominal — Link drift) |
| grid stdev        | **15.0 ms** |
| p50 / p95 / p99   | 0.66 / 22.4 / 24.9 ms |
| max excursion     | 29.2 ms @ idx 2 |
| drift             | -0.003 ms/event |
| IOI percentiles   | 5%=204 / 25%=254 / 50%=255 / 75%=256 / 95%=259 |

Shape: tight Gaussian around the mean with occasional ~50 ms
outliers (events that landed late then "caught up" on the next
step).

### 120 BPM ch7 (n=592 notes, 74 s recording)

| metric            | value     |
|-------------------|-----------|
| IOI median        | 109 ms    |
| grid stdev        | **15.2 ms** |
| p50 / p95 / p99   | 0.31 / 22.4 / 28.5 ms |
| max excursion     | -51 ms @ idx 391 |
| drift             | 0.004 ms/event |
| IOI percentiles   | 5%=99 / 10%=101 / 25%=103 / 50%=109 / 75%=153 / 90%=156 / 95%=158 |

Shape: **bimodal** — two narrow modes at ~100 ms and ~155 ms, almost
nothing in between.  Pairs sum to ~255 ms (the correct 8-events-
per-second average).  Underneath the bimodal artifact, a 15 ms
jitter floor identical to 60 BPM.

## Two distinct findings

### Finding 1 — bimodal artifact at 120 BPM

At 120 BPM with 16 stepsPerCycle the step interval is **125 ms**
but `lookAheadMs` is **100 ms**.  Step interval > lookAhead means
events get computed with `WallUs` already in the **past** by the
time the right tick "discovers" them.  link-spike / CoreMIDI emit
past-timestamped events immediately.

Tick interval is 50 ms; step interval 125 ms doesn't divide cleanly.
Events alternate between being discovered 25 ms late vs 50 ms late
depending on tick boundary phase → alternating IOI 100 ms / 155 ms.

**Not real jitter** — pure scheduling artifact, deterministic given
the tick / lookAhead / step relationship.  Disappears at 60 BPM
because step interval (250 ms) > lookAhead (100 ms) but the math
works out differently when step > lookAhead by more than the tick.

### Finding 2 — ~15 ms real jitter floor (both BPMs)

Underneath the bimodal artifact at 120 BPM, and exposed cleanly at
60 BPM, there is a **15 ms stdev floor** that is present at both
tempos.  This is the actual vmod gen_server jitter we need to fix.

Compared to Tidal at the same emit rates:

| emit rate | Tidal dense (Phase 3) | René (Phase 4) | ratio |
|-----------|------------------------|----------------|-------|
| 4 notes/s | 0.13 ms stdev          | 15.0 ms stdev  | **115×** |
| 8 notes/s | 0.11 ms stdev          | 15.2 ms stdev  | **138×** |

**Two orders of magnitude worse than Tidal.**  Same audio chain,
same recording, same emit rate.  The only difference is the BEAM
voice gen_server's per-step work.

## Candidate causes (René gen_server per-step work)

From the rene_voice.erl emit_step path, in order of suspected cost:

1. **`evaluateParamsAt` FFI call** — crosses into PureScript, the
   evaluator runs 32 Pattern → value queries (16 notes + 16 skips)
   per step.  Likely the dominant cost.
2. **`refresh_from_snapshot`** — two `set_field` calls per step,
   each updating the engine's working state.
3. **`lists:nth/2`** — O(n) walk through skip array each step.
4. **gen_server cast queue depth** — clock broadcasts at 50 ms
   intervals; if emit_step takes >50 ms even occasionally, the
   queue grows and per-event latency spikes.
5. **BEAM scheduler pre-emption** — GC pauses, scheduler context
   switches, OS thread scheduling.

## Plan to attack the 15 ms floor

Out of scope for this measurement session — flagged for the
next investigation step:

1. Instrument `emit_step` with per-component timing — add
   `erlang:monotonic_time()` markers around each phase, log
   distribution.
2. If `evaluateParamsAt` dominates: profile the PureScript
   evaluator; possibly cache the 16-note array as a compiled
   `compute_until` closure rather than 16 individual Pattern eval
   calls.
3. If `refresh_from_snapshot` dominates: switch to a single-pass
   record update instead of two set_field calls.
4. If gen_server cast queue depth shows up: consider a per-voice
   timer-driven scheduler rather than tick-driven broadcast, OR
   process the entire compute_until window in a worker process
   so the voice's mailbox doesn't accumulate.

## Plan to fix the bimodal artifact

Separately — lookAhead needs to be > step interval to keep WallUs
in the future:

- At 120 BPM with 16 stepsPerCycle → step interval 125 ms.
  lookAheadMs should be ≥ 200 ms (1.5× max step interval) to keep
  the gen_server scheduling events in the future.
- Or scale lookAheadMs dynamically with current BPM × stepsPerCycle.
- Or — better — actually use the `WallUs` value to schedule the
  send (`erlang:send_after`) rather than relying on link-spike's
  CoreMIDI timestamping.  This makes the system insensitive to
  lookAhead vs step relationships.

The artifact is independent of finding 2 above; both need
addressing.

## Carry-forward

- The 25 ms "René floor" from yesterday's recordings was the 15 ms
  real jitter floor PLUS orphan-voice phasing.  About half real,
  half phasing.
- Phase 3 confirms the BEAM emit path is sub-ms for Tidal —
  vmod gen_server work is the new floor.
- **Andrew's intuition that René might specifically be worse than
  other vmods needs Phase 4b** (Grids and Repetitor at comparable
  density) to test.  If they're similarly bad, it's gen_server
  infrastructure.  If only René, it's the 32-pattern-evals path.

## Related

- [[project_timing_jitter_investigation_queued]]
- [[reference_walker_does_not_stop_orphan_voices]]
- [[feedback_dont_patch_foundational_substrate]]
