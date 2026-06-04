# Genre-centres + tarot-controlled perturbations

The generative model behind tarot-music → Calypso. Not a single grand
structure (no one 5×5), but a small **algebra of perturbations applied to named
centres**, with the tarot draw dialling the operators. This note captures the
design as of the accent/Lumbeat session so the next one starts here.

## The trunk

- A **genre-centre** is a named base groove — a `Genre` of `VoiceArchetype`s,
  each a `StepProfile` (per-step strengths) + a `token` (instrument). The
  strength doubles as the **gain/accent** (rendered as MIDI velocity / Dirt amp
  / modular accent — proved end-to-end this session; see `typed-edsl-plan.md`).
- A **tarot draw** selects a centre (the significator/Major → genre) and a seed,
  then **perturbs** it. Variation isn't random noise; it's a controlled set of
  operators, each with a musical meaning.
- Centres are cheap to add: transcribe a few patterns per source as loci, then
  let the perturbation operators generate the surrounding family — rather than
  hand-transcribing every variation.

## The perturbation algebra

Operators that move you *around* a centre:

| operator | what it does | status |
|---|---|---|
| **density** | busier / sparser — threshold sweep on the StepProfile | done (`Genre.density`) |
| **re-voicing** | same rhythm, different percussion (reassign `token`s over fixed `profile`s) | designed below; ~trivial to add |
| **swing / feel** | groove laid on the grid (`swingByR`); orthogonal to structure | done (`Tempo.swing`/`swingN`) |
| **fills / decoration** | drummer-like additions over the skeleton | parked (Grids-ish — see below) |
| displacement / rotation, variation-blend | shift/rotate a row; crossfade two centres | future |

The tarot draw is the controller that dials these. This *is* the unifying idea —
a small algebra over centres, not one monolithic map.

## Re-voicing (the next operator to build)

Observation (from Afro-Latin Drum Machine): some variations are **only voice
changes** — identical rhythmic pattern, different percussion channels. In our
model that's almost free: a `VoiceArchetype` is `{ profile, token }`; re-voicing
**reassigns `token`s across the profiles while the profiles stay fixed**. The
groove is invariant; the instruments carrying it change. Literally moving a grid
row to a different instrument row.

The key refinement: **permutations have degrees of disruption**, and that degree
is what maps to tarot card choices —

- kick → lo-tom: *minor*
- swap closed ↔ open hi-hat: *moderate*
- swap kick ↔ snare: *strong*
- swap hi-hat ↔ kick: *extreme*

So re-voicing isn't "permute at random." It's a **disruption-weighted matrix**:
each possible change carries an intensity weight, and the sampler picks from a
**weighted distribution — mild changes common, extreme rare-but-possible** — so
we avoid cacophony while still allowing interesting accidents. The tarot draw
sets the disruption budget (e.g. a card's rank/suit → how far from the natural
orchestration we're allowed to roam).

Implementation shape:
- The centre defines base voices (profiles + their "natural" tokens) and a
  **re-voicing palette / change-matrix** (the allowed swaps + weights), so
  changes stay musical (mirrors Lumbeat's "natural config + alternatives").
- A seeded sampler step applies a weighted draw of changes within the budget.
- One base Guaguanco + a palette → the whole family, no re-transcription.

## Capture discipline (for transcribing centres)

- **Record with swing OFF** to get the grid honest — fit a clean step grid, then
  **note the correct swing% separately** as metadata (`Tempo.swing`). Structure
  and feel are orthogonal layers; the engine re-applies swing via `swingByR`.
  (Makuta: grid transcribed straight, swing noted at ~25%.)
- **MIDI capture > hand grids** for richer material: recording the app's output
  preserves the actual notes + velocities + fills, *and* sidesteps the
  note→pad mapping problem (re-emit the recorded notes; the rack plays them
  back identically). Same `pattern`/`gains` shape, multi-bar. A `.mid` reader is
  the small piece of new tooling; it doubles as the corpus front-end below.
- A proper **named drum-mapping system** (token → device/pad, per kit) is
  deferred — this session hand-set notes per rack as a stopgap.
- **Swing calibration is an A/B, not a guess.** The %→depth mapping
  (Lumbeat swing% → our `swingByR` depth) is currently eyeballed (25% → 0.25;
  Bembé 50% on 12/8 is a flagged approximation). To calibrate: record Lumbeat's
  MIDI out *and* our output into parallel Ableton tracks at the same tempo,
  overlay, and read the per-hit timing offsets — that gives the true mapping and
  confirms whether `swingByR` even models the feel (esp. 12/8 triplet swing,
  which the 16th-shuffle mechanism may not). "Close enough" until then.

## Parked: AfroLatin-Grids / corpus-derived kernel

A deeper generative kernel for *one* family (e.g. Guaguanco's variations,
Bembé's 7), in the spirit of MI Grids — and we already have the runtime:
**Balistes** (`balistes_engine.erl` / `balistes_tables.erl`) is a BEAM-native
Grids port (node-map + per-step strength tables + density threshold + accent →
velocity). "AfroLatin Grids" = **new tables for Balistes**, not a new engine.

The mechanism that makes it work: Grids encodes per-step *strength*; the
density knob is a threshold (`fire when strength clears (max − density)`). A
recording with the **Jam-Intensity slider swept** gives exactly that —
`P(hit | intensity)` per step separates **core hits** (present at low intensity →
high strength) from **fills** (only at high intensity → low strength). Velocity
distribution per step → the accent table. The named variations become nodes /
extra data.

Spectrum (start interpretable, escalate only if needed), all fed by the *same*
recordings:
1. hand-derived tables (curated basis patterns)
2. statistical tables from the corpus (intensity-swept captures)
3. a learned model emitting **our** representation (per-step strength + velocity
   + optional micro-timing, conditioned on intensity/style) — a learned Grids
   table, still interpretable/editable, plugs into Balistes. (cf. Magenta
   GrooVAE for the humanisation half.)

Notes:
- Grids' expressive economy is the lesson: **25 nodes × interpolation × a
  threshold** feels infinite. The recipe generalises to any rhythmic form with
  a few basis patterns + a meaningful axis.
- We are **not** reverse-engineering the Lumbeat apps (labours of love). We
  treat them as an oracle: sample the output, fit our own compact kernel. Any
  model stays personal-use.

## Parked: Euclidean-Balistes → FH-2

A Balistes variant whose node-map is a progressive matrix of **Euclidean
rhythms** ((k,n) parameter points, interpolated). Natural fit for Balistes'
structure and FH-2's Euclidean support.

Latency caveat + resolution: sending a new FH-2 *preset* per dial-step would be
too slow for Grids-style continuous sweeps. But we don't have to — **generate
the resulting gate pattern in Balistes and fire gates through the existing gate
path**; no FH-2 reconfiguration per step, so no preset round-trip, no sweep
latency. FH-2 stays a dumb gate sink; the rhythm lives in the BEAM.

## Where things stand (this session)

- Accent pipeline proved end-to-end: `Sound.gain` → MIDI velocity (808
  waveform staircase in Ableton). Typed-`Sound` eDSL realignment landed
  (`typed-edsl-plan.md`).
- First centre: **Makuta** (`Generate/Genres/Makuta.purs`), 5 AfroLatin voices,
  velocity levels in `Generate/Genres/AccentLevels.purs`, mapped to Wheel of
  Fortune.
- Direct-deal CLI: `calypso/scripts/deal.mjs <genre> [seed]` (pen-dance →
  `/session-source` build → transport), so a specific groove can be auditioned
  without a random draw — and the agent can fire it for testing.
