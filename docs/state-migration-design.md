# State migration design — PR1.4d through PR1.5+

A design pass undertaken before resuming implementation on the
`per-voice-supervisors` branch. Captured 2026-05-08 from a session
that audited `MIDIScheduler.purs` end-to-end and reshaped the design
question accordingly.

This is the operational sequel to `per-voice-refactor-plan.md`,
narrowed to the migration of state and dispatch responsibilities out
of MIDIScheduler. The plan doc named directions ("`tidal_state`
gen_server held by the supervisor"); this doc commits to specific
shapes with reasoning, after reading the code rather than guessing
at it.

## 0. Scope

In: the migration of every responsibility currently held by
`Tidal.MIDIScheduler` into the per-voice supervision tree introduced
by PR1.1–1.4c. Out: hot reload (PR2), cell-as-module (PR3), eDSL
work (Path B from `live-coding-feasibility.md`).

The end state is that MIDIScheduler.purs is deleted. Every code path
currently in it has a migration target named below.

## 1. Audit findings

These shape the design. Numbers reference `MIDIScheduler.purs` line
numbers as of the start of this work.

### 1.1 State map

`MIDISchedulerState` (line 257-302) holds:

| Field | Kind | Read sites at dispatch time |
|-------|------|-----------------------------|
| `config`             | static | every event (look-ahead, cycle math, gate config) |
| `tracks`             | runtime | tick walks all tracks |
| `continuousTracks`   | runtime | tick samples all continuous |
| `bridgeClient`       | socket | every MIDI emit |
| `oscClient`          | socket | every gate/CV/ESX emit |
| `bindings`           | registry | one site (compositional `#`, line 657) |
| `continuousBindings` | registry | only at install (`PlayByNameExpr`) |
| `sinkTypes`          | registry | only at install (`PlayByName*` type-check) |
| `slots`              | env | **NO consumer found in the dispatch path** |
| `midiDevices`        | env | every MIDI emit (most-read shared map) |
| `fh2VoiceChannels`   | env | every `Fh2TriggerTrack` event, every `Fh2Shape` |

### 1.2 Five `ParsedTrack` variants

```
GateTrack         — sample-name pattern → gate (+ optional CV pre-set)
CVTrack           — numeric pattern → sustained /cv updates
ESXTrack          — numeric pattern → ESX-8CV slot
BoundTrack        — pattern + name + binding + params (#-joins)
Fh2TriggerTrack   — pattern + voice-id (channel resolved at fire)
```

`GateTrack` / `CVTrack` / `ESXTrack` are pre-Binding-era — they hard-
code their destination. The Binding-era replacement is
`BoundTrack` + a registered binding. Migration target for the three
legacy variants: deprecate at the verb level (`UpdateGateTrack` /
`UpdateCVTrack` / `UpdateESXTrack`) by mapping them to BoundTracks
with synthesized bindings under reserved names (`__gate_<ch>`,
`__cv_<bus>`, `__esx_<slot>`). User-visible behaviour unchanged.

### 1.3 The two kinds of `#`

Both live inside `BoundTrack` dispatch (line 561-675), filled at
`PlayByName` time (line 886-891). They look identical at the parse
layer (a `Map String (Pattern String)` of param name → pattern) but
do different things at fire time:

**(a) Slot overrides** — line 604-614. For each PrimAction, if a
param matches a known slot (currently only `vel` for MidiNote),
sample the param pattern at the event's cycle and override the
field on this PrimAction. Self-contained; no registry read.

**(b) Compositional `#`** — line 640-675. For each param NOT consumed
as a slot override, look the name up in `state.bindings`. If it
matches another registered binding, fire that binding's `MidiCC`
actions with the joined value. **Only `MidiCC` is composed today**
(line 675: `_ -> pure unit  -- only MidiCC composition for now`).
This is the cross-binding fanout.

Both kinds need: voice samples each param pattern at the event's
cycle position, attaches to the event payload. Dispatcher decides
which kind each is (slot override → consumed by named-action match;
compositional → matches another binding name).

### 1.4 Continuous voices

Sampled once per tick (currently 50ms = 20Hz) using
`samplePatternAt :: Rational -> Pattern Number -> Maybe Number`
(line 1167-1180). NOT `queryArc` — different query type entirely.

Two destinations: `ContMidiCC { device, channel, cc }` and
`ContCV { bus, transforms }`. Dispatched via `dispatchContValue`
(line 1270-1292) with no latency adjustment, no event-time book-
keeping.

Registered via `parseContBinding` (line 1241-1251) from
`bind <name> midi-cc-cont …` / `bind <name> cv-cont …`. The track
is installed when `PlayByNameExpr` evaluates to a `VNumPattern` and
the name is in `continuousBindings`.

### 1.5 FH-2 — three verbs, two dispatch shapes

- `Fh2Envelope` (line 1056-1072) — registry write to
  `fh2VoiceChannels`; auto-registers `fh2` MIDI device alias.
- `UpdateFh2TriggerTrack` (line 1074-1087) — installs an
  `Fh2TriggerTrack`. Dispatch reads `fh2VoiceChannels` to resolve
  channel at fire time.
- `Fh2Shape` (line 1089-1118) — fires four CCs immediately (live
  ADSR), no track installed.

`Fh2TriggerTrack` is structurally a MIDI voice with one extra
indirection: voice-id → channel via shared map. `Fh2Shape` is a
fire-and-forget no-track verb.

### 1.6 Dormant / unclear

`state.slots` (line 293) is registered via `SetSlot` (line 1033-
1038) and serialized for the `state` verb (line 1519-1522), but I
found no consumer in the dispatch path. Either: (a) dormant feature,
(b) read site I missed, (c) future placeholder. **Flag for user to
resolve before deletion or migration.**

### 1.7 State publication

`publishState` (line 1427-1430) runs every tick, serializes the full
state to JSON, writes to `StateBus` ETS. Calypso reads from ETS.
~20 writes/sec; ETS insert is sub-microsecond.

After migration, no single process holds the full state. Snapshot
must be assembled from voice_sup + dispatcher (and clock for tempo).
Two viable models: (i) periodic publisher gen_server walks both;
(ii) each owner publishes its slice, reader stitches at read time.

## 2. Design decisions

### 2.1 Where does each piece of state live

**Decision: dispatcher-cohesive, with one exception.**

Hot-path argument is decisive. State read by every event must be on
the same process as the dispatcher; cross-process `gen_server:call`
on a hot path is unacceptable. The fields read at every-event-rate
(`midiDevices`, the local copy of `bindings` for the voice in
question, `fh2VoiceChannels`) all live on the dispatcher. The
plan doc's hand-wave at "preferred shape is a separate `tidal_state`
gen_server" is reconsidered: a separate process buys SRP-cleanness
at hot-path cost.

The exception is the **clock** — owns BPM and the tick. It exists
already; no field migrates *from* the dispatcher *to* the clock.

Specifically:

| Field | Lives on | Reason |
|-------|----------|--------|
| `config` | clock + dispatcher | clock owns bpm/tickMs; dispatcher owns gateConfig |
| `bindings` | dispatcher | hot-path read for compositional `#`; install-time read for new voices |
| `continuousBindings` | dispatcher | install-time read; close to discrete bindings |
| `sinkTypes` | dispatcher | install-time read; derived from `bindings` so co-located |
| `midiDevices` | dispatcher | every MIDI emit reads it |
| `fh2VoiceChannels` | dispatcher | every FH-2 trigger reads it |
| `slots` | TBD | dormant; flag for user before designing |
| voice runtime state | per-voice gen_server | the whole point of the refactor |

`publishState` (snapshot) is a separate concern handled in §2.6.

### 2.2 The `bind` verb routing

The `bind` verb mutates `bindings` (and `sinkTypes`). It does NOT
install a voice on its own — it just registers a name. A subsequent
`<name> <pat>` (PlayByName) installs the voice.

Today (post-PR1.4c): `bind` goes only to MIDIScheduler.
Post-migration (after PR1.4e): `bind` goes only to dispatcher.

**Transition state needs dual-write.** Between PR1.4d-i (this
commit) and PR1.4e (cleanup), MIDIScheduler still hosts BoundTracks
in its `tracks` array, and those BoundTracks read `state.bindings`
at dispatch time for compositional `#` joins (MIDIScheduler.purs
line 657). If PR1.4d-i sent `bind` only to the dispatcher, user-
level bindings would disappear from MIDIScheduler's registry —
only the default registry would remain — and compositional `#`
joins for user-defined bindings would silently fail.

The dual-write is bounded: the WS handler is the only writer of
the registry, so divergence requires someone adding a new write
path (which we can avoid by code review). Dual-write is removed in
PR1.4e once MIDIScheduler stops hosting BoundTracks.

The earlier "no dual-write needed" framing was glib about the
transition. The post-migration *end state* doesn't need dual-write,
but the migration *transition* does.

### 2.3 The `#` joins implementation

**Voice computes enriched events. Dispatcher routes both kinds.**

Voice state extends to hold `params :: Map String (Pattern String)`,
populated from the WS handler at install. On each `compute_until`,
voice queries pattern AND samples each param pattern at each event's
cycle position. Event payload becomes:

```purescript
{ token :: String
, wallTimeUs :: Number
, params :: Map String String  -- pre-sampled per-event values
}
```

Dispatcher receives this, looks up binding by voice name. For each
PrimAction in the binding:
- Walk PrimAction normally for the token.
- For each param in `event.params`:
  - If param matches a known slot for this PrimAction (e.g. `vel`
    for MidiNote), apply override.
  - Otherwise: look the param name up in `bindings`. If it matches
    another binding, fanout-fire that binding's MidiCC actions with
    the param's value.

This keeps the slot/composition decision on the dispatcher (where
the registry lives). The voice doesn't need to know about other
voices.

### 2.4 Continuous voices — same gen_server, polymorphic state

**Per the link-spike-as-universal-clock simplification.**

Voice state is a sum:

```purescript
data VoiceKind
  = Discrete
      { pattern :: Maybe (Pattern String)
      , binding :: Binding
      , params :: Map String (Pattern String)
      , phase :: ...
      , lastEmittedUntil :: Number
      , muted :: Boolean
      }
  | Continuous
      { pattern :: Maybe (Pattern Number)
      , dest :: ContDest
      , muted :: Boolean
      }
```

Both subscribe to the same `Window` broadcast. `computeUntil`
dispatches:

- `Discrete`: queries pattern over `[fromCycle, toCycle)`, produces
  scheduled events (current behaviour).
- `Continuous`: samples pattern at `currentCycle`, produces one
  immediate event.

Both push events to dispatcher. Dispatcher routes:
- Discrete event → dispatch via voice's binding (looked up by name).
- Continuous event → dispatch via voice's `ContDest` (looked up by
  name in `continuousBindings`).

Key implication: events from continuous voices need a flag (or a
separate cast pattern) so the dispatcher knows to consult
`continuousBindings`, not `bindings`. Two coherent options:

**(i)** Two cast patterns: `{event, ...}` for discrete, `{cont_event, ...}`
  for continuous. Dispatcher branches on the message type.
**(ii)** Voice carries kind in its name registration (`add_voice`
  caller sets a `kind` flag); dispatcher's `set_binding` /
  `set_continuous_binding` respect this and the unified
  `dispatch_event` reads the correct map.

Pick (i). Cleaner: the message shape encodes the dispatch path,
no per-name kind lookup needed. Dispatcher's `bindings` and
`continuousBindings` maps are independently read.

### 2.5 FH-2 voices — new PrimAction variant

**Decision: extend `PrimAction` with a `Fh2Trigger` variant.**

Today's `Fh2TriggerTrack` is a `ParsedTrack` variant (line 233) with
its own dispatch path. Migrating it as-is would mean voices need to
know they're FH-2 voices, which complicates the polymorphic voice
state. Instead, treat FH-2 trigger as a kind of MIDI emission: a
PrimAction that captures `voice :: Int` and resolves
`channel :: Int` at dispatch time.

```purescript
data PrimAction
  = ...
  | Fh2Trigger { voice :: Int, defaultNote :: Int }
  -- channel is resolved by the dispatcher via fh2VoiceChannels;
  -- device alias is hardcoded "fh2"; durationMs is fixed at 200ms
  -- (matches current behaviour).
```

The WS handler's `fh2-trigger <voice> <pattern>` verb installs a
voice with binding `[Fh2Trigger { voice, defaultNote: 60 }]`. The
voice is then a regular discrete voice; dispatcher's `Fh2Trigger`
handler does the channel resolve.

`Fh2Envelope` and `Fh2Shape` stay as direct dispatcher casts (no
voice involved): `dispatcher:fh2_envelope(voice, output, channel)`
and `dispatcher:fh2_shape(voice, a, d, s, r)`.

This unifies the voice model — every voice is either Discrete with
some PrimActions, or Continuous with a ContDest. FH-2 is a Discrete
voice with a specific PrimAction variant.

### 2.6 State publication

**Decision: periodic publisher gen_server.**

A dedicated `tidal_state_pub` gen_server ticks (e.g. every 100ms),
calls `voice_sup:gather_state()`, calls `dispatcher:snapshot()`,
calls `clock:snapshot()`, stitches the JSON, writes to StateBus.
~10 Hz publication is plenty for Calypso's `state` verb; the current
20 Hz is overkill (it's just whatever the scheduler tick happened to
be).

Why a dedicated publisher rather than each owner publishing its
slice:
- Calypso reads one ETS row, not three. Stitching at read time would
  push complexity into Calypso.
- Decouples publication rate from tick rate. Could go faster if a
  consumer needs it; could go slower if we want.

Why not just have the clock do it (since it already ticks):
- The clock should be lean. Adding "walk the whole supervision tree
  and serialize" couples it to a non-clock concern.

### 2.7 Slot bus — strip out

**Decision: delete `state.slots` field + `SetSlot` handler + `slot`
verb. Confirmed dormant scaffolding.**

`git blame` traced the field to commit `1ea3be6d` (2026-04-26,
"Named-binding dispatch layer"). The commit message names it as
scaffolding for unimplemented work:

> `slot <name> <value>` — set input slot value (Param scaffold;
> **not yet wired to MIDI/Tangle**)
>
> Out of scope for this commit (next sessions):
> - **Real `Param a = Lit a | Slot SlotRef` wiring**

The follow-up session never happened. Grep across the source confirms
zero readers in dispatch — only the write path (`SetSlot` verb), the
internal map mutation, and the JSON serialization for the `state`
verb's snapshot. The `slot foo 0.5` verb logs and stores; nothing
reacts.

The eventual `Param a = Lit a | Slot SlotRef` feature can be re-added
when actually implemented (a few-line addition: dispatcher gains a
`slots` field; `Param a` gains a `Slot` constructor; dispatch
resolves it). There is no design work being lost.

**NOTE: `isSlotOverride` and `param7bit` are unrelated.** Different
commit (`a7e825ff`, 2026-05-02, "Add `#` parameter-join operator").
The name is overloaded — there `slot` means "the param `vel` slots
into the MidiNote's velocity field." Wired in via the BoundTrack
dispatch loop, fully working. Keep.

This deletion is scheduled as a precursor cleanup commit before
PR1.4d-i so MIDIScheduler.purs starts the migration smaller. See §3
revised order.

## 3. Migration path

### 3.0 Precursor cleanup — strip dormant `slots` scaffolding

Standalone commit before PR1.4d-i. Removes the `state.slots` field,
`SetSlot` Msg constructor, and `slot <name> <value>` verb. Pure
deletion — no behaviour change because nothing reads slots today.
Detailed reasoning in §2.7.

### 3.1 PR1.4d — Voice + dispatcher own discrete dispatch end-to-end

Two commits:

**PR1.4d-i** — `bind` verb dual-writes to dispatcher.
- WS handler's `addBinding` continues to send to MIDIScheduler AND
  also calls `tidal_dispatcher:set_binding_from_spec/2` (new API
  that parses the spec via `Tidal.Binding.parseCompoundAction` then
  updates dispatcher state).
- Same dual-write for `removeBinding` and `registerMidiDevice`.
- Continuous bindings (`midi-cc-cont` / `cv-cont`) silently no-op on
  the dispatcher side because the dispatcher doesn't have a
  `continuousBindings` field yet (added in PR1.5). MIDIScheduler
  still handles them as today.
- Behavior unchanged. The dispatcher's registry is populated as a
  parallel structure for PR1.4d-ii to consume.

**PR1.4d-ii** — `playByName` / `PlayByNameP` / `PlayByNameExpr`
route to voices.
- WS handler reads binding from dispatcher, parses pattern + params,
  installs voice via `voice_sup:set_voice(name, kind, pattern,
  params, binding)`. (`set_voice` = upsert: replaces if voice for
  that name exists.)
- Voice state extends with `params :: Map String (Pattern String)`.
- Voice's `computeUntil` samples each param pattern at each event
  position; events carry pre-sampled `params :: Map String String`.
- Dispatcher's `dispatchEvent` consumes per-event params: applies
  slot overrides, performs compositional fanout via `bindings`
  registry lookup.

After 1.4d-ii: discrete voices fully run on the new tree. MIDI-
Scheduler's BoundTrack dispatch is dead (no patterns reach it).

### 3.2 PR1.4e — Dismantle MIDIScheduler's discrete path

- Remove `tracks` field, `BoundTrack` walk, `AddBinding` /
  `RemoveBinding` / `RegisterMidiDevice` handlers from MIDIScheduler.
- Migrate shared helpers (`noteNameMidi`, `interpretCV`, `clamp7bit`,
  `param7bit`, `voctValue`, `noteEntry`) into a new module
  `Tidal.Dispatch.Helpers`. Update Dispatcher's imports.
- MIDIScheduler shrinks to: clock+tick book-keeping, continuous
  voice tick, FH-2 verbs, legacy GateTrack/CVTrack/ESXTrack walks
  (still alive at this commit).

### 3.3 PR1.5 — Continuous voices migrate

This is the largest sub-PR after PR1.4d. Three sub-commits.

#### 3.3.1 PR1.5-a — Infrastructure (additive, no routing flip)

**Goal**: Voice and Dispatcher both gain the data structures + APIs
needed to host continuous voices end-to-end, but no WS verb routes
to the new continuous path yet. Continuous still flows through
MIDIScheduler.

**Files & changes:**

- **`src/Tidal/Binding.purs`** — new module home for `ContDest`.
  Move from MIDIScheduler.purs:
  ```purescript
  data ContDest
    = ContMidiCC { device :: String, channel :: Int, cc :: Int }
    | ContCV     { bus :: Int, transforms :: Array Transform }
  ```
  Export from Tidal.Binding's module list. The
  parallel-implementation note at top of Tidal.Binding noted server-
  side-only types — ContDest is server-side state, fits there. The
  `Transform` import comes from `Tidal.Transform` (already used).
  *Server-only*: do NOT mirror in tidal-protocol's Binding.purs;
  ContDest is dispatch state, not wire protocol.

- **`src/Tidal/Voice.purs`** — voice state becomes a sum:
  ```purescript
  data VoiceKind
    = Discrete
        { pattern :: Maybe (Pattern String)
        , params :: Map String (Pattern String)
        , binding :: Binding
        }
    | Continuous
        { pattern :: Maybe (Pattern Number)
        , dest :: ContDest
        }

  newtype State = State
    { name :: String
    , kind :: VoiceKind
    , phase :: Rational
    , lastEmittedUntil :: Rational
    , muted :: Boolean
    }
  ```
  - `initialState` becomes `initialDiscreteState` and
    `initialContinuousState` (or one constructor with explicit
    kind).
  - `setPattern :: Pattern String -> State -> State` updates the
    Discrete variant only (errors silently if Continuous? or no-op?
    decision: silent no-op + a debug log; matches existing style).
  - New: `setContinuousPattern :: Pattern Number -> State -> State`
    for the Continuous variant.
  - `installFromSpec` (used by WS handler for discrete) stays as is —
    its caller checks discrete-binding-ness first.
  - New: `installContFromExpr :: Pattern Number -> State -> State`
    or similar — set continuous pattern from an already-evaluated
    Pattern Number.
  - `EventToDispatch` becomes a sum:
    ```purescript
    data EventToDispatch
      = DiscreteEvent { token :: String, wallTimeUs :: Number, params :: Map String String }
      | ContinuousEvent { value :: Number, wallTimeUs :: Number }
    ```
  - `computeUntil` dispatches on `state.kind`:
    - `Discrete`: same logic as today.
    - `Continuous`: samples the Pattern Number at currentCycle (one
      tick = one emission). Produces zero or one events. lastEmittedUntil
      semantics simpler — just bumped to the integer cycle of currentCycle
      plus a small step, OR we can drop the dedup since each tick
      always re-samples (no look-ahead). Decision: keep
      lastEmittedUntil for parity but it doesn't gate emission.
    - Actually simpler: the Continuous branch emits on every tick if
      the pattern is set, regardless of lastEmittedUntil.
  - Snapshot extends to indicate kind.

- **`src/tidal_voice.erl`** — handle the polymorphic state opaquely;
  the `compute_until` cast iterates events with the correct
  dispatch_event variant per event tag:
  ```erlang
  array:foldl(fun(_Idx, E, _) ->
                  case E of
                      #{kind := <<"discrete">>, ...} ->
                          tidal_dispatcher:dispatch_event(...);
                      #{kind := <<"continuous">>, ...} ->
                          tidal_dispatcher:dispatch_cont_event(...)
                  end
              end, ok, Events).
  ```
  Or the Erlang side can read a `kind` field from each event map.
  (Note: PureScript sum types compile to tagged tuples;
  destructuring will use `{discreteEvent, ...}` / `{continuousEvent, ...}`
  patterns. Test the encoding before writing the dispatch.)

- **`src/tidal_voice_sup.erl`** — new entrypoint:
  ```erlang
  set_voice_cont_pat(Name, ContDest, Pattern) ->
      ...
  ```
  Mirror of set_voice_pat/3 but creates a Continuous-kind voice.

- **`src/Tidal/Dispatcher.purs`** — state extends:
  ```purescript
  newtype State = State
    { ...
    , continuousBindings :: Map String ContDest
    , ...
    }
  ```
  New API:
  - `setContinuousBinding :: String -> ContDest -> State -> State`
  - `removeContinuousBinding :: String -> State -> State` — could
    unify with removeBinding (delete from both maps). Decision:
    unify, since unbind is one verb at the WS layer.
  - `lookupContinuousBinding :: String -> State -> Maybe ContDest`
  - `dispatchContEvent :: { name, value, wallTimeUs } -> State -> Effect State`
    that looks up `continuousBindings`, applies the dest's emit
    logic (mirror of MIDIScheduler.dispatchContValue).
  - `setBindingFromSpec` extends: tries `parseContBinding` first
    (move that helper to Tidal.Binding alongside ContDest), falls
    through to `parseCompoundAction`. On continuous-spec match,
    install in continuousBindings; on discrete, install in bindings.

- **`src/tidal_dispatcher.erl`** — new APIs:
  ```erlang
  -export([..., dispatch_cont_event/3, lookup_continuous_binding/1, ...]).

  dispatch_cont_event(Name, Value, WallTimeUs) ->
      gen_server:cast(?MODULE,
                      {cont_event, Name, Value, WallTimeUs}).
  ```
  handle_call adds `{lookup_continuous_binding, Name}` →
  `'tidal_dispatcher@ps':lookupContinuousBinding(Name, PsState)`.
  handle_cast adds `{cont_event, ...}`.

- **`src/Tidal/Expr.purs`** — `parseEvalNumPattern` (sister to
  parseEvalPattern):
  ```purescript
  parseEvalNumPattern :: String -> Either String (Pattern Number)
  parseEvalNumPattern src = do
    e <- parseExpr src
    r <- evalExpr e
    case r of
      VNumPattern p -> Right p
      _ -> Left "expected a number pattern"
  ```

- **`src/Tidal/Dispatch/Helpers.purs`** — no changes (already has
  shared dispatch helpers).

- **`src/Tidal/MIDIScheduler.purs`** — no changes (still hosts
  continuous voices through ContinuousTrack tick walk; will be
  cleaned up in PR1.5-c).

**Build/test expectations:**
- All existing tests pass.
- Behavior unchanged at the user level — no WS verb reaches the new
  continuous path.

**Verification before commit:**
- Manual test: existing discrete cells still play correctly.
- Existing continuous cells (`bass-cutoff :slow 4 sine`) still LFO
  through MIDIScheduler.

#### 3.3.2 PR1.5-b — Routing flip

**Goal**: WS handler `bind` dual-writes continuous specs to
dispatcher; WS handler `playByNameExpr` routes continuous-bound
expressions through the new tree.

**Files & changes:**

- **`src/Tidal/WebSocket/Handler.erl`** — bind path stays as is
  (`set_binding_from_spec` now handles continuous specs internally
  thanks to PR1.5-a's parser extension).

- **`src/Tidal/WebSocket/Handler.erl`** — `handle_play_by_name_expr`
  extends decision logic:
  ```erlang
  case tidal_dispatcher:lookup_binding(Word) of
      {just, Binding} -> ... discrete path (unchanged)
      {nothing} ->
          case tidal_dispatcher:lookup_continuous_binding(Word) of
              {just, Dest} ->
                  case ('tidal_expr@ps':parseEvalNumPattern())(ExprSrc) of
                      {right, Pattern} ->
                          tidal_voice_sup:set_voice_cont_pat(Word, Dest, Pattern),
                          ... reply ok
                      {left, _Err} ->
                          SchedulerPid ! {playByNameExpr, ...},
                          ... forward
                  end;
              {nothing} ->
                  SchedulerPid ! {playByNameExpr, ...},
                  ... legacy fallback in MIDIScheduler
          end
  end.
  ```

- **`src/tidal_voice.erl`** — verify install_from_spec doesn't
  accidentally apply to Continuous voices (it shouldn't, since
  Continuous voices are created via set_voice_cont_pat which uses
  setContinuousPattern).

**Build/test expectations:**
- All existing tests pass.
- New behavior: `bass-cutoff :slow 4 sine` runs through new tree.
- Verification: hush works on both kinds (since hush_all clears
  pattern of every voice via clear_pattern, polymorphic).

**Verification before commit:**
- Manual test: LFO modulating a filter (continuous voice through new
  tree).
- Existing discrete cells still work.
- Hush silences both discrete and continuous voices.

#### 3.3.3 PR1.5-c — MIDIScheduler cleanup

**Goal**: remove now-dead continuous-voice code from MIDIScheduler.

**Files & changes:**

- **`src/Tidal/MIDIScheduler.purs`**:
  - Drop `continuousTracks :: Array ContinuousTrackData` field from
    `MIDISchedulerState`.
  - Drop `continuousBindings :: Map String ContDest` field (it's now
    on dispatcher; see ‘Snapshot' below for cosmetic concern).
  - Drop `dispatchContValue` function.
  - Drop the continuous voice tick walk in `midiSchedulerLoop` (the
    `for_ state.continuousTracks` block at the end of the Tick
    handler).
  - Drop `parseContBinding` (moved to Tidal.Binding).
  - Drop `ContDest` definition (moved).
  - Drop `ContinuousTrackData` type.
  - Drop `numberToCycleRat` if unused after removal.
  - `AddBinding` handler: simplify — it tried parseContBinding then
    parseCompoundAction; now only parseCompoundAction (continuous is
    handled by dispatcher's setBindingFromSpec via dual-write). Or
    maybe keep both for snapshot purposes (continuous bindings
    appear in JSON snapshot). Decision: keep both, for snapshot
    until PR1.8.
  - Actually re-read: continuousBindings stays on MIDIScheduler
    until PR1.8 for snapshot purposes — same logic as bindings.
    Re-examine: do we need to keep the field?
    - bindings + sinkTypes feed the snapshot's `bindingNames` and
      `voices` arrays.
    - continuousBindings feeds the snapshot's `continuousBindings`
      array.
    - All three should stay until PR1.8.
  - So PR1.5-c removes ONLY the runtime dispatch code, NOT the
    state fields used for snapshots. Same pattern as PR1.4e.
  - Remove ContDest definition (moved to Binding) — but the field
    references it. Need to import the new location.

- **Update test files** if any reference dropped functions.

**Build/test expectations:**
- All existing tests pass.
- MIDIScheduler.purs shrinks ~150-200 lines.
- Behavior unchanged.

**Verification before commit:**
- Continuous voices through new tree (smoke).
- Discrete voices through new tree (smoke).
- State JSON snapshot still includes continuousBindings (for Calypso).

#### Risks / things to test before each commit

- **PureScript sum-type encoding for VoiceKind**: each variant is
  a tagged tuple (`{discrete, ...}` / `{continuous, ...}`).
  The Erlang voice gen_server's `compute_until` handler must NOT
  pattern-match on this directly — it should pass the opaque state
  through PureScript and only inspect `EventToDispatch`'s tagged
  output. The events are where the kind needs to discriminate.

- **EventToDispatch encoding**: `{discreteEvent, #{...}}` vs
  `{continuousEvent, #{...}}` after compilation. The Erlang voice's
  `array:foldl` over events case-matches on these tags.

- **ContDest encoding**: `{contMidiCC, #{...}}` and `{contCV, #{...}}`.
  The dispatcher's PureScript dispatchContEvent destructures these
  inside PureScript so Erlang doesn't need to know.

- **Map encoding for Pattern Number**: same as Pattern String at
  runtime — opaque function values. Voice and dispatcher don't
  inspect them directly.

#### Rollback plan

If PR1.5-a infrastructure has a fundamental issue (e.g. sum-type
encoding doesn't work as expected), revert the commit and reconsider.
Options to fall back on:
- Two parallel voice modules: `Tidal.Voice.Discrete` and
  `Tidal.Voice.Continuous` with separate State types and supervisors.
- Keep continuous voices in MIDIScheduler indefinitely; mark PR1.5
  as "deferred" and skip to PR1.6.

Document failure in §5 and adjust before retry.

After 1.5: continuous voices run on new tree. MIDIScheduler's
`continuousTracks` walk is gone. State snapshot fields kept for
PR1.8.

### 3.4 PR1.6 — FH-2 migrates

- New `PrimAction.Fh2Trigger { voice, defaultNote }` constructor.
- WS handler's `fh2-trigger` verb installs a voice with that
  PrimAction.
- Dispatcher's `Fh2Trigger` handler resolves channel via
  `fh2VoiceChannels` and emits.
- `Fh2Envelope` / `Fh2Shape` route to dispatcher directly (no voice).

After 1.6: MIDIScheduler.purs is empty modulo helpers and the
legacy GateTrack/CVTrack/ESXTrack code (which already migrated to
synthesized BoundTrack equivalents at the verb-handling level).

### 3.5 PR1.7 — Legacy verbs synthesize BoundTracks

- WS handler's `UpdateGateTrack`, `UpdateCVTrack`, `UpdateESXTrack`
  install voices with auto-generated bindings under reserved names.
- MIDIScheduler.purs is deleted in this commit.

### 3.6 PR1.8 — State publisher

- `tidal_state_pub` gen_server reads from voice_sup + dispatcher +
  clock at 10Hz, writes JSON to StateBus.
- Calypso's `state` reading is unchanged (same ETS row, same JSON
  shape).

## 4. Failure modes and rollback strategy

This is a multi-PR refactor on a feature branch. Each numbered PR
above is a coherent commit — the branch should compile and pass
tests at each one. If a PR proves to be irreconcilable mid-flight:

1. **Revert the bad commit**, keep the prior state.
2. **Add a `failure-log` section to this doc** documenting what
   went wrong: what assumption broke, what alternative was tried,
   what the root cause was.
3. **Reset the branch** to before the problematic PR and adjust
   the design here before re-trying.

Common failure modes to anticipate:

- **PureScript Array vs Erlang array confusion** — already hit once
  in PR1.4b. Voice/dispatcher state with collection types needs to
  match the runtime encoding. Test in `erl -noshell` before
  committing each PR.
- **Newtype/sum encoding** — purs-backend-erl wraps every ADT
  constructor as a tuple. The `VoiceKind` sum type especially: each
  variant is a tagged tuple at runtime. Erlang code that destructures
  needs to know this.
- **Cast ordering** — voices push to dispatcher; dispatcher mutates
  state. If a `bind` verb reaches the dispatcher *after* the voice
  starts emitting events for that name, the dispatcher's binding
  lookup fails. Pre-PR1.4d this was bounded by MIDIScheduler being a
  single mailbox. Post-PR1.4d the dispatcher and voice_sup are
  parallel. Mitigation: WS handler does dispatcher:set_binding
  *before* voice_sup:set_voice (sequential calls, dispatcher's call
  is synchronous so it's strictly happens-before).
- **State publisher race** — `tidal_state_pub` reads from N
  processes at non-atomic moments. Acceptable per the plan doc's
  §5 ("`state` snapshot is eventually consistent"). Document this
  in the publisher's module comment.

---

**See also:**
- `docs/per-voice-refactor-plan.md` — upstream plan doc.
- `docs/live-coding-feasibility.md` — design exploration.
- `src/Tidal/MIDIScheduler.purs` — the file being dismantled.
- `src/Tidal/Dispatcher.purs` — the migration destination for
  dispatch logic.
- `src/Tidal/Voice.purs` — the migration destination for per-voice
  state.

## 5. Failure log

(empty — to be populated if we hit irreconcilable problems and have
to reset)
