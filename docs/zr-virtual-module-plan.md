# Zularic Repetitor as a BEAM virtual module

**Status:** Draft plan, 2026-05-18.

**Source manual:** `/Volumes/Crucial4TB/Books/Manuals/Music/Noise Engineering/Noise Engineering ZR_manual.pdf`

**Source patterns (per the manual's Design Notes):** William Sethares,
*Rhythm and Transforms* (MIT Press, 2007). The 30 named patterns are
Stephen Hick's selection from a much larger catalog.

**Companion docs:**
- `grids-virtual-module-plan.md` — first virtual module on BEAM; this
  one mirrors its phase structure.
- `sequencer-vocabulary-research-2026-05-09.md` — the `Sequencer state
  nav out` framework. ZR is the sixth module that should have been
  surveyed there.

## Goal

A virtual Zularic Repetitor on the BEAM, peer to the Tidal voice tree
and to the now-implemented virtual Grids. Live-coded from Calypso.
Triggers route through the existing fan-out: MIDI to Ableton, OSC to
cv-router (→ ES-9 gates), OSC to SuperDirt.

Plus: a **rhythm-library substrate** so ZR's 30 patterns are just one
*bank* among many. The same engine should accept additional libraries
sourced from Sethares, Toussaint, drum-machine factory patterns, and
hand-authored corpora.

## Why ZR is interesting (and how it differs from Grids)

ZR is the **dual** of Grids on the library↔navigation axis:

|              | **Library**                    | **Navigation**                  |
|--------------|--------------------------------|----------------------------------|
| **Grids**    | Tiny: 25 latent nodes (2.4 KB) | Rich: continuous 2D + bilinear interp + perturbation |
| **ZR**       | Rich: 30 named cultural rhythms | Sparse: select-one + 3 phase offsets |

Grids' value is the smooth pattern *manifold*. ZR's value is the
*curation*. They sit at opposite ends of the same design space and are
both worth having.

The corollary: ZR's engine is **trivially small**. The value of doing
this isn't the engine — it's that, having paid the cost of a tiny
engine, we get a long-lived substrate that any rhythm corpus can plug
into.

## Algorithm

State:

```
{ bank, pattern_idx, offset_c1, offset_c2, offset_c3, step, mode }
mode = Normal | Divider | Random
```

In `Normal` mode, given a pattern `P` with mother bits `M` of length
`len`, the read at the current step is:

```
mother  = M[step           mod len]
child_1 = M[(step - off_c1) mod len]
child_2 = M[(step - off_c2) mod len]
child_3 = M[(step - off_c3) mod len]
```

A Child is *the same Mother pattern, phase-shifted*. Not a separate
pattern. This matches what you see in the manual: each Child row is a
delayed copy of the Mother row, not an independent track.

In `Divider` mode (Old World, last position): Mother = BEAT/4;
Children = BEAT/k where k ∈ 1..32 set per Child by knob+CV.

In `Random` mode (New World, last position): Mother fires at 25%
probability per beat; Children at probability set per Child by
knob+CV.

**Pattern length is per-pattern data**, not a global constant. From
the manual: PASHTO is ~8 steps, PRIME 232 short, MOTORIK ~32, CHACHAR
~48+. The MEASURE input resets to the start of *that* pattern's
measure, confirming `len` lives with each pattern.

State size is ~12 bytes. Even smaller than Grids.

## The empirical question: Child offset semantics

The manual is *quiet* on quantization, range, and whether offset
scales with pattern length. This is the one piece we have to measure
before committing to an engine.

Three sub-questions, each measurable:

### Q1. Is offset quantized or continuous?

The MSP430 origin (per Design Notes) and the "knob attenuates CV"
language both suggest **integer-beat quantization**, but it's not
stated.

### Q2. What's the range? In what units?

Possibilities:
- 0..15 (one pattern of 16)
- 0..31 (one pattern of 32)
- 0..63 (two patterns; the patching-suggestions section says "amount
  of time offset that occurs every 64 beats" which is suggestive)
- 0..(len − 1) — **scaled per pattern**, so the knob always sweeps
  exactly one pattern length. Most elegant if true.

### Q3. Linearity?

Almost certainly linear in beats (it's a counter offset on an MCU
that has no reason to do anything fancier), but worth confirming.

### Measurement procedure (recommended)

The cleanest setup uses the rig you already have:

1. **Patch:** master clock → ZR `BEAT`. ZR Mother and Child 1 outputs
   → two inputs on Trig31 → MIDI in via the iConnectivity 4c+.
2. **Pattern choice:** pick something with a **sparse Mother** so the
   shift is visually obvious in the captured MIDI. Candidates:
   PASHTO (short, sparse), PRIME 2 (short), or KING 1. PRIME 2 is
   probably ideal — short measure, single sparse pattern, no
   ambiguity about which hit shifted where.
3. **Tempo:** slow (e.g. 60 bpm) so you have time to turn the knob
   between measures.
4. **Sweep:** record continuously while turning Child 1's knob slowly
   from full-CCW to full-CW. Take ~30 seconds for the full sweep.
   This gives the ear and the eye plenty of detectable plateaus if
   the offset is quantized.
5. **Analyze the capture:** in your DAW, line up Mother and Child 1
   on the grid. Each plateau in Child 1's timing relative to Mother
   is one quantization step. Count plateaus → number of discrete
   offsets. Measure the time delta between Mother and Child 1 at
   each plateau → unit (beats? 16ths?).
6. **Repeat on a long pattern** (CHACHAR or MOTORIK 1). If the
   number of plateaus differs between PRIME 2 and CHACHAR, the
   offset is **pattern-length-scaled** (Q2 hypothesis 4). If it's
   the same count, it's a **fixed integer range**.
7. **Confirm Children behave identically.** Two-minute sanity check:
   sweep Child 2 and Child 3, verify same plateau count.

That's enough to commit to an engine model.

### Alternative: CV-automated sweep

Drive Child 1's CV input directly from cv-router with a slow ramp
(0V → 7V over 60s) while the knob is at max (so the knob's attenuator
is unity). Capture Mother + Child 1 MIDI throughout. Pros: perfectly
monotonic, repeatable, no human-hand bias. Cons: a bit more setup.
Either approach yields the same answer; pick whichever feels less
fiddly on the day.

### If offset turns out to be continuous

Unlikely on an MSP430, but if Child 1 slides smoothly past Mother
rather than clicking into positions: it's a sub-beat phase shift, in
which case we need a finer time-base than the BEAT input alone gives
us, and the model becomes "delay line in 24-ppqn ticks" rather than
"step offset." Either is implementable; we just need to know.

## Architecture

```
              Calypso (repetitor cell or pane)
                          │
                          │ WS verbs: set_bank, set_pattern,
                          ▼                set_offset, set_mode…
   ┌──────────────────────────────────────────────────────┐
   │ purerl-tidal                                          │
   │                                                        │
   │   Tidal.Repetitor (PureScript surface)                 │
   │     • newtypes Bank, PatternIdx, Offset, Probability   │
   │     • ADT Mode = Normal | Divider | Random             │
   │     • set verbs + Pattern lift                         │
   │                                                        │
   │              │ FFI                                      │
   │              ▼                                          │
   │   Repetitor.Engine (Erlang, pure)                       │
   │     • lookup(Bank, Idx, Step) -> bit                    │
   │     • evaluate/1 covers all 3 modes                     │
   │                                                        │
   │   Repetitor.Libraries (Erlang, static)                  │
   │     • zr_old_world (15 patterns)                        │
   │     • zr_new_world (15 patterns)                        │
   │     • toussaint_clave, toussaint_west_african, …        │
   │     • sethares_indian, …                                │
   │     • each: list of { name, length, mother_bits }       │
   │                                                        │
   │   Repetitor.Voice (Erlang gen_server)                   │
   │     • one per logical Repetitor instance                │
   │     • subscribes to master clock                        │
   │     • emits Mother + Children into fan-out              │
   └──────────────────────────────────────────────────────┘
```

**Shared substrate observation.** Grids and Repetitor will both want:
per-voice gen_server, master-tick subscription, trigger-emit fan-out,
Calypso cell-kind hook, WS-verb registration. With two concrete
instances we're at the threshold where extracting a `virtual_module`
behaviour (in the OTP sense) starts to pay. Not in scope for this
plan, but worth noticing now so we don't paint ourselves into a
corner; revisit after Phase 2 lands here.

## Library plurality (the long game)

Engine cost is trivial; the differentiated content is the libraries.
Each library is just data: a list of `{ name, length, mother_bits }`
records. JSON in `priv/libraries/` plus a tiny PureScript codec lets
new banks land without recompiling Erlang.

Candidates to pursue once the substrate is up:

- **ZR Old World / New World** — first two banks; transcribed from
  the manual. Source for this plan.
- **Sethares — *Rhythm and Transforms* (MIT Press, 2007).** Appendix
  rhythm catalogs. Check for a companion website with
  machine-readable data; failing that, the TUBs notation transcribes
  cleanly. *Buy if doing this.*
- **Toussaint — *The Geometry of Musical Rhythm* (CRC Press, 2013).**
  Comprehensive: clave variants, West African bell patterns, bossa,
  samba, son, rumba, Aksak/Balkan, Indian talas. Includes
  *phylogenetic* groupings (rhythms organized by mutational distance)
  — that's a candidate for a *second* navigation layer on top of
  library selection, in the spirit of Grids' XY drift. *Buy if doing
  this.*
- **TR-808 / TR-909 / LinnDrum / DMX factory patterns** —
  enthusiast-transcribed, widely available, useful as a known
  reference point.
- **Hand-authored cells.** Calypso can save any pattern the user
  authors as a new library entry; the library mechanism doubles as a
  user pattern bank.

**Euclidean is deliberately not a Repetitor library** — Tidal
mini-notation has Euclidean rhythms native (`bd(3,8)`), so adding them
as a Repetitor bank would be redundant.

## Phases

### Phase 0 — Offset measurement

**Deliverable:** A short note in this doc (or a sibling
`zr-offset-measurement-2026-MM-DD.md`) recording:
- Quantized or continuous?
- Number of discrete steps across the knob sweep.
- Unit (beats? 16ths?).
- Whether step count scales with pattern length.
- Whether all three Children behave identically.

This is a 1-hour rig session. Block on it before Phase 2.

### Phase 1 — Engine + ZR libraries, headless

**Deliverable:** Erlang engine + the two ZR banks (30 patterns
transcribed from the manual), verified against a few hand-traced
expectations.

- `src/repetitor_libraries/zr_old_world.erl` — 15 patterns as
  `{Name, Length, MotherBits}` tuples. Transcribed by pixel-counting
  the manual.
- `src/repetitor_libraries/zr_new_world.erl` — same for the other 15.
- `src/repetitor_engine.erl` — `lookup/3`, `evaluate/1` covering all
  three modes. ~100 LOC.
- `test/repetitor_engine_SUITE.erl` — property tests (Child output =
  Mother shifted; offset 0 ⇒ Child = Mother bit-for-bit; modulo wrap
  at `len`) + reference vectors for a few patterns.

**Acceptance:** `evaluate` on KING 1 with all offsets = 0 returns
Mother bits identical on all four outputs, step by step, for one
measure.

**Estimate:** 1 day (mostly transcription).

### Phase 2 — Voice gen_server, clock wiring, validation

**Deliverable:** Live virtual ZR on the rig, with the same trigger
fan-out as Grids. Validated against the hardware ZR.

- `src/repetitor_voice.erl` — gen_server, ~150 LOC; mirror of
  `grids_voice.erl`.
- Wire into per-voice supervisor tree.
- **Validation harness:** parallel-record hardware ZR (via Trig31)
  and virtual Repetitor (via Tidal MIDI output) at the same tempo
  on the same pattern. Diff the MIDI streams. Patterns that don't
  match → fix transcription or fix engine. Target: zero deltas after
  one debug pass.

**Acceptance:** record VODOU 1, CLAVE, MOTORIK 1, RANDOM (at 50%),
DIVIDER (at /4 /8 /16) — virtual and hardware agree bit-for-bit.

**Estimate:** 1–2 days.

### Phase 3 — PureScript surface

**Deliverable:** `Tidal.Repetitor` exposing the set-verbs and a
`Pattern`-compatible lift. Same shape as `Tidal.Grids`.

- Newtypes, ADTs, FFI to gen_server.
- `repetitorPattern :: RepetitorConfig -> Pattern Trigger`.
- `repetitorNav :: Pattern Nav -> RepetitorVoice -> Effect Unit`
  where `Nav = SetBank | SetPattern Int | SetOffset Child Int |
  Reset`. The "Pattern of nav" lift gives you authoring tricks the
  hardware can't: e.g. *every other measure, advance the pattern
  index*; or *jux-flip the Children*.

**Acceptance:** a Calypso cell containing

```purescript
repetitor
  { bank = OldWorld
  , pattern = "KING 1"
  , offsets = { c1: 3, c2: 7, c3: 11 }
  }
```

runs and produces the right four-voice gate output.

**Estimate:** 1 day.

### Phase 4 — Calypso surface + library loader

**Deliverable:** Repetitor cell kind. Library loader for JSON banks
in `priv/libraries/`.

- Cell kind: parse `repetitor { … }` body, hot-reload.
- Library loader: walk `priv/libraries/*.json`, decode, register
  each as a selectable bank.
- Documentation for the library JSON schema so new corpora can be
  added without writing Erlang.

**Estimate:** 1 day cell + half a day loader.

### Phase 5 (optional) — Additional libraries

Pursue if/when Sethares and/or Toussaint arrive. Each library is an
afternoon of transcription. Independent of the engine work.

## Total estimate

**~4 working days for Phases 0–3** (functional system, validated
against hardware). Phase 4 +1.5 days. Phase 5 ongoing.

## Open questions

1. **Where does the Child offset measurement live in the repo?**
   Probably a markdown sibling to this plan + a fixture file
   (`test/fixtures/zr_offset_calibration.json`) consumed by the
   property tests.
2. **Mother-pattern selection: knob-only or `Pattern Int` only or
   both?** The hardware has both knob and CV. The PureScript surface
   could expose `set_pattern :: Int -> Effect Unit` *and* accept a
   `Pattern Int` for navigator-driven selection. Default: both, no
   ambiguity since the Pattern overrides any held value while it's
   running.
3. **DIVIDER mode aesthetics.** Divider mode is mostly a utility
   feature on the hardware; in software, we have `slow`/`fast`/`every`
   natively. Worth implementing for completeness and ZR fidelity, but
   it's the least-novel part of the module.
4. **Should Mother + Children be four separate voices, or one voice
   with four output channels?** Same trigger budget either way; the
   difference is whether per-output transforms (e.g. accent, choke,
   probability) can be composed independently. Probably four
   channels, single voice — matches the hardware idiom.

## Out of scope

- Recreating the panel UX (LEDs, switch). Calypso authoring replaces
  it.
- Audio output. ZR is a gate generator; sample/sound source is
  someone else's job (SuperDirt, Ableton).
- The RST button's "hold-to-pause" semantic. Pause/resume is already
  a Calypso/scheduler concern, not a per-module one.

## References

- Hardware manual: `/Volumes/Crucial4TB/Books/Manuals/Music/Noise Engineering/Noise Engineering ZR_manual.pdf`
- Pattern catalog (visual): manual pp. 5–8 (New World and Old World grids)
- Source-of-source: William Sethares, *Rhythm and Transforms*, MIT Press 2007
- Companion plan: `grids-virtual-module-plan.md`
- Framework: `sequencer-vocabulary-research-2026-05-09.md` §"What 'porting' means here (it's not a copy)"
- Validation hardware: vpme.de Trig31 (gate-to-MIDI) → iConnectivity 4c+
