# Typeful-cues end-to-end test runbook (2026-05-15)

Smallest viable demo of the typeful-cues path producing real MIDI
in Ableton. Validates that a `Cue` value from a typeful `.tiderl`
session flows through the existing purerl-tidal dispatcher and
emits audible notes.

## Prerequisites

1. **IAC port enabled** on macOS: Audio MIDI Setup → IAC Driver →
   check "Device is online". Port name: "IAC Driver Tidal" (per
   `reference_macos_iac_port_naming` — no parens).
2. **Ableton Live** running with:
   - A MIDI track set to "IAC Driver Tidal" channel 1 input
   - Track armed for recording / monitor on
   - A bass instrument loaded (anything that plays low MIDI notes —
     bass1A's pattern targets notes c2 / e2 / g2 / b2)
3. **purerl-tidal** built and ready (see "Build" below).
4. **wscat** or any WebSocket client.

## Build

```bash
cd /Users/afc/work/afc-work/music/live-coding/purerl-tidal
git checkout typeful-cues
make
```

The build produces ~537 `.beam` files in `ebin/`, including:

- `calypso_prelude@ps.beam` — the DSL
- `calypso_generated_session@ps.beam` — the typeful session
- `calypso_voices_bass1@ps.beam` — voice wrapper exposing `armed/0`
- `tidal_generated_mcalypsobass1@ps.beam` — bridge to the
  existing `play-armed` infrastructure

## Run

```bash
make run
```

Or via DeepStar:
```bash
deepstar up tidal
```

WebSocket on `ws://localhost:3012/ws`.

## Test sequence

Connect via wscat (or any WS client):

```bash
wscat -c ws://localhost:3012/ws
```

Send these messages in order (response after each):

```
midi-device iac "IAC Driver Tidal"
→ OK: midi-device iac → IAC Driver Tidal

bind bass1 midi-note iac 1 36 100 50
→ OK: bound bass1 → midi-note(iac, ch=1, note=36, vel=100, dur=50ms)

play-armed bass1 Mcalypsobass1
→ OK: play-armed bass1 Mcalypsobass1
```

After the third command, **Ableton should start receiving MIDI**
on the IAC Driver Tidal channel 1. The pattern is bass1A's
`mini "c2 e2 g2 ~ b2 ~ g2 e2"` — 6 notes per cycle (one cycle per
beat at the current bpm), with rests on positions 4 and 6.

## What's being tested

The `Mcalypsobass1` bridge module compiles to:

```erlang
pattern() ->
  erlang:map_get(body, calypso_generated_session@ps:bass1A()).
```

This:
1. Calls `bass1A/0` on the typeful session — returns a `Cue` value
   (an Erlang map `#{destination => ..., body => PatternFun}`)
2. Extracts the `body` field — a `Pattern String` (Erlang fun)
3. Returns it as the module's `pattern/0`

The existing `play-armed` handler then:
1. Builds the atom `tidal_generated_mcalypsobass1@ps`
2. Calls `:pattern()` → gets the Pattern from our typeful path
3. Looks up the binding registered for `bass1` (which we set up via
   `bind bass1 midi-note iac 1 36 100 50`)
4. Installs the Pattern + Binding into the `bass1` voice gen_server
5. The voice's dispatch loop fires MIDI events from the pattern

The Pattern was constructed via `mini` at PureScript module-load
time — same parser the existing cell-compile pipeline uses, just
called from a different surface.

## If it doesn't work

- **"ERR play-armed: error: undef"**: the module isn't loaded.
  Confirm `ls ebin/tidal_generated_mcalypsobass1@ps.beam` shows the
  file. If not, re-run `make`.
- **"ERR play-armed: not found"**: the bass1 binding isn't
  registered. The `bind` step must succeed first.
- **No MIDI events seen**: check Ableton's MIDI input setting and
  that the track is armed. The pattern fires at the current bpm
  (default 120) — at that speed, ~6 notes per second.

## Success criteria

When this works end-to-end, the typeful-cues architecture is
validated through real MIDI dispatch. The path:

```
.tiderl source (PureScript)
  → corefn → .erl → .beam
  → calypso_generated_session@ps:bass1A/0  (Cue value)
  → tidal_generated_mcalypsobass1@ps:pattern/0  (Pattern String)
  → tidal_voice gen_server for "bass1"
  → tidal_dispatcher → CoreMIDI → IAC Driver Tidal
  → Ableton track input → bass synth
  → AUDIBLE SOUND
```

is fully proven.

## What this does NOT validate

- **Cue-switch hot-load.** Today the bridge module references
  `bass1A` statically. To demonstrate switching to `bass1B` etc.
  we'd need the daemon-side wrapper synthesis (Phase 2 of the
  plan) — recompile `Tidal.Generated.Mcalypsobass1.purs` to point
  to a different cue, hot-load, the voice swaps. Future session.
- **The full session loader.** A real Calypso daemon would walk
  the Session value and register all bindings + devices
  automatically. Here we use the existing `bind` / `midi-device`
  wire verbs as manual setup. The walker is also Phase 2.
- **Multiple simultaneous voices.** Only bass1 is wired. Multiple
  voices = repeat the bind/play sequence for each.
