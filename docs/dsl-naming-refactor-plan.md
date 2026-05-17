# DSL Naming Refactor Plan — Instrument/Part Substrate

**Status (end-of-day 2026-05-17):** PR 1 + PR 1.5 + PR 2a landed on
branch `dsl-naming-slab-a`.  PR 2b and PR 2c remain.

**Branch + commits:**
- `b74d890` — PR 1 (renames + drop phantom mvoice)
- `7cd6f2d` — PR 1.5 (walker hoist into PureScript)
- `728a7cb` — PR 2a (DrumKit + DrumPart + drum parser)

**What landed in PR 2a:**
- New `DrumKit`, `DrumHit`, `DrumPart` types in `Calypso.Prelude`.
- `Instrument` keeps its 5-field shape; smart-ctor `midi` hides the
  system defaults from user-facing Studio declarations.
- `on` typeclass-resolved across Instrument/DrumKit; `Erase`
  typeclass extended for DrumPart; `eraseAll` + `<+>` operator for
  per-kind erasure.
- `drum` parser in `Tidal.Drum` delegates to `mini` + projects out
  Sample names; full mini-notation grammar works.
- Walker emits `RegisterMidiDrumKit` events; Erlang shell registers
  each kit as one MIDI binding using first-hit defaults.
- Conductor's `ArmCommand` carries a `Destination` sum
  (DestInstrument | DestDrumKit); `AnyDrumPart` bodies are
  `Sample`-coerced at the conductor boundary so the dispatcher's
  Pattern-Pitch path handles drums unchanged.
- Handler.erl's `resolve_cue_body` inspects destination tag and
  calls `drumPatternToPitch` for DrumKit-destined parts.

**End-to-end test passed:** reload-baseline reports
`(3 device(s), 4 instrument(s), 2 drum kit(s))`; `play-armed qd1
qd1A` produces MIDI events visible at the FH-2; `drum "bd*4"`,
`drum "bd(3,8)"`, `drum "[bd sn]*2"` all parse correctly.

**What's left for PR 2b** (next session, queued as task #61
recreated post-completion if needed):
- **Per-hit MIDI bindings.**  Today PR 2a registers each DrumKit as
  *one* MIDI binding using the first-hit's defaults — so all hits
  fire the same MIDI note.  PR 2b fans out to N per-hit bindings
  (`<kitAlias>.<hitName>`) so each declared hit's (note, vel,
  durMs) actually dispatches per-event.
- **Per-event vel/dur for pitched parts.**  Today's Pitched
  Instruments still keep a binding-level defNote/defVel/defDurMs.
  PR 2b drops these — pattern events must carry their own vel/dur
  (via `# vel 0.7` style attach), and the dispatcher spec
  `midi-note <alias> <ch>` shrinks accordingly.
- **Voice supervisor extension or per-hit-binding-split at arm
  time.**  The current `set_voice_pat(VoiceName, Binding, Pat)`
  assumes one binding per voice; PR 2b needs either a multi-binding
  variant or a per-event binding lookup.  Open design question:
  decompose drum patterns into N sub-arms (one per hit) vs. extend
  the voice gen_server.

**Boundary additions for PR 2b** (in `Tidal.SessionWalker`):
- Extend `RegisterMidiDrumKit` with `hits :: Array DrumHit` field
  (the walker has them but currently drops all but the first).
- New Erlang `apply_event` clause registers each hit as a binding
  named `<kitAlias>.<hitName>` via additional
  `set_binding_from_spec` calls.

**Specific gotchas to remember when resuming:**
- See `reference_purerl_tidal_silent_routing_check_power` — if
  modular routing silent and IAC works, suspect rack power; both
  link-spike (port 57122/udp) and purerl-tidal cache CoreMIDI
  destinations at startup.
- See `reference_purerl_array_is_erlang_array_module` — `Array a`
  on the BEAM is the stdlib `array` module, not a list; FFI
  primitives must `array:from_list/1` on entry and `array:to_list/1`
  on exit.
- See `reference_purs_backend_erl_constructor_encoding` — nullary
  constructors encode as 1-tuples (`{nothing}`), never bare atoms.
- Calypso's arm-rebuild path rewrites disk Session.purs based on
  `cell.source`.  If the user edits a typeful cell to just the
  inner pattern (`drum "..."` without the `on "mv" kit (...)`
  wrapper), the disk gets that broken form and compile fails on
  next ▶ run.  This is a known UX trap of the typeful-cells
  projection.

**Companion docs:** `per-voice-refactor-plan.md`,
`polyvoice-cookbook.md`.
**Companion memory:** `feedback_purerl_erlang_boundary_principle`.

## Why this exists

After the MVP-1→4 substrate work landed (pitch substrate, Pattern-of-patterns,
tintinnabuli, four-voice diatonic fugue), several names in the user-facing DSL
read as artefacts of earlier design choices rather than what the system now
actually is:

- **"Cue"** was named when there was a deliberate gap between arming a
  pattern and it sounding. Latency reduction has collapsed that gap; the
  name now sells the wrong mental model.
- **"Channel"** is overloaded — the data type contains a MIDI channel
  number as one of its five positional fields, so `Channel iac 1 36 100 50`
  reads as inscrutable magic, and "channel" the type-name conflicts with
  "channel" the field-name.
- **Channel's tail of default-note/vel/dur** forces a decision at
  declaration time that is meaningless 95% of the time (the defaults are
  only ever used for drum hits, never for melodic parts).
- **`Pattern Pitch` as the body type** quietly assumes 12-TET equal-tempered
  pitch is the One True musical event model. We already know we want maqam
  microtonality, MPE per-note expression, and (more pragmatically) microtonal
  V/oct CV — none of which fit cleanly under `Pitch`.
- **The phantom mvoice on `Cue "fugue"`** forces `[anyCue x, anyCue y, …]`
  per-element wrapping at the Session bag because PureScript arrays are
  homogeneous and phantom-types differ across voices. The repetition is
  cognitive load and a typo opportunity.

This plan addresses all of the above across a series of staged slabs
(A, A-residual, B, C), with the slate of decisions D1–D8 documented as
motivation. A scope discovery during the initial implementation reading
on 2026-05-17 added a load-bearing architectural principle — the
PureScript/Erlang boundary rule — which inserts a walker-hoist step
(PR 1.5) between the surface renames and the destination-split work.

## Architectural principle: the PureScript / Erlang boundary

**Type-discrimination logic lives in PureScript; OTP / ETS / IO /
scheduling lives in Erlang. The boundary between them is a small set
of flat registration-event / command ADTs. Erlang never reaches into
purs-backend-erl-encoded values to ask "what kind is this?".**

This principle surfaced on 2026-05-17 while scoping Slab A. Reading
the existing `tidal_session_walker.erl` revealed that the Erlang side
does ad-hoc classification on PureScript-encoded ADT shapes — clauses
like `element(1, V) =:= channel` and map-key-presence sniffing on
newtype-elided records. Every PureScript type rename ripples there
twice (the change *and* the Erlang catch-up), and every new variant
requires Erlang to learn it. This coupling is the underlying reason
Slab A's scope ballooned when read seriously.

The principle resolves it: PureScript walks its own types and produces
something Erlang can apply without knowing PureScript's shape. The
boundary is a small, intentional ADT, not the rich session/instrument/
part ADTs the DSL is allowed to evolve.

### Stays in Erlang

- gen_servers and supervisor trees (`tidal_voice`,
  `tidal_voice_sup`, `tidal_dispatcher`)
- ETS-backed hot-path lookups (`tidal_control_bus`,
  `tidal_scale_bus`, channel alias table)
- Real-time scheduling, Link anchor (`tidal_clock`,
  `tidal_link_anchor`)
- MIDI/OSC IO (the dispatcher's send path)
- Process lifecycle, monitors, message passing

This is exactly what BEAM is for. Rewriting it in PureScript would
be reinventing OTP badly.

### Moves to PureScript

- The walker's type-classify clauses (`tidal_session_walker.erl`
  lines 181–198 in the current head)
- The dispatcher spec parser (the `"midi-note alias ch note vel
  dur"` string format — it exists because there was no other way
  to push structured registration data across; with purerl there
  is)
- Conductor-side type discrimination
- Anywhere else Erlang uses `element/2` or map-key matching to
  reach into PureScript-shaped data

### The boundary ADT (sketch)

```purescript
data RegistrationEvent
  = RegisterMidiDevice
      { alias :: String, name :: String, latencyMs :: Int }
  | RegisterMidiInstrument
      { alias :: String, deviceAlias :: String, channel :: Int }
  | RegisterDrumKit
      { alias :: String, deviceAlias :: String, channel :: Int
      , hits :: Array DrumHit }
  | RegisterVPerOct
      { alias :: String, routerAlias :: String, bus :: Int }
```

Erlang's `tidal_session_walker` becomes a thin shell:

```erlang
walk_baseline() ->
    Events = 'tidal_session_walker@ps':walk(),
    lists:foreach(fun apply_event/1, Events).

apply_event({registerMidiDevice, #{alias := A, name := N, latencyMs := L}}) ->
    tidal_dispatcher:register_midi_device(A, N, L);
apply_event({registerMidiInstrument, #{alias := A, deviceAlias := D, channel := C}}) ->
    tidal_dispatcher:register_midi_instrument(A, D, C);
%% one clause per registration-event constructor — small and stable
```

The Erlang clauses match on the **registration-event ADT** (small,
stable, intentional) — not on the **Session ADT** (rich, churning,
DSL-implementation detail). The session ADT is opaque from Erlang's
perspective. Existentials, nullary-constructor tuple-wrapping,
typeclass dictionaries — all the purs-backend-erl encoding details
become invisible across this seam.

### The deciding question

When evaluating "should X live in PureScript or Erlang?":

- Does X need to know a PureScript ADT's shape? → PureScript.
- Does X need OTP, ETS, or IO? → Erlang.
- Things that need both have a **flat-data boundary** between them.

### When this lands

PR 1.5 (below) — hoisting the walker into PureScript. Scheduled
between PR 1 (surface renames) and PR 2 (destination split) so the
destination split's new variants land cleanly via additional
PureScript walker cases, and so Slab B's existentials never produce
a wire-format question on the Erlang side.

This principle should also guide all future work in purerl-tidal: any
new feature that requires Erlang to know about a PureScript ADT
shape is a feature whose discrimination logic belongs in PureScript,
with a flat-data hand-off.

## The decisions slate (D1–D8)

| # | Decision |
|---|---|
| D1 | `Cue` → `Part`. Names what it actually is now that arm-and-sound have collapsed. |
| D3 | `Channel` → `Instrument`. Less overloaded, more honest about role. |
| D4 | `Instrument` is a sum over routing fabrics: `MidiInstrument` + `VPerOctInstrument`, future siblings welcome. |
| D5 | Polysignals are a Session-level declaration alongside Parts, not a kind of Instrument. They are autonomous configurations on a device, not destinations a Part can target. |
| D6 | Two destination kinds: `Instrument` (pitched, routing-only) and `DrumKit` (drum/sample, named hits with per-hit defaults). Part splits into `PitchedPart` / `DrumPart`. |
| D7 | `Pattern` stays polymorphic in event type. `Instrument` and `PitchedPart` are parameterized by note type even though today only one variant exists (`PitchedNote12`). Conductor emits via an `Emitable note` typeclass so new note types (maqam, MPE, microtonal CV) drop in without touching the conductor. Rename `Pitch` → `PitchedNote12` to surface "this is one note model among many." |
| D8 | Drop the phantom mvoice from Parts; store mvoice as a runtime String set by `on`. Makes `parts :: Array AnyPart` enumerable via `map erase` per kind. A future voice-registry (`VoiceName "fugue"` as typed witness) can restore compile-time grouping without bringing back per-element wrapping. |

D2 was a transient proposal during conversation (split Part body by pitched/
unpitched) and was absorbed by D6 (split happens at the destination type
level, body type follows). Skipping D2 in the numbering is intentional and
preserves traceability to the conversation that produced this plan.

## The coherence story (one paragraph)

D1 and D3 are honesty renames. D4–D6 are the structural consequences of
taking those names seriously: once you say "Instrument" you have to admit
that ES-9 via OSC is one, polysignals are not one, and drum hits live in a
different shape from melodic destinations. D7 and D8 are the extensibility
moves: keep Pattern polymorphic so timing combinators work over any event
type (Dilla, swing, humanization are free), and drop the phantom mvoice so
the heterogeneous-array problem dissolves into one `map erase` per
part-kind. The result is a closed core of well-named types, open at exactly
the seams that have visible future extensions.

## End-state user surface

**Studio.purs** (rig declaration; touched rarely):

```purescript
module Studio where

import Calypso.Prelude

-- MIDI devices --------------------------------------------------------------
iac      = midiDevice "IAC Driver Tidal"
fh2      = midiDevice "Expert Sleepers FH-2"
fh2qd    = midiDevice "Expert Sleepers FH-2 QD"

-- OSC routers ---------------------------------------------------------------
cvRouter = CvRouter { host: "127.0.0.1", port: 57120 }

-- Pitched instruments — pure routing, no defaults --------------------------
bass1, bass2, bass3, bass4 :: Instrument PitchedNote12
bass1 = midi iac 1
bass2 = midi iac 2
bass3 = midi iac 3
bass4 = midi iac 4

lead1 :: Instrument PitchedNote12
lead1 = midi iac 5

vco1, vco2 :: Instrument PitchedNote12
vco1 = vPerOct cvRouter 7
vco2 = vPerOct cvRouter 8

-- Drum kits — named hits, each carrying its own defaults -------------------
qd1 :: DrumKit
qd1 = midiDrumKit fh2qd 14
  [ hit "bd" 36 100 50
  , hit "sn" 38 100 50
  , hit "hh" 42  80 30
  , hit "cp" 39 100 30
  ]

gateKit :: DrumKit
gateKit = gateDrumKit cvRouter
  [ gateHit "bd" 8  50
  , gateHit "sn" 9  30
  ]
```

**Calypso/Generated/Session.purs** (changes every time the music changes):

```purescript
module Calypso.Generated.Session where

import Calypso.Prelude
import Studio
import Tidal.Fugue (Voice, defaultVoice, fugueVoice, doubleSpeed, halfSpeed)

-- Subject in raw degrees; the active scale (set live via `set-scale`)
-- governs rendering.
subject :: Pattern PitchedNote12
subject = d "1 5 3 5 1 3 5 -1"

fugue1, fugue2, fugue3, fugue4 :: PitchedPart
fugue1 = on "fugue" bass1 (fugueVoice defaultVoice subject)
fugue2 = on "fugue" bass2 (fugueVoice (defaultVoice { transpose = 7 }) subject)
fugue3 = on "fugue" bass3 (fugueVoice (defaultVoice { transpose = 7, speed = doubleSpeed }) subject)
fugue4 = on "fugue" bass4 (fugueVoice (defaultVoice { transpose = -3, retrograde = true, speed = halfSpeed }) subject)

mPart :: Pattern PitchedNote12
mPart = mini "a4 b4 c5 d5 e5 d5 c5 b4"

melodyM, melodyT :: PitchedPart
melodyM = on "bass" bass1 mPart
melodyT = on "bass" bass2 (tintinnabuli aMinT above1 mPart)

qd1A, qd1B :: DrumPart
qd1A = on "drums" qd1 (drum "bd bd ~ ~ bd ~ bd ~")
qd1B = on "drums" qd1 (drum "bd ~ bd bd bd ~ ~ bd")

session :: Session
session = Session
  { midiDevices: [iac, fh2, fh2qd]
  , cvRouters:   [cvRouter]
  , instruments: [bass1, bass2, bass3, bass4, lead1, vco1]   -- erased internally
  , drumKits:    [qd1, gateKit]
  , polysignals: []
  , parts:       (erase <$> [melodyM, melodyT, fugue1, fugue2, fugue3, fugue4])
              <> (erase <$> [qd1A, qd1B])
  }
```

Every number above is now individually meaningful. No positional five-tuples.
No `anyCue` per element. No phantom-type weight on every Part annotation.

---

# Slab A — Surface renames, walker hoist, destination split

**Scope:** D1, D3, D6, D8, plus the walker-hoist architectural move (see
"Architectural principle" above). Delivered in **three landable PRs**
after the scope discovery on 2026-05-17:

- **PR 1** — surface renames (Cue→PitchedPart, Channel→Instrument-single-
  variant) + drop phantom mvoice + minimal walker tag-rename. Concrete
  to a single `MidiInstrument` form; no DrumKit, no VPerOct, no
  dispatcher-protocol change. ~1 hour. Lands D1, D3, D8 at the surface.
- **PR 1.5** — hoist `tidal_session_walker.erl` into PureScript via a
  `RegistrationEvent` ADT at the boundary. Erlang side becomes a thin
  event applier. Sets up the boundary discipline before Slab B's
  existentials and PR 2's new destination variants land. ~half-day.
- **PR 2** — destination split (Instrument-sum + DrumKit) + dispatcher
  protocol change (per-event vel/dur; new spec kinds for `v-per-oct`
  and drum hits) + per-event MIDI emit path. ~half-day to full day.
  Lands D4, D6 properly.

The file-by-file change list below describes the **end-state of Slab A**
(after PR 2). PR 1 is a strict subset: only the renames and minimal
walker tag-rename apply at that stage. PR 1.5 adds the
`RegistrationEvent` boundary and moves the walker. PR 2 fills in the
destination variants.

**Estimated total size:** medium-to-large refactor across ~10 PureScript
files and 2–3 Erlang modules, plus the SDI-managed calypso-session.json
synchronisation surface. The three-PR split keeps each landing small
and verifiable.

## File-by-file change list — Slab A

### purerl-tidal — PureScript

#### `src/Calypso/Prelude.purs`
- Rename type `Cue` → `PitchedPart` (drop phantom `mvoice :: Symbol`; add
  `mvoice :: String` as a record field).
- Rename type `AnyCue` → `AnyPart` (it becomes a sum: `AnyPitchedPart` and
  `AnyDrumPart`). For Slab A, keep `AnyPart` non-existential (no Emitable
  yet — that's Slab B); just a closed sum:
  ```purescript
  data AnyPart
    = AnyPitchedPart { mvoice :: String, destination :: Instrument PitchedNote12, body :: Pattern PitchedNote12 }
    | AnyDrumPart    { mvoice :: String, destination :: DrumKit,                    body :: Pattern DrumHitRef }
  ```
- Introduce type `DrumPart` (newtype with same-shaped record, no phantom).
- Introduce type `DrumKit` with constructors `MidiDrumKit` and `GateDrumKit`.
- Introduce types `DrumHit`, `GateHit`, `DrumHitRef = String`.
- Introduce smart constructors:
  - `midi   :: MidiDevice -> Int -> Instrument PitchedNote12`
  - `vPerOct :: CvRouter   -> Int -> Instrument PitchedNote12`
  - `midiDrumKit :: MidiDevice -> Int -> Array DrumHit -> DrumKit`
  - `gateDrumKit :: CvRouter -> Array GateHit -> DrumKit`
  - `hit     :: String -> Int -> Int -> Int -> DrumHit`
  - `gateHit :: String -> Int -> Int -> GateHit`
- Rename type `Channel` → `Instrument`, but its constructor changes: it's
  now a sum (`MidiInstrument` + `VPerOctInstrument`) with no
  default-note/vel/dur fields.
- Rename `on :: forall mv. Channel -> Pattern Pitch -> Cue mv` to a
  typeclass-resolved `on`:
  ```purescript
  class On dest body part | dest -> body part where
    on :: String -> dest -> Pattern body -> part

  instance onInstrument :: On (Instrument PitchedNote12) PitchedNote12 PitchedPart where
    on mv inst body = PitchedPart { mvoice: mv, destination: inst, body }

  instance onDrumKit :: On DrumKit DrumHitRef DrumPart where
    on mv kit body = DrumPart { mvoice: mv, destination: kit, body }
  ```
  *(The note-type parameter on `Instrument` is concrete to `PitchedNote12`
  in Slab A; Slab B parameterizes it.)*
- Rename `anyCue` → `erase` via a class:
  ```purescript
  class Erase a where
    erase :: a -> AnyPart

  instance erasePitched :: Erase PitchedPart where
    erase (PitchedPart r) = AnyPitchedPart r

  instance eraseDrum :: Erase DrumPart where
    erase (DrumPart r) = AnyDrumPart r
  ```
- Update `Session` record to the new field shape (see end-state above).
- `armCue` → `armPart` (operates on either `PitchedPart` or `DrumPart` via
  Erase, returning a `Pattern AnyPart` for Section use).
- `cueOf` → `partOf` (or remove if unused after the rename; check usage).

#### `src/Studio.purs`
- Replace every `Channel device ch note vel dur` declaration with either
  `midi device ch` (pitched) or a `midiDrumKit device ch [hit …, …]` block
  (drum kit).
- Add the cvRouter declaration if not present.

#### `src/Calypso/Generated/Session.purs`
- Update all Part annotations: `Cue "bass"` → `PitchedPart`, `Cue "drums"`
  → `DrumPart`.
- Update `on` call-sites to include the mvoice as a string argument:
  `on bass1 (...)` → `on "bass" bass1 (...)`.
- Reshape the `session` value to use the new field names and the `erase
  <$> [...]` pattern.
- Note: this file is auto-overwritten by Calypso's RAM↔disk pipeline. We
  must update both the disk file *and* `calypso-session.json` (module
  source + cells) in lockstep, or restart Calypso after the disk edit so
  it boot-loads from JSON. See "Migration safety" below.

#### `src/Tidal/Conductor.purs`
- Update to walk `AnyPart` instead of `AnyCue`. Pattern-match on the
  `AnyPitchedPart` / `AnyDrumPart` constructors at arm time and call the
  appropriate dispatcher path.

#### `src/Tidal/Pitch.purs`
- **No change in Slab A.** The rename `Pitch` → `PitchedNote12` is Slab B.
  In Slab A the type stays `Pitch` to keep the change set minimal.

#### `src/Tidal/Cell/Prelude.purs`
- Re-export the renamed surfaces. Confirm Tintinnabuli and Fugue still
  re-export cleanly. Tintinnabuli was added to the prelude in MVP-3 as
  legacy; consider moving it out into explicit-import-only as part of the
  dedicated-modules feedback (note: orthogonal to Slab A; can be done
  independently).

#### `src/Tidal/Fugue.purs`, `src/Tidal/Tintinnabuli.purs`, `src/Tidal/Scales.purs`
- No type changes in Slab A (they continue to operate on `Pattern Pitch`).
  Slab B will rename the body type to `PitchedNote12`.

### purerl-tidal — Erlang

#### `src/Tidal/WebSocket/Handler.erl`
- Confirm `reload-baseline` continues to work with the renamed BEAM
  modules. The compiled module names may shift if any PureScript module
  names change (none do in Slab A — only types within modules change).
- The BEAM-side walker that consumes the `Session` value must be updated
  to handle the new tagged-tuple shape produced by purs-backend-erl for
  the new `AnyPart` sum. Test: print one walked AnyPart and verify the
  tag-tuple shape lines up with the Erlang walker's match clauses.
- **Critical:** purs-backend-erl encodes ADT constructors as tuples even
  for nullary constructors (per `reference_purs_backend_erl_constructor_
  encoding` memory). The walker must match on the new `'AnyPitchedPart'`
  and `'AnyDrumPart'` tuple tags.

#### Other Erlang modules
- `src/Tidal/Dispatcher.erl`, voice-supervisor modules: confirm no
  references to the old `Cue` tag survive in walker clauses or registry
  shapes.

### Calypso

#### `frontend/src/Calypso/Frontend/Shell/Types.purs`
- No changes expected: the wire-verb classifier deals in verb names
  (`set-scale`, `play-piece`, etc.), not in Part types. Confirm.

#### `server/...`
- Any references to "cue" in field names that are sent over the wire need
  review. The state-sync surface (calypso-session.json) is mostly
  language-agnostic; it stores source strings, not typed cue references.
  Confirm with a `grep -r cue server/` pass before declaring done.

### SDI / supervision

- `agent-teams/sdi/`: no direct changes expected; SDI proxies to
  Calypso's :3060 and doesn't care about Part types.
- DeepStar: no changes.

## Migration safety — the state-sync footguns

This is the surface that hit us hardest on 2026-05-17. The slab touches
both the on-disk `Session.purs` and types referenced inside `calypso-
session.json` cells. Three failure modes to defend against:

1. **Calypso RAM overwrites the disk edit on next ▶ run.** The browser's
   CodeMirror buffer is posted back to disk; if we edit
   `Session.purs` directly while Calypso is up, the next ▶ run reverts
   it. **Mitigation:** stop Calypso (via SDI control port or DeepStar) for
   the duration of the Slab A merge; restart it pointing at the new
   `calypso-session.json` that already contains the new module source.

2. **`calypso-session.json` `module.source` ≠ `cells[].source`.** The JSON
   has separate fields for module source and per-cell source; updating
   one without the other leaves the cell projection broken. **Mitigation:**
   write a one-shot sync script that re-projects cells from
   `module.source` after the rename, and apply it before restarting
   Calypso. Or simply blow away the cells array and let Calypso re-derive
   from module.source on boot (confirm boot path actually does this — if
   not, this is the moment to make it).

3. **BEAM cache.** The conductor and dispatcher hold registry data in
   ETS / gen_server state. `reload-baseline` purges and reloads
   `calypso_generated_session@ps` and `studio@ps`. Confirm both are
   purged; new modules introduced in Slab A (none expected) would need
   adding to the reload list.

The cleanest sequence:
1. Branch.
2. Edit code on disk only; Calypso *not* running.
3. Update `calypso-session.json` to match the new module shape.
4. Start Calypso (via SDI lazy-spawn); confirm boot from JSON works.
5. End-to-end test in Live (see Validation below).

### Empirical evidence from PR 1 (2026-05-17)

PR 1's migration ran into footguns #1 and #2 above as live phenomena —
worth recording the specific symptoms as evidence of why the
`project_calypso_state_sync_review_pending` audit is non-negotiable
before the next big rename:

- **Footgun: WS handler classify clause not in lockstep with walker.**
  The Erlang walker was renamed to return `instruments` field; the
  WS handler's `case` clause still matched `channels`. Result: BEAM
  crash on every WS connection. Headline error: a `{case_clause,
  …}` exception with no PureScript trace. This is the canonical
  example of why the boundary should be **type-discrimination in
  PureScript, OTP/IO in Erlang** (see top-of-doc architectural
  principle) — *a typo-pair across the boundary is normal-mode
  failure today, structurally impossible after PR 1.5.*

- **Footgun: cells[] preserved old-form sources through the
  module.source sync.** Syncing `module.source` to the new disk
  Session.purs left `cells[].source` untouched. Each Part cell's
  source kept its pre-rename form (`on bass1 (...)` — no mvoice
  string). On arm, `syncCellIntoTypefulSource` rewrote a disk line
  with the stale cell source, breaking the file. Headline error:
  "purs compile failed".

- **Footgun: RAM lags JSON.** After patching `cells[]` in JSON, the
  running Calypso server kept serving its in-RAM (still stale)
  cells from boot. Editing the JSON file changed only the boot
  snapshot. Mitigation in PR 1: kill Calypso processes via SDI
  state inspection (`/state` shows pids), let SDI lazy-respawn on
  next browser request, which then boots from the corrected JSON.
  See `reference_calypso_api_propose_dont_write` for the principled
  agent-side path (POST /proposals or PATCH /session/cells/:id).

These three are the empirical case for treating the state-sync audit
as a hard prerequisite for the *next* invasive refactor, not just a
nice-to-have. PR 1.5's walker hoist removes footgun #1 by
construction; the cells/module/RAM/JSON surfaces remain to be
designed-properly during the audit.

## Validation — Slab A

1. **Build:** `spago build` succeeds without warnings.
2. **Type-check key surfaces:** confirm `on "fugue" bass1 (...)` and
   `on "drums" qd1 (drum "bd sn")` both type-check.
3. **Erase pattern works:** confirm `(erase <$> [fugue1, fugue2])
   <> (erase <$> [qd1A])` produces a homogeneous `Array AnyPart`.
4. **Start Calypso → arm a cell → hear MIDI in Live.** This is the
   golden-path test. Arm `fugue1`, `fugue2`, `qd1A`. Confirm
   simultaneous playback.
5. **Live scale change still works:** fire `set-scale a-harmonic-minor`,
   confirm fugue voices instantly modulate.
6. **Reload-baseline still works:** edit Session.purs (add a new Part),
   re-run baseline, arm the new Part — should work without restarting
   purerl-tidal.
7. **No regression in tintinnabuli / fugue:** all MVP-3 and MVP-4 demos
   continue to produce identical MIDI output.

## Risks — Slab A

- **The BEAM-side walker is the highest-risk surface.** It consumes
  PureScript-generated tagged tuples; renames at the PureScript type
  level produce different tag atoms on the Erlang side. Verify with a
  print-before-match in the walker.
- **The `on` typeclass with functional dependencies may produce confusing
  inference errors** when a user passes the wrong kind of pattern (e.g.
  a drum pattern to a pitched Instrument). Test the error messages
  before declaring done; if they're cryptic, consider concrete
  type-class instances with overlapping-instance-style helpers, or split
  `on` into `onPitched` + `onDrum`.
- **The Calypso state-sync footguns** (above) will bite if not handled
  carefully. The compaction-survival audit (`project_calypso_state_sync_
  review_pending` memory) is queued *after* this slab, but Slab A's
  migration will exercise the same surfaces. Treat the migration as a
  small exercise of the upcoming audit.

---

## PR 1.5: Hoist the session walker into PureScript

**Status:** Between PR 1 (renames) and PR 2 (destination split).
**Embodies:** The PureScript/Erlang boundary principle declared at the
top of this doc.
**Estimated size:** half-day. Mechanically straightforward; the
architecture move is doing real work but each individual code change
is small.

### Why here, why now

After PR 1, the codebase has the new PureScript surface but the Erlang
walker still classifies via `element(1, V) =:= channel` and similar
ad-hoc shape-sniffing. Two things make this exactly the right moment
to fix it:

- **PR 2** is about to add new variants on the PureScript side
  (`MidiInstrument` + `VPerOctInstrument`, `MidiDrumKit` +
  `GateDrumKit`). Doing PR 2 without the walker hoist means adding
  four new Erlang classify clauses — busy-work that gets deleted
  shortly after.
- **Slab B** introduces existential `AnyPart` with `forall note.
  Emitable note =>`. purs-backend-erl's encoding of existentials is
  not something we want the Erlang side reaching into via `element/2`.
  With the walker in PureScript, the existential is unwrapped on the
  PureScript side and Erlang sees only flat `RegistrationEvent`
  values.

### The boundary ADT

```purescript
module Tidal.SessionWalker
  ( RegistrationEvent(..)
  , walkBaseline
  ) where

data RegistrationEvent
  -- routing fabrics
  = RegisterMidiDevice
      { alias :: String, name :: String, latencyMs :: Int }
  | RegisterCvRouter
      { alias :: String, host :: String, port :: Int }
  -- destinations (added incrementally — only MidiInstrument exists in PR 1)
  | RegisterMidiInstrument
      { alias :: String, deviceAlias :: String, channel :: Int
      -- PR 1 carries the old defaults here; PR 2 drops them in favour of
      -- per-event vel/dur on the emit path.
      , defNote :: Int, defVel :: Int, defDurMs :: Int }
  | RegisterMidiDrumKit
      { alias :: String, deviceAlias :: String, channel :: Int
      , hits :: Array { name :: String, note :: Int, vel :: Int, durMs :: Int } }
  | RegisterVPerOct
      { alias :: String, routerAlias :: String, bus :: Int }
  | RegisterGateDrumKit
      { alias :: String, routerAlias :: String
      , hits :: Array { name :: String, bus :: Int, durMs :: Int } }

walkBaseline :: Effect (Array RegistrationEvent)
walkBaseline = do
  -- Read every export of Studio + Calypso.Generated.Session, classify
  -- each value at its PureScript type, and produce a flat list of
  -- RegistrationEvent values.  This is the *only* place that knows
  -- the shape of the session's typed declarations.
  ...
```

The PR 1.5 cut introduces only the constructors that exist after PR 1
— `RegisterMidiDevice` and `RegisterMidiInstrument`. PR 2 adds the
DrumKit / VPerOct / CvRouter constructors as one-file PureScript
changes; the Erlang side gets one new clause per constructor.

### Erlang side after the hoist

```erlang
%% tidal_session_walker.erl after PR 1.5 — thin shell.

walk_baseline() ->
    case erlang:module_loaded('tidal_session_walker@ps') of
        false ->
            {error, walker_module_not_loaded};
        true ->
            EventsThunk = 'tidal_session_walker@ps':walkBaseline(),
            Events = EventsThunk(),    %% Effect-wrapped: thunk to invoke
            lists:foreach(fun apply_event/1, Events),
            {ok, length(Events)}
    end.

apply_event({registerMidiDevice, #{alias := A, name := N, latencyMs := L}}) ->
    tidal_dispatcher:register_midi_device(A, N, L);
apply_event({registerMidiInstrument,
             #{alias := A, deviceAlias := D, channel := C,
               defNote := N, defVel := V, defDurMs := Dur}}) ->
    Spec = iolist_to_binary([
        "midi-note ", D, " ",
        integer_to_binary(C), " ",
        integer_to_binary(N), " ",
        integer_to_binary(V), " ",
        integer_to_binary(Dur)
    ]),
    tidal_dispatcher:set_binding_from_spec(A, Spec).
%% PR 2 adds one clause per new constructor.
```

The Erlang clauses match on **registration events** — small, stable,
intentional — never on **session/instrument/part ADTs**.

### File-by-file change list — PR 1.5

- **NEW** `src/Tidal/SessionWalker.purs` — defines
  `RegistrationEvent` ADT and `walkBaseline :: Effect (Array
  RegistrationEvent)`. The classify logic moves here from
  `tidal_session_walker.erl`.
- **REWRITE** `src/tidal_session_walker.erl` — becomes the thin shell
  shown above. The current ~150-line classify/register code
  collapses to ~30 lines of event-apply clauses.
- The `Tidal.SessionWalker` module needs to enumerate Studio +
  Session module exports. Options:
  - Call into BEAM via FFI: a thin `module_exports` FFI that returns
    `Array Foreign` of nullary-export values plus their names. The
    PureScript side then classifies via type-class dispatch.
  - Have Studio + Session export a single `studio :: Studio` /
    `session :: Session` value of a typed record. The walker just
    deconstructs the record fields and emits events for each — no
    enumerate-exports needed. **This is the cleaner approach** and
    is consistent with the end-state user surface already in this
    doc (a single `session :: Session` declaration).
- The Erlang walker still owns: calling the PureScript walker on
  hot-reload, applying events to the dispatcher, exposing the
  channel-alias ETS for the conductor.

### Validation — PR 1.5

1. Build green; cell modules continue to compile.
2. `reload-baseline` still works end-to-end: Live receives MIDI when
   firing existing cells (e.g. the fugue1-4 demo).
3. The new walker reports the same set of registrations as the old
   walker did. Add a debug log path that prints each
   `RegistrationEvent` as it's applied so we can eyeball the list
   matches the old "bass1, bass2, bass3, bass4, qd1, qd2"
   enumeration.
4. Hot-edit Studio.purs to add a channel → ▶ run → confirm the new
   binding is registered. (Same test PR 1 did, but exercising the
   new path.)

### Risks — PR 1.5

- **The PureScript walker needs access to BEAM module exports.** If
  we take the `module_exports` FFI route, this is non-trivial:
  PureScript needs a generic "enumerate exports of an Erlang module
  and call each nullary function." If we take the `session ::
  Session` declared-value route, we avoid this entirely. Strongly
  prefer the declared-value route.
- **Effect-wrapping the walker.** PureScript-side walker is `Effect
  (Array RegistrationEvent)` because reading the loaded Session is
  effectful. The Erlang call site invokes the Effect-thunk; trivial
  but worth checking purs-backend-erl's representation.

---

# Slab B — Polymorphic substrate + Emitable typeclass

**Scope:** D4, D7. Parameterize `Instrument` and `PitchedPart` by note
type. Introduce `Emitable note` typeclass. Existentialize `AnyPart` over
note type. **Touches the conductor's emit path on both sides.**

**Estimated size:** larger PR. The polymorphism propagates through every
function that today operates on `Pattern Pitch`. The wire format between
PureScript and Erlang may need adjustment for the existentialised
`AnyPart`.

**Prerequisite:** Slab A complete and stable.

## File-by-file change list — Slab B

### purerl-tidal — PureScript

#### `src/Tidal/Pitch.purs`
- Rename type `Pitch` → `PitchedNote12`.
- Rename constructors: keep `Degree`, `Chromatic` (drop `Sample` — that
  was the old way to encode drum names; D6 in Slab A has already moved
  drum hits to `DrumHitRef` in `DrumPart`).
- Add a class instance for `Emitable PitchedNote12` (see below).

#### `src/Calypso/Prelude.purs`
- Parameterize `Instrument` by note type:
  ```purescript
  data Instrument note
    = MidiInstrument    MidiDevice Int
    | VPerOctInstrument CvRouter Int
  ```
- Parameterize `PitchedPart`:
  ```purescript
  newtype PitchedPart note = PitchedPart
    { mvoice :: String, destination :: Instrument note, body :: Pattern note }
  ```
- Existentialize `AnyPart` over note type with the `Emitable note`
  constraint as the certificate:
  ```purescript
  data AnyPart
    = forall note. Emitable note =>
        AnyPitchedPart { mvoice :: String, destination :: Instrument note, body :: Pattern note }
    | AnyDrumPart { mvoice :: String, destination :: DrumKit, body :: Pattern DrumHitRef }
  ```
- Update `Erase` instance for `PitchedPart note` to existentialize the
  note type at the boundary.

#### `src/Tidal/Emit.purs` (new file)
- Define the typeclass(es). Factor as multiple smaller classes per
  output target rather than one mega-class:
  ```purescript
  class Emitable note where
    -- The class is a "marker" that the note type can be emitted to
    -- at least one fabric; specific capabilities are separate classes.
    noteName :: note -> String  -- for logging / debugging

  class ToMidiNote note where
    toMidiNote :: note -> Maybe { note :: Int, vel :: Int }

  class ToVPerOctVolts note where
    toVPerOctVolts :: note -> Maybe Number
  ```
- `PitchedNote12` implements all three.
- Future `MaqamNote` would implement `Emitable`, `ToVPerOctVolts`, and
  `ToMtsNote` (a future class) but not `ToMidiNote` (plain 12-TET MIDI
  can't carry microtones).

#### `src/Tidal/Pattern/Types.purs`, `src/Tidal/Pattern/Core.purs`
- No changes — these are already polymorphic in event type.

#### `src/Tidal/Scales.purs`
- Rename `Pattern Pitch` → `Pattern PitchedNote12` in signatures.
- `inKey`, `transposeDiatonic`, `transposeChromatic` etc. stay specific
  to `PitchedNote12` (they're scale-degree operations; they only make
  sense for that note type). Future `MaqamScale` operations would live
  in their own module operating on `MaqamNote`.

#### `src/Tidal/Tintinnabuli.purs`, `src/Tidal/Fugue.purs`
- `Pattern Pitch` → `Pattern PitchedNote12` in signatures.

#### `src/Tidal/Conductor.purs`
- Emit path branches on `Instrument` variant *and* uses the `Emitable`
  class instance to render the note value. Pseudo-code:
  ```purescript
  emitOnInstrument inst note = case inst of
    MidiInstrument dev ch ->
      case toMidiNote note of
        Just { note: n, vel } -> sendMidi dev ch n vel
        Nothing -> log "note type can't emit MIDI"
    VPerOctInstrument router bus ->
      case toVPerOctVolts note of
        Just v -> sendOsc router ("/cv/voct/" <> show bus) v
        Nothing -> log "note type can't emit V/oct"
  ```

### purerl-tidal — Erlang

- The BEAM walker may need a wire-format adjustment for the existentialised
  `AnyPart`. The `forall note. Emitable note =>` constraint compiles to
  some runtime representation (likely a tuple with type-class evidence as
  an extra field, but purs-backend-erl's encoding here needs to be
  verified). **Sub-step:** print one walked `AnyPart` value before the
  walker matches and confirm the shape.
- If the encoding turns out to be opaque (which is the typical PureScript
  story for existentials), we may need to thread the emit operation
  through a different boundary — e.g., the PureScript side pre-renders
  each Pattern's events into a `Pattern EmittedEvent` (a closed Erlang-
  friendly ADT) before the Erlang walker sees it. **Open question — see
  below.**

### Calypso

- No frontend changes expected.

## Validation — Slab B

1. **Slab A regression-pass:** everything that worked after Slab A still
   works.
2. **Polymorphic type-check:** confirm `PitchedPart PitchedNote12` is the
   inferred type of every existing Part. Confirm `Pattern PitchedNote12`
   is the inferred body type.
3. **Emit class dispatch:** add a unit test or scripted demo that arms
   a Pattern of degrees and a Pattern of chromatics on both a MIDI and
   a V/oct Instrument, verifying correct emit on both fabrics.
4. **Future-proof check (no implementation):** confirm a *new* Note type
   would only require new ADT + Instrument variant + Emitable instance
   — none of the existing combinators (fast, slow, rev, transposeDiatonic
   when scoped to PitchedNote12, fugueVoice, tintinnabuli) need any
   change. Document the recipe in the polyvoice cookbook.

## Risks — Slab B

- **Existential types and purs-backend-erl interaction.** The `forall
  note. Emitable note =>` boundary may produce a wire format that the
  Erlang walker can't easily decode. If so, the fallback is to render
  events to a closed ADT on the PureScript side before crossing the wire.
  This shifts the emit-class dispatch entirely to PureScript, which is
  fine but worth deciding consciously.
- **Class-instance resolution cost.** Typeclass dispatch is normally
  zero-cost in PureScript, but with existentials carrying class
  dictionaries, the dictionary is stored at runtime. Per-event emit cost
  in the hot path needs benchmarking (the live-coding rig is latency-
  sensitive — see `feedback_calibration_stability_over_precision`).
- **Class explosion.** `ToMidiNote`, `ToVPerOctVolts`, `ToMtsNote`,
  `ToMpeEvent` is already four classes for four destinations. Resist
  the urge to merge into one ToEverything class; resist the urge to
  proliferate. Each class earns a destination + a note-type instance.

---

# Slab C — Polysignals, parser cluster, voice registry

**Scope:** D5 + naming the parser cluster (`mini`/`d`/`n`/`drum`) + bringing
back compile-time mvoice safety via a voice registry.

**Status:** Outlined here; not yet detailed. Depends on the port-claims
work in `fh2-config` converging (see `project_port_claims_design` memory).

## Polysignals as alternate notation (Andrew's framing, 2026-05-17)

The shape we discovered during the slate review: **polysignals are not
Instruments and not Parts; they're a different *vocabulary* for expressing
musical/control time-structure.** A polysignal config says "a saw LFO at
0.5 Hz on FH-2 bank C output 3" — that's a *declarative* musical
specification, parallel to the Tidal pattern's *event-stream* specification
of "at t=0 send note, at t=0.25 send note, …".

This reframe suggests the right architectural slot:

- Polysignals are first-class members of the Session alongside Parts.
- Their on-disk representation is a `PolySignal` ADT (or sum of family
  ADTs: `PolyLfo`, `PolyClock`, `PolyEnv`, `PolyEuclid`, `PolyRand`).
- Their wire-out path is fh2-config's daemon-write protocol, not the
  MIDI/OSC emit path that Parts use.
- They issue port claims at install time; the port-claims layer
  (designed in fh2-config) refuses overlaps.
- Calypso could surface them as a separate cell-kind in the UI, with the
  polysignal block syntax (continuation marker `<>`, per memory
  `reference_polysignal_continuation_marker`) as their first-class
  notation.

This makes "Tidal mini-notation" and "polysignal block" two siblings in
a family of musical-specification notations the live-coding system
understands, not one privileged form and one anomalous appendage. The
polyfacetic-REPL framing from earlier (`project_polyfacetic_repl_vision`)
finally has a concrete second vocabulary alongside Tidal patterns.

When we pick Slab C up: think of the polysignal type and its Session-slot
as the *second proper notation*, with Tidal patterns as the first. That
framing should guide naming and API shape.

## Parser cluster naming

After D6, the mini-notation parser splits cleanly by destination:

- `mini :: String -> Pattern PitchedNote12` — chromatic literals (`c4`,
  `e5`, `f#4`), rests, modifiers.
- `d :: String -> Pattern PitchedNote12` — scale degrees (`1`, `-3`,
  `7'`, sequences).
- `n :: String -> Pattern PitchedNote12` — note-number sequences (raw
  semitones).
- `drum :: String -> Pattern DrumHitRef` — drum names (`bd`, `sn`,
  `hh`, `~`).

To-decide: whether the drum parser should be `drum`, `hits`, or
something else; whether `mini` and `d` should share more or be more
clearly differentiated.

## Voice registry

Restore compile-time mvoice safety after D8. Sketch:

```purescript
-- in Studio (or a Voices module)
data VoiceName (s :: Symbol) = VoiceName

bassVoice  :: VoiceName "bass"
bassVoice  = VoiceName

fugueVoice :: VoiceName "fugue"
fugueVoice = VoiceName

drumsVoice :: VoiceName "drums"
drumsVoice = VoiceName

-- in `on`, instead of String:
on :: forall s dest body part. IsSymbol s => On dest body part =>
  VoiceName s -> dest -> Pattern body -> part
on (VoiceName :: VoiceName s) dest body =
  mkPart (reflectSymbol (Proxy :: Proxy s)) dest body
```

Now `on "fuge" bass1 …` (typo) doesn't typecheck; `on fugeVoice bass1 …`
(typo'd binding) is a name resolution error. Best of both worlds.

The voice registry could be hand-maintained in Studio or auto-generated
from a `voices.txt` config the cell-prelude reads at boot. Tactical
choice for when we get there.

---

# Sequencing summary

1. **PR 1 (today)** — Slab A surface renames + drop phantom mvoice +
   minimal walker tag-rename. ~1 hr. Pre-flight: branch
   `dsl-naming-slab-a`; confirm Calypso isn't running so the
   RAM-overwrites-disk footgun is parked; edit; build; run end-to-end
   smoke test in Live (existing fugue + tintinnabuli demos sound
   identical).
2. **PR 1.5 (next session)** — Hoist `tidal_session_walker.erl` into
   PureScript via a `RegistrationEvent` ADT at the boundary. Erlang
   side becomes a thin event applier. **Pays for itself before PR 2
   even starts** because PR 2's new variants then land as
   one-clause-per-variant PureScript additions, with one matching
   Erlang clause per event constructor.
3. **PR 2 (Slab A-residual)** — Destination split (Instrument-sum +
   DrumKit) + dispatcher protocol change (per-event vel/dur; new spec
   kinds for `v-per-oct` and drum hits) + per-event MIDI emit path.
   ~half to full day. Lands D4, D6 properly.
4. **Slab B** — Parameterize note type + Emitable typeclass.
   Existential-AnyPart now crosses a boundary that doesn't peek into
   it (thanks to PR 1.5), so the wire-format risk disappears.
5. **Slab C** — when fh2-config's port-claims design lands.
   Polysignals as alternate notation + parser cluster + voice
   registry.

The PureScript/Erlang boundary principle established at the top of
this doc is the load-bearing architectural move; PR 1.5 is its first
expression, but it should guide every subsequent decision about
"where does this piece of logic live?"

# Open questions parked for the implementation session

- Should `on` be one typeclass-resolved function or two named functions
  (`onPitched`, `onDrum`)? Trade-off: inference clarity vs. fewer names.
  *(Deferred until PR 2 introduces `DrumPart` — irrelevant in PR 1
  which has only one Part kind.)*
- The Session record's `instruments :: Array (Instrument note)` is
  heterogeneous in note type once Slab B lands. Existentialize via
  `SomeInstrument`? Or split into per-note-type arrays? Lean toward
  `SomeInstrument` for symmetry with `AnyPart`.
- Do we keep `mini` as the verbose-pitched parser and add `n` as the
  short-form degree parser, or unify? The naming-cluster question is
  worth its own short design discussion when we pick Slab C up.
- The PR 1.5 walker's mechanism for enumerating Session contents:
  declared-value route (`session :: Session` deconstructed by field)
  vs. module-exports FFI route. Strongly leaning toward declared-value.
- The Tintinnabuli-out-of-prelude move (dedicated-modules feedback) is
  orthogonal to all PRs; pick it up opportunistically.

# Companions / references

- `per-voice-refactor-plan.md` — the per-voice supervisor refactor; this
  plan inherits its multi-PR discipline.
- `polyvoice-cookbook.md` — recipes for new pattern-construction; will
  need a chapter on adding a new note type after Slab B.
- `feedback_dedicated_modules_over_prelude` — the move-Tintinnabuli-out
  feedback that informs Slab A's Cell.Prelude cleanup.
- `project_purerl_tidal_ide_framing` — the IDE-for-music framing that
  makes coherent state and typed surfaces matter more.
- `project_calypso_state_sync_review_pending` — the architecture review
  queued for after the music-library work; Slab A's migration is a
  small exercise of those surfaces.
- `project_port_claims_design` — port-claims work in fh2-config that
  Slab C will integrate with.
- `project_polyfacetic_repl_vision` — the multi-vocabulary framing that
  the polysignals-as-notation reframe lands inside.
