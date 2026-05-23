# Slab C — Selene as notation + algebra

**Synthesized 2026-05-23** from:
- `dsl-naming-refactor-plan.md` §"Polysignals as alternate notation"
- `music/atlantis-site-planning/polysignal-algebra-2026-05-23.md`

The polysignal→Selene rename has landed in code (memory
`project_vocabulary_rename_2026_05_22`); this plan commits to **Selene**
as the name throughout. References to "polysignal" remain in the
absorbed source docs for legibility but the new types, modules, and
user surface use Selene.

## Vision

Selene is a sibling vocabulary to Tidal patterns. Where a Tidal pattern
says "at t=0 send note, at t=0.25 send note, …" (event-stream), a
Selene config says "a saw LFO at 0.5 Hz on FH-2 bank C output 3"
(declarative continuous signal). Both are first-class members of
`Session`. This is the second proper notation the polyfacetic REPL
gives us (memory: `project_polyfacetic_repl_vision`).

## The three structural moves

### 1. One Selene kind, not two

Preset is a degenerate Selene where every value-function is `const`.
Per the FH-2 manual:

```
output(t) = smoothing( direct(t)
                     + LFO_level · fade(t)
                       · Σ_shape ( amp_shape · shape(rate, phase, t) ) )
```

A preset of "3.2 V" is literally `direct = 3.2 V` with every per-shape
amplitude at zero. Structurally one kind; ergonomically two surfaces
(preset and `selene` builders both stay as shorthands).

Six basic shapes: `Sine`, `Square`, `Triangle`, `Saw`, `Random`,
`Noise`. PW is a Square parameter, not a seventh shape. Saw is
signed-amplitude (64 = zero, >64 rising, <64 falling).

### 2. Selene forms a Semigroup

The FH-2 firmware **already** sums on the jack. The spec has been
pretending this is a single LFO. Promote the algebra:

```purescript
slowTri   = selene (BankMain, Out 1) { rate = 0.5, tri = 0.8 }
sqrDetune = selene (BankMain, Out 1) { rate = 0.5, sqr = 0.3 }
studio    = slowTri <> sqrDetune
```

Two candidate monoids surface:

| Monoid                  | Semantics                                                  |
|-------------------------|------------------------------------------------------------|
| **Signal-sum**          | LFOs summed on the same jack (firmware-native)             |
| **Per-jack record merge** | Last-write-wins per jack (named operator, e.g. `<|`)     |

**`<>` is signal-sum.** The override merge gets a named operator
deferred until a concrete need surfaces.

### 3. Patterns of Selene on walker boundaries

Each operand of `<>` can be a `Pattern Selene`, switched on
bar/cycle boundaries by the walker:

```purescript
clockedHit = cat
  [ selene (BankMain, Out 1) { rate = 4.0, sqr = 0.3 }   -- bar 1
  , selene (BankMain, Out 1) { rate = 2.0, tri = 0.5 }   -- bar 2
  ]

studio = sustainedSweep <> clockedHit <> liveDetune
```

This is the musically expressive payoff — a *changing* set of summed
LFOs on the beat. Oscilab (iPad chiptune) is the existence proof that
sum-of-LFOs alone is a complete musical idiom; bar-mutability is what
makes it a first-class compositional surface.

## Realiser ceiling — spec richer than any single realiser

The Selene spec sits *above* what any single realiser can deliver:

| Realiser              | Capability                                                                                  |
|-----------------------|---------------------------------------------------------------------------------------------|
| **FH-2 firmware**     | Single rate per output; per-shape amplitudes over six fixed shapes; one phase; level; offset; fade; smoothing |
| **Virtual (BEAM)**    | Free additive synthesis: arbitrary harmonics, rates, amplitudes, phases                     |
| **ES-9 + cv-router**  | Same as Virtual, realised as a control-rate CV stream to ES-9 jacks                         |

Beyond the FH-2 ceiling — multi-rate Fourier composition — looks like:

```purescript
selene (Virtual "myMod")
  ( offset 3.2
  <> harmonic 1 0.8 sine 0.0
  <> harmonic 3 0.3 sine (pi / 4.0)
  <> harmonic 5 0.1 sine 0.0
  <> harmonic 1 0.4 tri  0.0
  )
```

A complex modulation shape in five lines.

### Capability-match compile pass

A static analysis sibling of bus-bandwidth and port-claims:

- **Same-rate composition** is free on any realiser.
- **Multi-rate composition** is free on Virtual / cv-router; on FH-2
  it must be rejected, approximated, or warned.
- **Excess summands per output** (BEAM compute budget, Rust
  per-sample budget) is a count-check, same shape as port-claims.

The realiser–spec gap is **rate-disjointness against the FH-2
realiser**, not shape-overlap.

## Architectural placement

### Session slot

Selene values are first-class members of `Session`:

```purescript
session ::
  { devices     :: Array Device
  , instruments :: Array (Instrument note)
  , drumKits    :: Array DrumKit
  , parts       :: Array AnyPart
  , selenes     :: Array Selene             -- NEW
  }
```

### Wire-out

- **FH-2**: fh2-config daemon-write protocol (existing).
- **Virtual**: control-rate sample stream onto the bus key, parallel
  to Parts but in a separate emit path.
- **ES-9 + cv-router**: same Fourier compute, output as CV stream.

Not the MIDI/OSC emit path Parts use.

### Port claims

Selene install issues port claims on `(bank, output)` (FH-2) or
`(bus, slot)` (Virtual, ES-9). Hooks into the unified port-claims
design (memory: `project_port_claims_design`,
`fh2-config/docs/port-claims-design.md`). Named owner = the Selene
binding name; capability check = realiser supports the rate/shape
spec; collision = compile-time error with the named owner that
already holds the slot.

### Realiser lowering table

| Realiser              | Lowering of `<>`                                                           |
|-----------------------|----------------------------------------------------------------------------|
| **FH-2 firmware**     | Per-shape amplitude += summand.amp; rate must match; emit one config       |
| **Virtual (BEAM)**    | Sum sample values in software before writing the bus key                   |
| **ES-9 + cv-router**  | Sum values in Rust before streaming to the jack                            |

The spec is uniform; the realisers' work is what differs.

### Calypso surface

Calypso renders Selene as a separate cell-kind alongside Voice Cells.
The continuation-marker block syntax (`<>` at line-end, memory
`reference_polysignal_continuation_marker`) parses to a `Selene`
value. The parser already exists for the line-block form; what's
new is the algebraic interpretation of `<>` as Semigroup append
rather than as a continuation glyph.

## Smallest demonstration

Same-rate shape-mix on a single FH-2 output:

```purescript
slowTri   = selene (BankMain, Out 1) { rate = 0.5, tri = 0.8 }
sqrDetune = selene (BankMain, Out 1) { rate = 0.5, sqr = 0.3 }
studio    = slowTri <> sqrDetune

-- Lowering target:
--   rate         = 0.5
--   shapeAmps    = { tri = 0.8, sqr = 0.3, others = 0 }
--   phase        = 0
--   direct       = unchanged
--   LFO_level    = max
```

If the FH-2 receives that config and the scope shows a tri+sqr mix
at 0.5 Hz, sections 1–3 are proven for the FH-2 realiser.

Then a multi-rate Fourier test against the Virtual realiser confirms
the realiser ceiling — same algebraic surface, different lowering.

## Open questions to resolve before code

1. **Walker install path.** Can the cell-boundary install machinery
   accept Selene payloads with a "fire on next bar" gate, or is that
   a new hook?
2. **Reset semantics.** The FH-2 config UI has Type + Set 1 + Set 2
   columns — probably gate-triggered phase reset. Read the manual
   section to confirm.
3. **Spec-layer exposure of FH-2 features.** Should Fade /
   Smoothing / Direct-level be first-class in the Selene spec, or
   kept as FH-2-realiser-only knobs? Lean toward first-class (they
   describe per-output continuous-signal behaviour, not firmware
   accidents).
4. **Oscilab fact-check.** Bar-mutable stack or static stack? Sets
   the priority of move 3.
5. **`<>` for per-jack record-merge.** When (if ever) do we need the
   second monoid? Punt until a real ergonomic need surfaces.
6. **Bank model.** Should `Selene` values directly carry
   `(Bank, Output)`, or should banks remain an emergent property of
   port claims? Lean toward `(Bank, Output)` in the value — explicit,
   compile-time-checkable, no port-claims dependency at type level.

## Sequencing

**Prerequisites:**

- Port-claims design lands in fh2-config (memory:
  `project_port_claims_design`). Selene install hooks into this.
- Slabs A and B of the DSL naming refactor land — Selene is
  downstream of the Session-layout work in PR 2 and the Emitable
  parameterization in PR 2.5.

**Internal sequence of Slab C:**

| Step | Scope                                                          | Demo                                                            |
|------|----------------------------------------------------------------|-----------------------------------------------------------------|
| C.1  | `Selene` type + Semigroup + FH-2 realiser lowering             | Scope shows tri+sqr mix at 0.5 Hz from `slowTri <> sqrDetune`   |
| C.2  | Walker install path for `Pattern Selene`                       | Bar-mutable stack swaps shape on cycle boundary                 |
| C.3  | Virtual (BEAM) realiser + Fourier spec                         | Multi-rate composition on Virtual; capture sample stream        |
| C.4  | ES-9 + cv-router lowering                                      | Same Fourier surface, scoped at the ES-9 jack                   |
| C.5  | Capability-match compile pass                                  | Rate-disjoint expression bound to FH-2 → compile error          |
| C.6  | Calypso cell-kind for Selene blocks                            | A `<>`-block cell parses to a Selene and installs               |

C.1 alone proves the algebra and is the smallest landable PR. C.2 is
the musical payoff. C.3+C.4 close the realiser-ceiling story.
C.5 is the static-analysis cleanup. C.6 is the user-facing surface;
the block-parser already exists, so this is lighter than it sounds.

## Out of scope

- **Slab D** (parser cluster naming, voice registry). Tracked
  separately in `dsl-naming-refactor-plan.md`. Carved out of the old
  Slab C; independent of Selene work.
- **Atlantis catalogue / discoverability surface for Selene.**
  Different layer.
- **Future third notations** (e.g. Odonus sequencers as a third
  vocabulary). When those arrive, they go in the same architectural
  slot Selene establishes here — adding `odonuses :: Array Odonus`
  to the Session record alongside `selenes`.

## References

- **Original capture (absorbed):**
  `music/atlantis-site-planning/polysignal-algebra-2026-05-23.md`.
  Kept as historical artifact; this plan supersedes it.
- **Sibling unification on the time axis:**
  `purerl-tidal/docs/signals-and-sources-2026-05-20.md` (Source/Sink).
- **Port-claims integration:** `project_port_claims_design` (memory);
  `fh2-config/docs/port-claims-design.md`.
- **User-facing block syntax:**
  `reference_polysignal_continuation_marker` (memory) — the `<>`
  line-end marker the parser already handles.
- **Architectural framing:** `project_polyfacetic_repl_vision` —
  Selene is the second proper notation; this plan is its first
  full landing.
- **Vocabulary rename:** `project_vocabulary_rename_2026_05_22` —
  authority for "Selene" over "polysignal".
- **FH-2 structural model:** confirmed against manual + UI 2026-05-23
  (see absorbed doc, Move A).
