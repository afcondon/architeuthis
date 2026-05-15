# Typeful cues — MVP findings on the real purerl-tidal codebase (2026-05-15)

The synthetic `purerl-leaf-edit-benchmark` predicted ~0.6s per cue
edit. This is what the real purerl-tidal codebase gives us after
adding `Calypso.Prelude` and a hand-written test session.

## What was built

- `src/Calypso/Prelude.purs` — MVP DSL: MidiDevice, MidiNote,
  Binding, Cue (mvoice :: Symbol), Session. Re-exports
  Tidal.Cell.Prelude (Pattern, mini, every, rev, fast, slow, …).
- `src/Calypso/Generated/Session.purs` — hand-written test
  session in the new typeful form.

## Measured timings

| Scenario                                                  | Time   |
|-----------------------------------------------------------|--------|
| Cold full build                                           | ~6s    |
| Warm no-op                                                | ~1.3s  |
| Edit one cue body, full `spago build`                     | ~6s    |
| Edit one cue body, `rm build.txt && backend-erl --filter` | ~2.5s  |

`--filter Calypso.Generated.Session` pulls in 149 modules
(transitive closure: Session → Calypso.Prelude → Tidal.Cell.Prelude
→ Tidal.Pattern.* → Prelude.* → …). Each takes ~17ms to emit; the
149-module emit dominates.

## How this differs from the benchmark

The synthetic benchmark used **trivial leaves** that imported
only a tiny Baseline + Prelude (33-module closure). The real
purerl-tidal codebase has a rich pattern infrastructure that
every cue body depends on transitively, so the filter scope
necessarily includes all of it.

Per-edit cost scales with the **dependency closure** of the
edited module, not the size of the project as a whole.

## Verdict for typeful-cues

**Viable for cue/play live coding.** ~2.5s per cue edit is at
the upper edge of comfort for live performance, but workable.
For composition-pane editing without firing (typing without
compilation), there's no recompile cost at all.

Tighter latencies are available with further investment:

1. **Daemonise backend-erl** (task #20, deferred): keep the
   process warm with parsed corefns in RAM; only emit the
   one module whose corefn changed. Estimated <0.5s if achievable.
2. **Multi-package spago workspace**: split user-mutable session
   into its own package depending on a pre-built purerl-tidal.
   spago might skip recompiling the upstream package entirely.
   Estimated <0.5s if achievable.
3. **Patch backend-erl** for content-hash-based emit skipping:
   if a module's corefn hash hasn't changed, don't re-emit its
   .erl. The deep clean shoot.

For Phase 1 of the typeful-cues plan, **accept ~2.5s** and proceed
to wrapper synthesis and BEAM hot-load wiring. Optimisation work
(any of 1-3 above) becomes a focused follow-up once the
architecture is proven end-to-end.

## Files

- `src/Calypso/Prelude.purs` — the DSL surface
- `src/Calypso/Generated/Session.purs` — hand-written test session

## Voice wrapper validation

`src/Calypso/Voices/Qd1.purs` is the prototype voice wrapper.
One declaration:

```purescript
module Calypso.Voices.Qd1 where
import Calypso.Generated.Session (qd1A)
import Calypso.Prelude (Cue)

armed :: Cue "drums"
armed = qd1A
```

Generated `.erl` is also one declaration:

```erlang
-module(calypso_voices_qd1@ps).
-export([armed/0]).
armed() -> calypso_generated_session@ps:qd1A().
```

The voice gen_server calls `calypso_voices_qd1@ps:armed/0` to get
the cue. To switch from qd1A to qd1B, the daemon rewrites this
file with `qd1B` instead. Scoped emit + hot-load: voice's pattern
swaps on next cycle boundary.

### Arm-switch cycle measured

- Edit wrapper `qd1A → qd1B`
- `purs compile` (incremental) + `rm build.txt && backend-erl --filter Calypso.Voices.Qd1`: **2.5s**
- Content-hash gate + `erlc` one .beam: **0.18s**
- `code:load_binary` + first call: **<2ms**
- **Total per arm-switch: ~2.7s**

Bypassing spago (direct `purs compile` + direct `purs-backend-erl`)
gives the same timing. spago doesn't add overhead on the hot path;
the cost is in backend-erl's emit of the 149-module closure.

## End-to-end BEAM load confirmed

The Session value loads in BEAM as expected. `session/0` returns
a map with `bindings`, `devices`, `cues` fields — `bindings` is
an Erlang array of `{bMidiNote, #{...}}` tagged tuples; `cues` is
an array of `{anyCue, #{body, destination, mvoice}}` tuples with
mvoice reflected to a binary string. Body is a `#Fun<...>` ref
into the pattern infrastructure. This is exactly what
purerl-tidal's runtime would walk at baseline-load time.

## Next

- **Phase 1 wrap-up**: extend Calypso.Prelude with the remaining
  binding kinds (Cv, Gate, MidiCc) and polysignal/control/tag
  primitives. The shape is established; the rest is additive.
- **Phase 2 next**: build the daemon-side orchestrator script.
  Input: session source + target tvoice. Output: .beam binaries
  ready to ship over WS. The mechanics are proven; this is
  packaging.
- **Phase 3**: voice gen_server hot-load wiring (`{:swap_pattern,
  Module}` message; capture fun-ref on each swap).
- **Phase 4+**: Calypso frontend integration.

See `calypso/docs/typeful-cues-plan-2026-05-15.md` for the full
phased plan.
