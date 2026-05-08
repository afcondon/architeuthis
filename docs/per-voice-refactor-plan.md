# Per-voice supervision refactor — implementation plan

A concrete plan for **Path A** from `live-coding-feasibility.md`:
refactoring purerl-tidal's monolithic `MIDIScheduler` into a per-voice
OTP supervision tree, plus the follow-on work that gets us to
~1.0–1.3 s cell-fire latency. Captured 2026-05-07 from a session that
revisited the feasibility doc and ran fresh compile-time measurements.

This doc is meant to (a) guide the work across PRs and (b) serve as
the historical record of why the architecture is shaped the way it
is. The feasibility doc is the upstream context; this is the
operational sequel.

## 1. Goal

Decompose the single `MIDIScheduler` Erlang process into:

- A thin **clock + dispatcher** owning the tick loop and OSC dispatch.
- A **voice supervisor** (`simple_one_for_one` dynamic) managing
  per-voice gen_servers.
- One **voice gen_server per binding**, each holding its own
  `{pattern, binding, phase, last_emitted_until, muted}` state.
- An OTP **application** + top-level supervisor wrapping all of the
  above (the project today has no OTP scaffolding — `Main.purs` just
  `spawn`s the scheduler directly).

Subsequent PRs add hot reload of combinator + cell modules
(`code:load_file/1`) and a daemonised compile pipeline so cell-fire
latency lands in the comfortable-live-coding band.

The motivation is the §6 list from the feasibility doc — crash
isolation, per-voice GC isolation, hot reload, supervisor ergonomics
— none of which today's monolithic scheduler gets. The eDSL question
(Path B from the feasibility doc) is **not** part of this plan; the
work enables it but doesn't commit to it.

## 2. Compile-time measurements (2026-05-07)

Re-running §5.2 of the feasibility doc against a cell-shaped module
(5 lines, imports `Tidal.Pattern.Core`, produces a `Pattern String`):

| Stage                                  | Cold (real edit) | Warm (no-op) | Real per-edit work |
|----------------------------------------|------------------|--------------|--------------------|
| `purs compile --codegen corefn`        | 0.36 s           | 0.30 s       | 0.06 s             |
| `purs-backend-erl --filter Cell.Test1` | 1.59 s           | 0.27 s       | 1.32 s             |
| `erlc`                                 | 0.19 s           | 0.17 s       | 0.02 s             |
| **Total**                              | **~2.14 s**      | ~0.74 s      | ~1.40 s            |

Implications:

- Direct invocation hits **~2.1 s per cell-fire**, consistent with the
  feasibility doc's projection.
- Daemonising `purs-backend-erl` (long-lived process holding the
  optimizer state in memory) recovers ~0.5–0.8 s of startup cost.
  Plausible target: **~1.0–1.3 s** end-to-end.
- Sub-1 s requires upstream incremental-optimizer support —
  `purs-backend-erl` re-verifies the full closure every fire even
  with `--filter`.
- GHCi parity (~200 ms) is not on the table with this toolchain.

The 1.0–1.3 s target sits inside §5.3's "comfortable live coding"
band, which is the right target for a rig that's modular + iPad +
Ableton, not bd-sn improvisation. Cued / DJ-flavoured firing
(prepare, then fire on a beat) makes the latency a non-issue rather
than a limit.

The cell module used for the experiment was deliberately minimal:

```purescript
module Cell.Test1 where

import Prelude
import Data.Rational (fromInt)
import Tidal.Pattern.Core (fast, fastCat, rev)
import Tidal.Pattern.Types (Pattern)

cell :: Pattern String
cell = fast (fromInt 32) (rev (fastCat (map pure ["bd","sn","cp","hh"])))
```

Anything more complex (bigger combinator chain, multiple imports)
would not change the picture meaningfully — the optimizer's cost is
dominated by the closure size, not the cell.

## 3. Architecture

### 3.1 Process tree

```
              purerl_tidal_sup  (top, one_for_all)
                       │
   ┌─────────┬─────────┼────────────────┬──────────────┐
   ▼         ▼         ▼                ▼              ▼
ws_handler clock   voice_sup       dispatcher     link_bridge
(Cowboy)  (gen_   (simple_one_     (gen_server)   (existing
          statem) for_one,                          OSC mirror
                  dynamic)                          of link-spike)
              │       │                  ▲
              │  ┌────┼────┬─────...     │
              │  ▼    ▼    ▼             │
              │ bass lead pad            │
              │ (gen_server: { pattern,  │
              │   binding, phase,        │
              │   last_emitted, muted }) │
              │                          │
              └──cast {compute_until, T}─►
                          │              │
                          └──cast {event, binding, ts, e}──┘
                                                            │
                                                            └─OSC─►link-spike / cv-router
```

### 3.2 Process responsibilities

**`ws_handler`** (existing, Cowboy) — receives WebSocket messages,
parses verbs, routes to voice_sup or specific voices. Today its
references go to `SchedulerPid`; after refactor they go to the
clock (for hush/bpm), to voice_sup (for bind/unbind), or to
specific voice gen_servers (for set_pattern, get_state).

**`clock`** (gen_statem) — owns BPM and a periodic tick (~50 ms).
On each tick: reads `link_bridge` for current beat-time, computes
lookahead window `[now, now + 200 ms]`, casts `{compute_until, T}`
to every voice (via `voice_sup:cast_all/1`). States: `running`,
`paused`. `hush` puts it in `paused`; `unhush` resumes.

**`voice_sup`** (`simple_one_for_one` dynamic supervisor) — children
are voices created via `bind`. API:
- `add_voice(Name, BindingSpec) → Pid`
- `remove_voice(Name) → ok`
- `find_voice(Name) → {ok, Pid} | not_found`
- `cast_all(Msg) → ok` (broadcast)
- `gather_state() → [VoiceState]`

**`voice<Name>`** (gen_server) — state
`{pattern, binding, phase, last_emitted_until, muted}`. Messages:
- `cast {compute_until, T}` — query `pattern` for events in
  `(last_emitted_until, T]`, cast each to `dispatcher` with absolute
  timestamp, update `last_emitted_until`. If `muted`, compute but
  drop events at the emit boundary (preserves phase for instant
  unmute).
- `call {set_pattern, P}` — replace `pattern`. Phase carries over by
  default; `reset_phase` opts out.
- `call {set_pattern_module, Mod}` — call `Mod:cell()` to extract
  pattern, replace. Used for cell-fire (PR3).
- `call get_state` — return state snapshot for the `state` verb.
- `cast reset_phase` — for cell-fire that wants barline reset.
- `cast {set_muted, Bool}` — for mute/unmute.

**`dispatcher`** (gen_server) — receives
`{event, binding, ts, e}`, looks up the binding's destination
(MIDI port + ch / CV bus / OSC route), formats, sends via OSC. Holds
the bridge_client / osc_client handles that today live in
MIDIScheduler. Bottleneck for OSC sends but cheap.

**`link_bridge`** — existing (`tidal_link_anchor.erl` +
`Tidal.LinkAnchor`). No change. Provides a pure read-only mirror of
link-spike's `/link/anchor` OSC.

### 3.3 Decisions

**Push (voice → scheduler) vs pull (clock → voice).** Three coherent
models exist:
- **A.** Pull-by-tick — clock casts `{compute, T}`; voice queries
  pattern, pushes events to dispatcher.
- **B.** Voice self-ticks — voice runs its own timer, reads Link,
  pushes events autonomously.
- **C.** Voices push *recipes* (patterns) to a central scheduler;
  scheduler holds all patterns and does all computation.

A and C are operationally near-identical at the message-flow level;
the difference is whether per-voice state lives in a per-voice
process or a shared scheduler map. C's shared map is what we have
today — a pathological pattern crashes everything. **A is what gives
the BEAM benefits** (crash + GC isolation) precisely because the
state is in a per-process heap. The "muxing engine taking recipes"
intuition (C) is the right *user-facing* mental model — `bind bass
<pattern>` is exactly pushing a recipe — but under the hood the
recipe lives in a per-voice gen_server. From outside, indistinguishable;
from inside, BEAM is doing real work.

B is reserved for cases where voices need genuinely different tick
rates (continuous CV at higher rates than gates). Not needed at
PR1; can be added later as a per-voice option.

**Choice: Pull (model A) at one global tick rate.**

**Phase preservation on cell-fire.** TidalCycles' answer is "carry
over." We mirror that: `set_pattern` preserves phase by default,
`reset_phase` is an opt-in for cells that explicitly want a barline
reset (e.g. retriggering a one-shot). Same convention as Tidal.

**Mute as separate axis.** Mute is a boolean on voice state, applied
at the dispatcher-emit boundary. Distinct from stop (terminate
gen_server, lose state) and pause (clock-level suspension across all
voices). Rationale: keeps phase, makes unmute instant, doesn't
require the voice to know about higher-level transport state.

**Event ordering at the dispatcher.** Today MIDIScheduler emits in
one tick-pass with natural order. After refactor, events arrive at
the dispatcher in any order from any voice. Two options:
- **(i)** Dispatcher sorts by timestamp before sending.
- **(ii)** Accept slight reorder within a tick window — timestamps
  preserve the actual schedule; OSC delivery order doesn't matter to
  link-spike (which kernel-timestamps).

**Choice: (ii).** link-spike's OSC handler honours timestamps; the
order events arrive at link-spike doesn't change when they sound.
If we ever add a destination that ignores timestamps, revisit.

**OTP application scaffolding.** The project today has no `.app.src`,
no top-level supervisor, no `application:start/1`. `Main.purs` just
`spawn`s things. This refactor brings the project under proper OTP.
The `purerl_tidal.app.src` and `purerl_tidal_sup.erl` are part of
PR1's scope.

## 4. PR sequence

### PR 1 — Structural refactor (this branch's first deliverable)

**Behaviour-preserving.** No external API changes; the WS protocol
is identical; the same patterns produce the same events. Existing
tests should pass with no modification.

**New files:**

- `src/purerl_tidal.app.src` — OTP application descriptor.
- `src/purerl_tidal_app.erl` — `application` callback (start/stop).
- `src/purerl_tidal_sup.erl` — top-level `one_for_all` supervisor.
- `src/tidal_voice_sup.erl` — `simple_one_for_one` dynamic
  supervisor for voices.
- `src/Tidal/Voice.purs` — voice gen_server callbacks (PureScript
  side: pattern query, event production, state shape).
- `src/tidal_voice@foreign.erl` — gen_server dispatch shim
  (`init/1`, `handle_call/3`, `handle_cast/2`) wrapping into
  PureScript callbacks.
- `src/Tidal/Clock.purs` + `src/tidal_clock@foreign.erl` — gen_statem
  for the tick loop and BPM state.
- `src/Tidal/Dispatcher.purs` + `src/tidal_dispatcher@foreign.erl` —
  OSC dispatch gen_server (takes over the OSC client + bridge_client
  handles from MIDIScheduler).

**Modified files:**

- `src/Tidal/MIDIScheduler.purs` — voice-state map removed; module
  becomes a thin shim over Clock + Dispatcher + voice_sup, or is
  deleted entirely if the migration absorbs all its responsibilities.
- `src/Main.purs` — replaces `startMIDIScheduler` with
  `application:start(purerl_tidal)`.
- `src/Tidal/WebSocket/Handler.erl` — `bind` / `unbind` route through
  `voice_sup:add_voice` / `voice_sup:remove_voice`. `state` calls
  `voice_sup:gather_state`. `hush` casts to clock. `bpm` casts to
  clock. `setSlot`, `addBinding`, etc. — case by case, but mostly
  unchanged or routed to the appropriate process.
- `Makefile` / `rebar.config` — register the OTP application so
  `application:start` works.

**Estimated size:** ~400 LOC added (mostly OTP boilerplate +
PureScript voice gen_server), ~150 LOC removed/moved from
MIDIScheduler.

**Test plan:**

- All existing tests pass unchanged.
- Manual smoke test: `bind` a voice, observe `state`, fire a
  pattern, hear it, `hush`, observe quiet.
- Crash test: deliberately bind a voice with a pathological pattern
  (e.g. a function that throws); observe the voice restart and other
  voices keep playing.

### PR 2 — Hot reload for combinator modules

Add `code:load_file/1` calls when a `.beam` for a combinator module
(`tidal_pattern_core`, `tidal_pattern_branched`, etc.) rebuilds.
Voices keep using old code until their next pattern construction;
new patterns pick up new combinators automatically.

Trigger mechanism: a small file-watcher on `output-erl/`, or a verb
the user explicitly fires (`reload`).

**Scope:** ~100 LOC. Mostly Erlang `code:load_file` orchestration.

### PR 3 — Cell-as-module + daemonised compile pipeline

The fire-loop:

1. WS receives `fire <name>` with cell text.
2. Server writes `src/Cell/<Name>.purs`.
3. `purs compile` (incremental).
4. `purs-backend-erl --filter Cell.<Name>` (via daemon — see below).
5. `erlc` on the resulting `.erl`.
6. `code:load_file('cell_<name>@ps')`.
7. `gen_server:call(voice_<name>, {set_pattern_module, Mod})`.

The daemon is the engineering effort. Two options:
- **(a)** Wrap `purs-backend-erl` in a long-lived Node process
  holding the optimizer state warm. Communicate via stdin/stdout or
  a socket. Skips Node.js startup + CoreFn re-read on each fire.
- **(b)** Spawn fresh per-fire but cache `output/` aggressively. Less
  speedup, simpler.

**Option (a) is the right answer**; (b) is a fallback if (a) hits a
limit in `purs-backend-erl` we can't work around.

Cell module convention:

```purescript
module Cell.Bass where
import Prelude
import Data.Rational (fromInt)
import Tidal.Pattern.Core (fast, rev, fastCat)
import Tidal.Pattern.Types (Pattern)

cell :: Pattern String
cell = fast (fromInt 4) (rev (fastCat (map pure ["c2","g2","c2","f2"])))
```

Every cell exports a single `cell :: Pattern X`. Convention is the
contract. The voice gen_server's `set_pattern_module` calls
`Mod:cell()` and replaces its state.

**Scope:** ~500 LOC including the daemon. Larger than PR1+PR2 combined
because it spans Node.js (daemon), Erlang (file-write + load_file
orchestration), and PureScript (cell convention).

## 5. Risks

**Hush, BPM, atomicity.** Today these are single state mutations
over `MIDIScheduler`'s map. After refactor they're broadcasts. Edge
case: a voice is mid-`compute_until` when `hush` fires — its
already-computed events still flow to the dispatcher. Mitigation: at
the dispatcher emit-boundary, check whether transport is paused;
drop events if so. Same approach as the per-voice `muted` flag,
applied globally.

**`state` snapshot is eventually consistent.** Gathering from N
voices isn't atomic — a voice could fire an event between two
gather_state calls. For introspection and the `state` verb, fine. If
anything depends on a synchronised snapshot today (e.g. tests
asserting voice A and voice B's last_emitted are equal), it'd need
rethinking. Likely nothing does.

**Slot bus + binding state currently lives in MIDIScheduler.** Slot
values (set via `setSlot`) and binding registry entries (set via
`addBinding`) are global to the scheduler today. They should
probably stay global — they're not per-voice — so they move into
either the dispatcher or a separate `tidal_state` gen_server. This
is a sub-decision in PR1; preferred shape is a separate
`tidal_state` gen_server held by the supervisor, owned by neither
clock nor dispatcher.

**MIDI bridge / OSC client lifetime.** The feasibility doc's memory
note "Erlang gen_udp sockets must be opened inside spawn" applies
here too. The dispatcher gen_server's `init/1` is the right place
to open them; the supervisor's restart strategy (probably
`one_for_all` for the top tree) means a dispatcher crash takes down
the rest of the tree, which gets restarted, which re-opens sockets.
Acceptable.

**FH-2 envelope voices.** These use a slightly different mechanism
(`{fh2_envelope, ...}`, `{updateFh2TriggerTrack, ...}`). They should
be gen_servers like other voices, with a flag indicating their
destination is the FH-2 daemon rather than direct OSC. Worth a
quick audit during PR1 to make sure nothing about FH-2 forces a
different topology.

**ESX tracks.** Same shape — they're entries in `tracks` /
`continuousTracks` today; they become voice gen_servers with their
binding indicating ESX destination.

## 6. Open questions deferred

- **Cell-fire `arrange` and `timeCat`.** Section-scale composition
  (per the `purerl-tidal-jux-design` memory's followup) interacts
  with cell-fire ergonomics. Not urgent for PR1–3.
- **Mute as a separate axis distinct from source-axis decoupling.**
  Per the feasibility doc §9. Worth its own design pass eventually,
  but `muted` boolean on voice state is the right placeholder.
- **Decoupling source-of-fire from cell creation.** Calypso's
  "make-cell-and-fire" friction. Parallel design thread. Doesn't
  block this work.
- **Distributed Erlang for collaborative live-coding.** Mentioned in
  the feasibility doc. Not pursued. The architecture admits it for
  free if we ever want it.

## 7. Sequencing and where this work lives

Branch: `per-voice-supervisors` (this one).

PR1 — structural refactor — lands first. Estimated 1–2 weeks of
focused work; can be split into smaller commits along these
boundaries:

1. OTP scaffolding (app.src, top sup, application callback) — no
   functional change.
2. Voice gen_server (Tidal.Voice + foreign shim + voice_sup) — added
   alongside MIDIScheduler, not yet wired in.
3. Clock and Dispatcher extracted from MIDIScheduler — still
   single-process, but separated.
4. Migration: switch `bind` to voice_sup, switch tick to broadcast,
   delete the old voice-map code.
5. State and slot extracted to `tidal_state` gen_server.

Each step is a coherent commit; the branch should compile and pass
tests at each one.

PR2 and PR3 are subsequent branches off main, after PR1 lands.

---

**See also:**
- `docs/live-coding-feasibility.md` — upstream design exploration.
- `ARCHITECTURE.md` — current architecture at refactor start.
