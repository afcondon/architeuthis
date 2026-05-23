# Vetula expressivity audit

A retrospective on the four musical experiments built on top of the
V-A..V-D Vetula substrate (2026-05-22..23).  The goal was not to ship
the experiments as features but to test what the substrate can express
ergonomically — and to surface where it forces contortions.

Each experiment took the same input (McMullen Yellow progression in
C major with drop-2 voicing) and rendered it in a different musical
shape.

## What was tried

| Experiment | What changed | Code cost | Notes |
|---|---|---|---|
| **Bass-out** | Selector splits each voicing into bass vs. upper, routed to two MIDI channels | 1 new function (`vetulaSplit`), 0 new types | Cleanest of the four |
| **Arp** | Each chord arpeggiates ascending instead of stacking | 1 new function (`vetulaArp`) + 1 helper (`voicingAsArp`) | Clone of `vetulaPattern` with one inner call swapped |
| **Euclidean** | Each chord fires as Bjorklund(k, n) stabs within its cycle slot | 2 functions + a rhythm primitive | Same clone smell + 30 lines of Bjorklund |
| **Hold-across** | Common tones between adjacent voicings sustain instead of retrigger | New function + direct event construction | Most architecturally revealing; surfaced two substrate gaps |

## What the substrate did well

**The `Selector` vocabulary turned out to be load-bearing in a way I
didn't predict at V-B.**  Bass-out cost exactly one new function
because `Selector` already composed with the voice-leading pipeline —
no new types, no boundary work.  The fact that selectors carve sub-
voicings and the same selectors apply post-voice-lead means routing
decisions and harmonic decisions stay separable.  This is the
Mother-Chord insight from V-B paying off.

**The `Notation` typeclass provides a clean substrate hook.**  Each
experiment slotted in as a function returning `Pattern PitchedNote12`;
the substrate took care of scheduling, MIDI dispatch, timing.  No
experiment needed to reach below `Pattern` to make itself work.

**Small primitives compose into bigger ones.**  `closeVoicing →
VoicingStrategy → voicingAsStack → cat` is a clean ladder.  Adding a
new rung (arp, Euclidean stabs, sustained run) was always "swap one
rung, leave the rest".  That's exactly the F-algebra shape the
[[project-purerl-tidal-f-algebra]] note describes.

**The pitch-based definition of "held" survives the voicing
abstraction.**  When voice-leading falls back to `closeVoicing` on
size mismatch, position-based tracking would have been wrong; pitch-
based works regardless.  This is the correct musical definition
(common tones, à la Bach) and it dropped out cleanly.

## What the substrate forced contortions

### 1. Clone-and-swap shape repeated three times

Three of four experiments produced near-identical functions:

```
vetulaPattern   = … cat (map voicingAsStack voicings)
vetulaArp       = … cat (map voicingAsArp voicings)
vetulaEuclid k n = … cat (map (voicingAsStabs k n) voicings)
```

The differing part is one inner function call: "how do I turn a
voicing into a single-cycle Pattern?"  Everything else — the
realization of chords, the voice-leading, the `cat` outer structure —
is identical.

**Refactor**: factor out the renderer:

```purescript
vetulaRender
  :: (Voicing -> Pattern PitchedNote12)
  -> VetulaPart
  -> Pattern PitchedNote12
vetulaRender render (VetulaPart r) = …

vetulaPattern  = vetulaRender voicingAsStack
vetulaArp      = vetulaRender voicingAsArp
vetulaEuclid k n = vetulaRender (voicingAsStabs k n)
```

Reverse-arp, random-arp, drop-the-lowest-each-cycle, etc. all become
trivial new renderers.  *The renderer is the extension point we
keep adding.*

This refactor is mandatory before adding a fifth rendering style.

### 2. The substrate's emit path doesn't honour multi-cycle whole arcs

This is the big finding.  The hold-across experiment naturally wanted
to say "this note's MIDI event has whole arc `[startCycle,
startCycle + runLen)`".  The voice gen_server's `computeDiscrete` in
`Tidal.Voice` queries the Pattern *every tick by part-arc* and
dispatches whatever overlaps.  So a multi-cycle whole gets re-fired
every cycle boundary — defeating the held semantics.

The workaround is to emit a single-cycle event at the run start and
rely on the Instrument's `defDurMs` to ring through the run.  This
works for an experiment but it's hack-shaped: defDurMs is fixed per
Instrument, so all events on that instrument inherit the same long
duration — transient single-cycle events bleed into following chords.

Two related substrate gaps converge here:

- **Per-event note duration**: task #88 (`noteLength` / `legato`)
  would let us pass duration per event via `# legato 5`.  Currently
  it lives on the Instrument.
- **Whole-arc as emission identity**: the voice gen_server could
  filter out events whose `whole.start < lastEmittedUntil`, treating
  them as already-emitted.  This would make the original
  multi-cycle whole approach work and would be the cleaner fix.

Without both, Patterns can't fully express what they look like they
should be able to.  Whole arcs are syntactically present but
semantically inert.

### 3. Direct event construction doesn't loop

`vetulaPattern` (built from `cat`) loops automatically because `cat`
does mod-cycle indexing — a 4-chord progression cycles through chords
indefinitely.  My direct event construction in `vetulaHeld` had to
re-derive that semantics manually with an explicit `progLen`
parameter and per-query iteration loop.  I forgot the first time;
the user heard silence after cycle 18.

**Suggested substrate add**: a combinator like

```purescript
repeatEvery :: Int -> Pattern a -> Pattern a
```

that wraps a finite-cycle pattern into a looping one by mod-cycle
indexing the query arc.  Any direct-event-construction pattern that
wants to loop should pass through this.  The trap of forgetting it
is real and silent (works in tests with short query arcs; fails in
production with long arcs).

### 4. Voicing-level operations don't compose at the Pattern level

Selectors operate on `Voicing` — they need access to the voicing
structure.  By the time we're at `Pattern PitchedNote12`, the
voicing has been flattened into parallel events; there's no way to
recover "the lowest note of this chord" from the Pattern alone.

That's why `vetulaSplit` had to be a separate function with the
Selector field embedded in its signature, rather than a Pattern-level
transformation like `selectVoices :: Selector -> Pattern a -> Pattern a`.

This is a fundamental layering choice — `Pattern` is too low-level to
carry chord structure.  Not a bug, but worth being aware of: chord-
shape operations live above Pattern, not on top of it.

## Substrate gaps surfaced (rolled-up)

In rough priority order for closing:

1. **Per-event note duration** (task #88) — currently per-Instrument
   only.  Blocks proper hold-across.
2. **Whole-arc-aware emission** in `Tidal.Voice.computeDiscrete` —
   filter events whose `whole.start < lastEmittedUntil`.  Pair with
   #1 to enable true sustained-event semantics.
3. ~~**`repeatEvery :: Int -> Pattern a -> Pattern a`** substrate helper
   so any direct event construction loops correctly without
   re-deriving mod-cycle indexing.~~  **DONE 2026-05-23.**  Added to
   `Tidal.Pattern.Core` next to `rotL` / `rotR`; `sustainedPattern`
   in `Vetula.Pattern` now uses it instead of an inline iteration loop.
4. **`vetulaRender` factoring** so adding a new chord renderer is a
   one-liner rather than a clone-and-swap.
5. **Voice-leading drift mitigation** — over 18 chords McMullen Yellow
   marches steadily downward in register because `voiceLead`'s
   nearest-octave choice can compound directionally.  Worth an
   anchor / re-centre step every N chords, or a global "centroid
   drift" constraint.

## What gets done next

Take this audit as input to a small refactor PR:

- **R1**: Factor `vetulaRender` and rewrite `vetulaPattern` / `vetulaArp`
  / `vetulaEuclid` against it.  Pure refactor, no behaviour change.
- **R2**: Add `repeatEvery` to `Tidal.Pattern.Core` (or a sibling
  module).  Use it in `sustainedPattern` for `vetulaHeld`.  Pure
  refactor + a substrate add.

R3/R4 are substrate-level (task #88 and voice-gen-server whole-arc
filtering); they're separately scoped and live in their own follow-ups.

## Meta-finding

The most useful single insight from the audit: **the experiments
revealed the *direction* of the gradient**.  Whatever-the-eDSL
naturally expressed with a one-line change was the right shape;
whatever required scaffolding (cloning, re-deriving cat's mod-cycle
indexing, working around defDurMs) was the substrate trying to tell
us where it's thin.  Run more experiments like this — each surfaces
one or two substrate weaknesses that are otherwise invisible until a
musical situation forces them.

---

*Generated 2026-05-23 after the bass-out / arp / Euclidean /
hold-across sequence.*
