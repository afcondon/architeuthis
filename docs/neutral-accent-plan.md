# Neutral accents / per-event velocity — scope

> **SUPERSEDED (2026-06-04) by `typed-edsl-plan.md`.** The B1/B2 framing below is
> obsolete: we rejected Tidal's stringly `ValueMap` and chose a *typed* `Sound`
> record, under which accents are simply the `gain` field. Step 1 (dispatcher
> `gain`→velocity) still applies and is done. Kept for the dispatch/Balistes
> findings, which remain accurate.

**Goal.** A Tidal-native, output-neutral way to specify accented drum patterns
from the live-coding/generative tool. The *same* accent spec should render on
MIDI→Ableton, OSC→SuperDirt, and CV/gate→modular. Two mandates:

1. **Strict superset of Tidal.** Don't duplicate or change how Tidal works;
   a Tidal user's muscle memory should apply verbatim.
2. **Don't make our own eDSL ugly** in the name of abstracting all three outputs.

**Headline:** the neutral quantity is *per-step strength* (0..1) — already the
genre `StepProfile`, already Balistes' accent bit, and exactly Tidal's `gain`.
Each backend renders it natively (MIDI velocity, Dirt amp, modular accent).
We are not inventing a control; we are making one existing control flow.

---

## What already works (the de-risk)

- **The dispatcher already applies per-event velocity to drum kits.**
  `Tidal/Dispatcher.purs` — `MidiNote` (line ~320) *and* `MidiDrumKit`
  (line ~359) both do `case Map.lookup "vel" params of … param7bit …`,
  overriding the binding/kit default velocity per event. `consumesVel`
  (line ~621) returns true for both. So `# vel` → MIDI note-on velocity is
  **done** on the MIDI leg, including drums.
- **The live-coding cell path already samples `#`-params.**
  `tidal_voice.erl install_from_spec(Name, PatStr, ParamSpecs)` installs a main
  pattern plus `# key pat` param patterns, samples each per step, and passes a
  `params` map to `dispatch_event`. Param specs are parsed as **text** over the
  WS verb, so they bypass PureScript's type checker.
- **Balistes is the precedent.** `balistes_voice.erl` renders the Grids
  per-step `{Inst, Accent}` to `vel`(90)/`vel_accent`(127) MIDI velocity out to
  the FH-2 — i.e. strength→velocity→modular already ships. We mirror it; we do
  not route transcribed patterns through it (Balistes plays Grids' own 5×5 map,
  not arbitrary patterns).

So the rendering leg (per-event velocity to MIDI/FH-2) is **proven and present.**

## Findings — open question #2 resolved (the two pattern worlds)

Tracing `play-piece` → `Tidal/Voice.purs computeDiscrete` settled it. The engine
runs **two parallel pattern models**:

- **World 1 — typed body + sidecar params (what Calypso parts use today).**
  `PitchedPart`/`DrumPart` (`Calypso/Prelude.purs`) carry `body :: Pattern note`
  / `Pattern DrumHitRef` and **no params field**. The *voice* holds params
  separately: `computeDiscrete` takes `params :: Map String (Pattern String)`,
  samples each per event, and hands them to dispatch (`setPatternWithParams p ps`).
  The voice machinery for per-event params therefore **already exists** — but the
  only thing that fills it is the **live text path** (`install_from_spec` parsing
  `# key pat` segments from the WS verb). A *compiled* part has nowhere to put
  params, so `play-piece` installs them empty.

- **World 2 — real Tidal `ControlPattern` (present, not wired to parts).**
  `Tidal/Controls.purs` is a faithful Tidal control layer: `ValueMap`,
  `ControlPattern`, `s`/`note`/`gain`/`pan`/`speed`, and `merge` (`#`), `|>`,
  `|+`, … So `s (pure "bd") # gain (pure 0.8)` is genuine Tidal here — but parts
  don't consume a `ControlPattern`; they consume a typed body.

**Consequence:** `drum "…" # gain "…"` doesn't typecheck because `drum` is World 1
and `#`/`gain` are World 2. And it's not drum-specific — *compiled pitched parts
can't carry `# gain` either*. The gap is general: **compiled parts don't capture
`#`-params.**

## The fork (decide before building)

Both routes give the same dispatch/rendering (already present); they differ in the
**author surface** and how much they pay down the divergence:

- **Route B1 — extend the sidecar to compiled parts (smaller).** Add an optional
  params map to `PitchedPart`/`DrumPart`; provide a World-1 attach combinator
  (e.g. `gainP pat "1 0.6"` or a `# `-lookalike that lives in World 1) that the
  `play-piece` install threads into the voice's existing `params`. Surface is
  *Tidal-ish* but not literally Tidal's `# gain` (different operator), so it
  mildly violates "strict superset". Least code; reuses the proven sidecar.
- **Route B2 — parts carry a `ControlPattern` body (bigger, true superset).**
  Let a part's body be a World-2 `ControlPattern`; `drum "…"` yields one (sets
  `s`); `# gain` is *literally Tidal's*; the voice samples the ValueMap instead of
  a typed pattern + string sidecar. This unifies the two worlds for parts and
  makes the surface a genuine Tidal superset (every Tidal control + combinator
  applies, verbatim). More work in the voice/walker, and it touches the
  Degree→scale render path (`renderToken`) which currently lives on the typed
  body.

**Recommendation:** **B2** matches the strict-superset mandate (the surface
becomes real Tidal, the engine has *fewer* models not more), and World 2 already
exists — we're connecting it, not building it. B1 is the fallback if B2's
voice/walker change proves too invasive for now. Either way the dispatch and the
neutral `gain`→velocity mapping are the same downstream work.

## What's missing (the actual work)

1. **Author surface — `#` won't compose with a drum pattern.**
   `drum "cga"` yields a `DrumPart` whose body is `Pattern DrumHitRef`
   (`Calypso/Prelude.purs` ~line 421), not a `ControlPattern` (`Pattern
   ValueMap`). So `drum "cga" # gain "…"` does not typecheck — you cannot *write*
   an accented drum cell in PureScript, even though the dispatcher would honour
   it. **This is the core change** (and the superset prize).

2. **Compiled-session parts don't carry per-event params.**
   Our generator emits a compiled `Calypso.Generated.Session` played via
   `play-piece`. Compiled parts are `Pattern note` / `Pattern DrumHitRef` with no
   ValueMap, so the walker has no params to sample → dispatch falls back to
   defaults. (The live `install_from_spec` path *does* carry params; the compiled
   path does not — yet.) **Open question to confirm first:** does the
   SessionWalker dispatch PrimActions directly, or re-serialize parts into
   `install_from_spec` specs? That decides whether (1) alone suffices or whether
   the walker also needs to sample a ValueMap body.

3. **Neutral control name.** The dispatcher recognises `vel` (absolute 0..127).
   For neutrality + superset we want `gain` (0..1, Tidal's universal loudness):
   MIDI `velocity = round(gain*127)` (a curve later if needed), Dirt `amp`,
   modular accent. Keep `vel` as the absolute power-user override. One small
   helper in the param lookup + add `gain` to `consumesVel`.

4. **Modular accent leg.** `GateDrumKit` (Dispatcher ~line 371) fires a fixed
   gate; it does not yet read `gain`/`vel`. Modular accent = an accent gate or a
   velocity CV via es9-daemon. Needs es9-daemon support → **defer to Phase 2.**

5. **SuperDirt leg.** No Dirt PrimAction is wired (57120 collides with
   es9-daemon; rig is MIDI-first). `gain`→Dirt `amp` when/if Dirt is wired →
   **defer to Phase 3.**

6. **The lowering.** `calypso .../Tarot/Lower.purs` must emit each drum voice's
   `StepProfile` strength as a `# gain "…"` param alongside the tokens.

## Surface design (the heart) — drums as ControlPatterns

Make `drum "cga ~ cga"` yield a **ControlPattern** (sets a sound/hit-token
control, e.g. `s`), exactly like Tidal's `s "…"`. Then:

```purescript
on vDrums kit (drum "cga ~ cga cga" # gain "1 ~ 0.6 0.9")   -- composes natively
on vDrums kit (every 4 (# gain "1.1 0.5") (drum "cga*8"))   -- every/jux/off all apply
```

- `drum` stays as sugar (preserves the GM token vocabulary + kit binding), but
  underneath it is a vanilla ControlPattern → **every Tidal combinator works**
  and `#` composes. This *removes* a bespoke type rather than adding one.
- The `kit` stops being a pattern type and becomes a **binding** that reads the
  per-event map (token + `gain`/`vel`) and renders to the device. Dispatch
  already does the velocity half.
- **Backward compatible:** `on vDrums qd1 (drum "bd ~ sn")` (no `#`) is just a
  ControlPattern with no gain → unchanged behaviour. `every 8 rev (drum "…")` in
  `Sessions/Fugue`/`Full` keeps working (combinators apply to ControlPatterns).

Decision to confirm: keep the name `drum` (kit-token vocabulary, discoverable) vs
reuse Tidal's `s`. Recommend **keep `drum`** as a thin alias for the superset
feel without losing the kit vocabulary.

## Neutral mapping (one knob → three renderings)

| `gain` (0..1) | MIDI (Ableton + FH-2) | SuperDirt | Modular (gate/CV) |
|---|---|---|---|
| 0 | (rest / vel 0) | amp 0 | no gate |
| 0.5 | velocity ≈ 64 | amp 0.5 | accent off |
| 1.0 | velocity 127 | amp 1.0 (unity) | accent on / vel-CV high |

`vel "0..127"` remains available as an absolute override (what the dispatcher
recognises today).

## Phasing

- **Phase 0 — verify rendering (no code).** Over the raw WS, bind a drum kit and
  send `cga ~ cga # vel "120 0 70"`; confirm velocity reaches Ableton (drum-rack
  dynamics / MIDI monitor). Proves the dispatch leg end-to-end before touching
  types.
- **Phase 1 — surface + MIDI + lowering (the 80%).**
  (a) `drum` → ControlPattern; adjust the `On`/DrumKit instance so `on vDrums
  kit (controlpat)` typechecks; keep back-compat.
  (b) Confirm/!x the compiled-path param flow (open question #2); make compiled
  Parts carry a ValueMap body and the walker sample it (if needed).
  (c) Recognise `gain` (0..1) → velocity in the dispatcher; add to `consumesVel`.
  (d) Lowering emits StepProfile strength as `# gain "…"`.
  → Accented drums to Ableton + FH-2 on every genre. Testable by ear.
- **Phase 2 — modular accent.** `GateDrumKit` honours `gain` → accent gate / vel
  CV via es9-daemon. (es9-daemon change.)
- **Phase 3 — SuperDirt.** `gain` → Dirt `amp` when the OSC path is wired.

## Files

- `purerl-tidal/src/Calypso/Prelude.purs` — `drum`, `DrumPart`, `On`/DrumKit
  instance (the surface change).
- `purerl-tidal/src/Tidal/Dispatcher.purs` — add `gain` (0..1)→velocity to the
  `MidiNote`/`MidiDrumKit` param lookup + `consumesVel`; later `GateDrumKit`.
- `purerl-tidal/src/Tidal/SessionWalker.purs` (+ `tidal_voice.erl`) — only if the
  compiled path must sample a ValueMap body (open question #2).
- `calypso/frontend/src/Calypso/Frontend/Tarot/Lower.purs` — emit `# gain` from
  StepProfile strength.
- `tarot-music` genres — unchanged; the strength is already there.

## Risks / open questions

1. **Compiled-path params (#2 above)** — the one thing to settle before
   committing to Phase 1's shape. Verify how `play-piece` parts reach dispatch.
2. **`drum` type change** ripples through the `On` class + any `Erase`/`armPart`
   instance; needs a careful but mechanical pass + a full engine build.
3. **`gain` vs `vel` standardisation** — recommend `gain` neutral (0..1), `vel`
   absolute escape hatch. Confirm.
4. **Gate accent representation** (Phase 2) — accent gate vs velocity CV is an
   es9-daemon/rig decision.

## Verification

Compile + play a swung, accented dembow / AfroCuban pattern; confirm velocity
dynamics reach Ableton (drum-rack velocity layers respond) and that an unaccented
genre is unchanged. Phase 0 gives an early read with zero code.
