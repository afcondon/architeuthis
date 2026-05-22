# Mutable Instruments Grids as a BEAM virtual module

**Status:** Draft plan, 2026-05-18.

**Source of truth:** Emilie Gillet's MIT-licensed firmware at
`/Users/afc/work/afc-work/music/stages-firmware/grids/` —
`pattern_generator.{h,cc}` (~270 LOC) and `resources/lookup_tables.py`
(25 nodes × 96 bytes + a 4 KB Euclidean LUT).

**Companion reading:** `sequencer-vocabulary-research-2026-05-09.md` —
the general "hardware module as `Sequencer state nav out`" framework
this plan instantiates. Grids was not in that doc's five; it should
have been, and is the cleanest of the lot.

## Goal

A virtual Grids running on the BEAM as a peer to the TidalCycles voice
tree in purerl-tidal, live-coded from Calypso. Triggers route through
the same fan-out as the rest of purerl-tidal: MIDI to Ableton, OSC to
cv-router (→ ES-9 gates), OSC to SuperDirt.

## Why Grids first

Of all the hardware modules we've considered porting, Grids has the
best ratio of *expressive yield* to *implementation cost*:

- **State is ~16 bytes** total. Three densities, X, Y, randomness,
  mode, step counter, three perturbation bytes.
- **Tables are 2.4 KB** (Drums) or 6.4 KB with Euclidean. Trivial to
  bake into Erlang as static binaries.
- **Algorithm is ~150 lines of C++**, mostly arithmetic on bytes. No
  floating point. No interrupt-driven timing dependencies the BEAM
  can't satisfy at 24 ppqn.
- **Live-coding surface is unusually clean** because the parameters
  are continuous, few, and have well-understood musical meaning
  (X/Y = "style space", density × 3 = "how many hits", randomness =
  "how often things go off-grid").
- **The doc's central lift applies trivially.** Hardware Grids has one
  navigator: a clock gate. Virtual Grids gets `Pattern (X, Y)` — a
  navigator over the 2D pattern landscape — which the hardware can
  never offer.

## Algorithm summary

Per 16th-note step, for each of three instruments (BD, SD, HH):

1. Look up `level` at `(step, instrument)` in the *four* nodes
   surrounding the (X, Y) cursor in the 5×5 grid.
2. Bilinearly interpolate by the fractional parts of X and Y
   (`U8Mix(U8Mix(a,b,fx), U8Mix(c,d,fx), fy)`).
3. Add a random `perturbation` (scaled by the randomness knob; sampled
   once per pattern start, not per step).
4. Threshold: `level > (255 - density)` → trigger.
5. Accent: `level > 192` → set accent bit.

Independent of the drum logic, an "extra random gate" derived from the
RNG is emitted on bit 7 of the output state — this is the panel's
random gate output and is worth preserving as a 4th output.

Euclidean mode is independent and dispenses with X/Y entirely; it's a
LUT-indexed bitmask. Cheap to include but separable.

## Architecture

```
                  Calypso (grids cell or pane)
                              │
                              │ WS verbs: set_xy, set_density, set_mode…
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ purerl-tidal                                              │
   │                                                            │
   │   Tidal.Grids (PureScript surface)                         │
   │     • newtypes X, Y, Density, Randomness                   │
   │     • ADT GridsMode = Drums | Euclidean                    │
   │     • setXY, setDensity, … (live-control verbs)            │
   │     • gridsPattern :: GridsConfig -> Pattern Trigger       │
   │                                                            │
   │              │ FFI                                          │
   │              ▼                                              │
   │   Grids.Engine (Erlang, pure)                               │
   │     • read_drum_map/4, evaluate/1                           │
   │     • property-testable in isolation                        │
   │                                                            │
   │   Grids.Tables (Erlang, static)                             │
   │     • 25 nodes × 96 bytes as binaries                       │
   │     • 5×5 node-index table                                  │
   │     • Euclidean LUT (optional)                              │
   │                                                            │
   │   Grids.Voice (Erlang gen_server)                           │
   │     • one per logical Grids instance                        │
   │     • subscribes to master 24 ppqn tick                     │
   │     • emits triggers into the existing scheduler fan-out    │
   └──────────────────────────────────────────────────────────┘
                              │
                ┌─────────────┼──────────────┐
                ▼             ▼              ▼
           sendmidi      OSC → cv-router    OSC → SuperDirt
           (Ableton)     (ES-9 gates)       (samples)
```

The boundary between PureScript and Erlang is the same boundary
already used by `Tidal.MIDIScheduler` / `Tidal.OSC` — a thin FFI layer
over a stateful Erlang process. No new architectural surface.

## Phases

### Phase 1 — Tables and engine, headless

**Deliverable:** Erlang module that, given a state and a step number,
returns the triggers a hardware Grids would emit. Verified against a
small set of hand-traced reference outputs from the firmware.

- `src/grids_tables.erl` — bake the 25 nodes and 5×5 index table from
  `lookup_tables.py`. Static binaries, compile-time constants. ~100
  LOC of mostly data.
- `src/grids_engine.erl` — pure functions: `read_drum_map/4`,
  `evaluate/1`, the U8Mix helper. ~80 LOC.
- `test/grids_engine_SUITE.erl` — property tests (interpolation
  bounds, density monotonicity, accent ≤ trigger) plus 3–5 traced
  reference vectors from a known (X, Y, density) input.

**Acceptance:** running `evaluate` on `(X=128, Y=128, density=128)`
produces a stable, plausible 32-step rhythm matching the firmware's
behaviour for the central node.

**Estimate:** 1 day.

### Phase 2 — Voice gen_server and clock wiring

**Deliverable:** A `grids_voice` process that ticks at 24 ppqn from
the existing master clock and emits triggers into the scheduler's
existing fan-out.

- `src/grids_voice.erl` — gen_server holding `GridsState` plus a
  subscription to the master tick. Handles `set_xy`, `set_density`,
  `set_randomness`, `set_mode`, `reset`. ~150 LOC.
- Wire into the per-voice supervisor tree (same pattern as TidalCycles
  voices).
- Outputs: emit the same trigger shape the MIDIScheduler already
  consumes — `{Instrument, Accent, Timestamp}`. No new wire format.

**Acceptance:** with cv-router up and ES-9 patched to the modular,
spawn one Grids voice, set X=128 Y=128 density_bd=200, hear a kick
pattern on jack 1.

**Estimate:** 1 day.

### Phase 3 — PureScript surface

**Deliverable:** `Tidal.Grids` module that exposes the verb set and a
`Pattern`-compatible lift.

- `src/Tidal/Grids.purs` — newtypes, ADTs, FFI to the gen_server.
- `gridsPattern :: GridsConfig -> Pattern Trigger` — Grids as a
  navigator-driven Pattern, composable with `slow`, `jux`, `every`.
- The "navigator as Pattern" lift: `gridsNav :: Pattern Nav ->
  GridsVoice -> Effect Unit` where `Nav = SetXY X Y | StepBy Int |
  Pulse | Reset`. This is the doc's central insight in code form.

**Acceptance:** a Calypso cell containing
```purescript
grids
  { x = sine # range 0 255
  , y = saw  # range 0 255 # slow 4
  , density = { bd: 200, sd: 140, hh: 180 }
  , randomness = 32
  }
```
runs and produces a slowly-drifting drum pattern.

**Estimate:** 1–2 days.

### Phase 4 — Calypso surface

**Deliverable:** Either a new `grids` cell kind, or — more ambitiously
— a dedicated pane with a 2D XY pad over the 5×5 pattern grid.

Minimum: the cell kind. The pane is a strict win on Hylograph
grounds (the bilinear interpolation map *is* a visualization), but it
can come later.

- Cell kind: parse `grids { … }` body, hot-reload via the existing
  per-cell PureScript compile path.
- Pane (optional, later): a Halogen view showing the 5×5 grid with
  the (X, Y) cursor, a heatmap of the interpolated current pattern,
  and sliders for density and randomness.

**Estimate:** 1 day for the cell; 2–3 days for the pane.

## Total estimate

**~4 working days for Phases 1–3** (functional system, headless+CLI
control). Phase 4 cell adds half a day; pane adds 2–3 days on top.

## Open questions

1. **Drums-only or Drums + Euclidean?** Drums is the iconic mode and
   does the heavy lifting; Euclidean costs +4 KB tables and ~20 LOC
   but Tidal already expresses Euclidean rhythms in mini-notation.
   *Default: Drums only, with a stub for Euclidean if it's wanted
   later.*
2. **Determinism vs aliveness.** Original firmware uses a free-running
   RNG. For live-coded reproducibility, seed the RNG per voice. At
   that point the seed buffer is one step away from Marbles DEJA VU,
   which the sequencer-vocabulary-research doc already proposed
   porting — they could share infrastructure.
3. **Bake the Euclidean LUT or compute on demand?** The Python in
   `lookup_tables.py:402-419` computes Euclidean(`k, n`) on every
   build. We could do the same in Erlang at startup and skip the 4 KB
   binary. Decision deferred until Phase 1 is in.
4. **Multi-instance.** Free architecturally — each Grids is ~16 bytes
   of state plus a gen_server process. Worth declaring `grids_voice`
   instances by name from the start so multiple Grids can run in
   parallel with different X/Y.
5. **Tick source.** Master tidal tick at 24 ppqn is the obvious
   choice. Alternative: subscribe directly to link-spike. The
   indirection through the master tick is correct; Link enters
   through there.

## Out of scope

- The hardware Grids panel UI (8-bit LEDs, three encoders). Not
  reproducing the physical-instrument UX; we get a strictly larger
  surface via Calypso authoring.
- "Snake mode," "rotation," and the tap-tempo logic. These are
  hardware-ergonomics features that don't translate.
- The SD-card pattern save/load. Calypso cells *are* the save/load.

## References in this repo

- Firmware: `/Users/afc/work/afc-work/music/stages-firmware/grids/`
  - `pattern_generator.cc:69-95` — drum map indirection and bilinear
    interpolation
  - `pattern_generator.cc:98-136` — the EvaluateDrums core
  - `pattern_generator.cc:139-172` — EvaluateEuclidean (if we keep it)
  - `resources/lookup_tables.py:32-383` — the 25 nodes
  - `resources/lookup_tables.py:411-419` — the Euclidean LUT
- Companion framework: `docs/sequencer-vocabulary-research-2026-05-09.md`
  §"What 'porting' means here (it's not a copy)" and §"Method"
- purerl-tidal architectural reference: `CLAUDE.md` in repo root.
