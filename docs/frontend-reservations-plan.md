# Frontend Reservations — design plan

**Status:** Design draft (2026-05-17).  Outgrowth of the 2026-05-17
pattern-language brainstorm that followed Slab A PR 2b.  The
brainstorm produced a useful taxonomy that's parked for now in
favour of a small, immediately-shippable thing: **surface the rig's
implicit resource claims to the frontend and catch conflicts at
load time**.

**Companion docs:**
- `fh2-config/docs/port-claims-design.md` — the backend model
  (already device-agnostic: capabilities, bitmask claims, owner IDs,
  overlap classification).  Spells out that the only FH-2-specific
  bits are the `Bank` constructors and `bankCapability`.
- `purerl-tidal/docs/dsl-naming-refactor-plan.md` — Slab A
  (Instrument / DrumKit substrate) which this builds on.

---

## Why this exists — pattern-language brainstorm context

The brainstorm started from a different question — "should FH-2
polysignals be a peer notation to Tidal mini-notation?" — and
broadened into a taxonomy of *executor families* before landing on
a much smaller, more concrete deliverable.

### Executor families (the long-term picture)

A pattern language presupposes a machine to execute it.  The
**executor type** is the organising axis.  Five families surfaced
in the brainstorm:

1. **Query-driven event streams** — engine asks the pattern "what
   fires at time *t*?".  Mini-notation (have), tracker rows
   (.mod / Renoise / Sunvox), step-sequencer p-locks (Elektron,
   Tempest), Reich-style phasing.
2. **Config-driven autonomy** — upload a description; hardware /
   process runs itself.  Polysignals (have one foot in), FM
   operator graphs (DX7 algorithms), modular patch sheets,
   René / Marbles / Metropolix XY-grid sequencers.
3. **Rule-driven generation** — declare relationships; system
   unfolds them.  Tintinnabuli (have), Fugue Machine (have),
   Tonnetz / P-L-R voice-leading, 12-tone matrices, L-systems,
   cellular automata.
4. **Form-filling** — specify shape; details get filled at execution
   time.  Jazz lead-sheets, score forms (intro / A / B / coda),
   Schenkerian voice-leading skeletons.
5. **Spatial / non-time** — a chart that the machine reads with its
   own clock.  Knitting / weaving drafts, TR-style drum-grid
   cards, Laban choreographic notation.

Two additional categories emerged in the conversation:

6. **Capture-and-transform** (Andrew's extension) — Arbhar / Lubadh
   / Morphagene.  These *consume another executor's output* and
   re-emit it transformed.  A **recursion point** in the rig.
7. **Human-as-executor** (Andrew's extension) — string quartet,
   saxophonist, screen-facing live-notation systems (Anthony
   Brown's Decibel ScorePlayer, Nick Didkovsky's JMSL).  Real
   tradition; our substrate (Pitch / Scale / Pattern) is already
   close to score-able.

### Key insights worth keeping

- **Patterns-for-time vs patterns-for-structure** are different
  layers.  Mini-notation describes what fires when (time-pattern);
  an FM patch describes an instrument's shape (structure-pattern).
  Polysignals straddle the line — they describe an
  instrument-like autonomous behaviour AND emit events — which
  may be exactly why they feel like peer-notation candidates.
- **Config-driven executors deserve their own first-class
  notation**.  A human reading a score and an FH-2 receiving a
  polysignal are structurally the same kind of executor: "here's a
  description, run it autonomously."  Naming that family makes
  human-as-executor a sibling, not a separate one-off feature.
- **Structure-over-cardinality** might be the shared abstraction.
  Mini-notation applies "evenly distributed / rotated by N /
  ratioed / filtered to subset" to time.  A polysignal mini could
  apply the same to outputs.  A looper mini could apply it to
  capture-and-playback recipes.  *Patterns describe structural
  relationships over a fixed cardinality.*  Not committing to this
  yet — flag it for later.

### Why none of this is being built right now

The abstraction isn't ripe.  Committing to the executor-families
taxonomy now would over-fit on three or four data points (we have
real working code for one family, partial sketches for two more, and
intuitions for the rest).  The brainstorm bought us **vocabulary**
and a **direction**, not a design.

What *is* ripe — and the rest of this doc — is a tiny,
immediately-useful win that draws on the brainstorm's clarity: a
**reservation language** for rig resources.  It's the smallest thing
that's still language-shaped (composition, structure, meaningful
errors) and it serves the user concretely by catching #fail
scenarios before they hit hardware.

---

## What we're building — frontend reservations

### The observation

The backend model in `port-claims-design.md` is already
device-agnostic.  Capabilities, bitmask claims, owner IDs, overlap
classification, eviction policy — all of it works for any device
whose outputs partition into capability-typed banks.  The only
FH-2-specific bits are:

- The `Bank` constructors (`BankMain`, `BankCv N`, `BankGt N`)
- The `bankCapability` function

Today, only FH-2 is in the claim table.  Other resources are
managed by *implicit declarations* in Studio.purs:

```purescript
bass1 = midi iac 1          -- implicit claim: iac MIDI ch 1
qd1   = midiDrumKit fh2qd 14 [hit "bd" 36 100 50, …]
                            -- implicit claim: fh2qd MIDI ch 14
```

No enforcement.  Two `Instrument`s on `iac` ch 1 happily coexist,
and the user hears chaos when they fire.

### Three failure modes worth distinguishing

1. **Card targets an alias that doesn't exist.**  Caught today by
   the walker + arm path.
2. **Two declarations claim the same resource.**  Silent today.
3. **A card uses a resource its alias didn't claim** (e.g., a
   setup cell with `fh2-gate 4 65 14` bypasses the typed
   declarations).  Silent today.

The reservation language enforces all three.

### The frontend surface

#### Typed declarations stay as they are

Every existing Studio.purs declaration is *already* a reservation:

```purescript
bass1 = midi iac 1                          -- claims iac ch 1
qd1   = midiDrumKit fh2qd 14 [hit …]        -- claims fh2qd ch 14
```

These are PureScript function calls, not new syntax.  The
"reservation language" for this case is just *running validation
over the existing declarations*.

#### Explicit `reserve` for un-typed resources

Setup-cell verbs (`fh2-gate 4 65 14`, `fh2-envelope 0 14`, etc.) and
polysignal verbs (`polylfo myLfo main`) don't have a typed
declaration today.  For those, a new declaration form in
Studio.purs:

```purescript
-- "These FH-2 main-bank outputs (0-3) are reserved for setup
-- cells; reject any cell that targets an output outside this set."
setupGates = reserveFh2 (slotsOf [0,1,2,3]) NeedGate

-- Or a polysignal block claiming a whole bank:
myLfoClaim = reservePolySignal "myLFO" Fh2Main fullMask
```

The forms compile to `Claim` values that feed the same
`applyClaim` validator as the FH-2 polysignal claims.  No new
backend mechanism — just new namespace entries.

### Extending the `Bank` namespace

To cover the resources Studio.purs actually claims, we extend
`Bank`:

```purescript
data Bank
  = BankFh2  Fh2Bank
  | BankEs9  Es9Bank
  | BankMidi { device :: String }   -- 16-channel namespace per device alias

data Fh2Bank = Fh2Main | Fh2Cv Int | Fh2Gt Int | Fh2Es5 Int
data Es9Bank = Es9Panel | Es9Cv Int | Es9Gt Int | Es9Es5 Int
```

For `BankMidi`, slots are MIDI channels 1-16 (or 0-15
internally).  Capability is something simple — a MIDI channel
"emits MIDI" — which makes the capability check trivially true.
What matters is *uniqueness*.

The existing `BankMask` (8-bit) needs to widen to 16-bit for MIDI.
The mask abstraction is fine; just generalise the int width.  (Or
use a `Bank → Int → SlotKey` indirection so MIDI's 16 channels and
FH-2's 8 jacks both fit.)

### Validation passes

1. **Load-time pass** — runs when the walker assembles the
   `Session`.  Builds a `ClaimTable` from all Studio.purs
   declarations + explicit `reserve` forms.  Reports duplicate
   claims as errors (with named owners, slot list, conflicting
   alias).  The frontend (Calypso) shows the errors on the
   composition pane.

2. **Arm-time pass** — when a card fires, check that any resources
   it touches (channel, output, polysignal bank) match a claim
   under that owner.  Mismatch → arm fails with a clear message.

---

## Phasing

### Phase 1: surface implicit MIDI claims, dup detection

Smallest possible useful slice.

- Generalise `Bank` to include `BankMidi { device :: String }`.
- Generalise `BankMask` (or its slot indexing) to handle 16-channel
  banks.
- Run a load-time pass that builds a `ClaimTable` from Studio.purs
  declarations alone (no `reserve` form yet) and reports duplicates.
- Surface errors in Calypso's composition pane.

Acceptance: two `Instrument`s claiming `iac` ch 1 produces a clear
error at composition-load time naming both aliases.

### Phase 2: ES-9 banks

- Add `BankEs9` constructors per `port-claims-design.md` section
  on cross-device extension.
- Register existing ES-9 tvoices as single-slot claims so
  partial-conflict detection covers them.

Acceptance: declaring two voices on the same ES-9 panel jack
produces an error.

### Phase 3: explicit `reserve` for setup-cell-style claims

- Add `reserveFh2` / `reserveEs9` / `reserveMidi` smart constructors
  in `Calypso.Prelude`.
- Walker recognises `reserve…` declarations and emits the right
  `Claim` events.
- Setup cells (`fh2-gate`, `fh2-envelope`) validated against the
  declared reserves.

Acceptance: a setup cell targeting an output not in any
`reserveFh2` declaration produces an error before the cell fires.

### Phase 4: connect to fh2-config's ClaimTable

The backend `port-claims-design.md` puts the claim state in the
fh2-config daemon.  Phases 1-3 above keep a *separate* claim table
in purerl-tidal covering MIDI + ES-9 + Studio declarations.  Phase
4 reconciles: either (a) move the FH-2 claim authority into
purerl-tidal so there's one table, or (b) keep them separate and
have purerl-tidal query fh2-config for FH-2 claims during validation.

Decision deferred — both are tractable, and the right answer
probably depends on how the polysignal frontend work shapes up
(Slab C territory).

---

## What's intentionally NOT here

- **Polysignal mini-notation** (a Tidal-mini-style surface for
  rate/phase/euclidean polysignal blocks).  Tabled from the
  brainstorm.  Useful, shippable, but its own piece of work.  The
  reservation work above doesn't preclude it — in fact, the
  reservation system gives polysignal-mini a place to slot its
  port-claims into.
- **Score-for-humans output** (Lilypond / MusicXML render of
  patterns for screen-facing live notation).  Aspirational sibling
  of the polysignal-mini work.  Same substrate.
- **Looper / capture-transform mini-notation.**  Third executor
  category from the brainstorm.  Needs more concrete experience
  with Arbhar / Lubadh / Morphagene control to design well.
- **The full executor-families abstraction.**  Premature.

---

## Pointers

- Backend model: `fh2-config/docs/port-claims-design.md`
- Slab A scope: `purerl-tidal/docs/dsl-naming-refactor-plan.md`
- Memory: `feedback_purerl_erlang_boundary_principle` — applies
  here too: type-discrimination in PureScript, OTP/ETS/IO in
  Erlang.  Claim validation lives in PureScript; the ETS table
  that *stores* claims lives in Erlang.
