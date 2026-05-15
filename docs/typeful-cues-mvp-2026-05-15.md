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

## Next

- **Phase 1 wrap-up**: extend Calypso.Prelude with the remaining
  binding kinds (Cv, Gate, MidiCc) and polysignal/control/tag
  primitives. The shape is established; the rest is additive.
- **Phase 2**: build the daemon-side wrapper synthesis logic
  (write `session/Voices/Qd1.purs` from session AST).
- **Phase 3**: voice gen_server hot-load wiring.
- **Phase 4+**: Calypso frontend integration.

See `calypso/docs/typeful-cues-plan-2026-05-15.md` for the full
phased plan.
