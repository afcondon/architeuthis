# Slotted literals — deferred optimization plan

**Status: DEFERRED 2026-05-14.** Do not implement now. Revisit after the 100% PureScript code path lands end-to-end and Andrew has spent real performance time with it.

## Why deferred

This optimization solves a problem we don't yet know we have. The architectural bet is that the cue/play model plus a hands-on rig is enough to make musical work feel responsive, even with seconds-scale cue compile latency. The companion bet on `#11 warm-compiler` aims to bring cue compile from ~7s down to ~500ms.

If those two bets hold in practice, slotted literals may add little perceived improvement. If they don't — specifically, if the dominant edit during performance turns out to be mini-notation string content rather than structural change — slotted literals could be the difference between tolerable and good.

We need playing-time evidence before knowing which is true. The plan exists here so that when the question is ripe, the design isn't starting from scratch.

## Reopen criteria

Reopen this when at least one of the following is observed in real use:

- Even with warm-compiler, the cue-per-string-edit cycle feels intrusive enough that Andrew avoids small edits during performance.
- A pattern emerges where most live edits ARE mini-notation content (changing `"bd sn ~ cp"` to `"bd sn hh cp"`), and structural edits (changing `rev (...)` to `every 4 rev (...)`) are rare during performance.
- Andrew finds himself wanting an A/B/C cuing pattern where the only differences are the strings, and pre-cuing all variants feels heavyweight.
- The hands-on rig's expressive bandwidth turns out to be narrower than expected (some rigs, some pieces), pushing more onto code.

Conversely, evidence that this work is NOT needed:

- Warm-compiler brings cue under ~500ms and that feels snappy enough.
- The hands-on rig genuinely carries most moment-to-moment expressivity, and code edits are slower-cadence than originally thought.
- Pre-cuing structural variants becomes a natural performance practice.

The decision belongs to playing experience, not engineering speculation.

## What it would do

Today, a cell like

```purescript
rev (mini "bd sn ~ cp")
```

compiles to a BEAM module where `"bd sn ~ cp"` is a baked-in atom. Changing the string requires a full `cue` recompile cycle (~7s today, ~500ms post-warm-compiler) before the new pattern can be installed.

The slotted-literals variant compiles instead to a module where mini-notation literals are **slot references** into a per-module ETS table. Module load populates the slots with initial values. A new verb `set-mini <module-hash> <slot-id> <new-string>` updates a slot. Subsequent pattern queries see the new string.

No recompile. The voice continues to use the same compiled module. Only the slot value changes.

Latency for a string-only edit drops from "cue compile cost" to "ETS write + re-parse + cache swap" — sub-millisecond.

## Relationship to existing substrate

The live-control bus (`reference_purerl_tidal_live_control_substrate`) is already exactly this pattern for **numeric** values. `live "amp" :: Pattern Number` reads a runtime-mutable number from an ETS row keyed by name; `set-control amp 0.5` writes it. Patterns containing `live "amp"` see the new value at the next clock-tick without recompile.

Slotted literals is the **string-typed** version of the same idea. Implementation can largely mirror the existing live-control wiring:

- Per-module ETS table (vs. global control-bus table — per-module because slot ordinals are module-relative).
- Update verb (`set-mini` or unified `set-slot`).
- Pattern constructor that reads the slot at query time, caches the parsed Pattern, invalidates on slot mutation.

A natural API surface: `liveMini :: Int -> Pattern String` (analogous to `live :: String -> Pattern Number`), with the compile pass auto-rewriting `mini "..."` to `liveMini N` at well-defined positions.

## Design sketch

### The slot mechanism

Each compiled module gets a private ETS table at load time: `slots_M<hash>`. Slot 0 holds the first mini-notation literal in the cell, slot 1 the second, etc. The table also caches the parsed-Pattern form alongside the raw string to avoid re-parsing on every clock query.

```erlang
%% on first module load:
ets:new(slots_M<hash>, [public, named_table, set]),
ets:insert(slots_M<hash>, [
  {0, <<"bd sn ~ cp">>, parse_mini(<<"bd sn ~ cp">>)},
  {1, <<"~ x ~ x">>,    parse_mini(<<"~ x ~ x">>)}
]).

%% on set-mini call:
NewParsed = parse_mini(NewStr),
ets:insert(slots_M<hash>, {SlotId, NewStr, NewParsed}).
```

### The Pattern extension

The Pattern type needs a new constructor that reads slots at query time:

```purescript
data Pattern a
  = ...
  | SlotPat ModuleId SlotId   -- ^ resolves to the parsed Pattern stored at
                              --   ETS(slots_<ModuleId>, SlotId) when queried
```

The voice evaluator handles `SlotPat` by reading the cached parsed-Pattern from ETS and recursing into it. This is the only invasive runtime change; the rest of the Pattern algebra is unchanged.

### The compile pass

The PureScript → Erlang pipeline gains one new pass between corefn and emit:

1. Walk the corefn AST.
2. For every `App (Var "mini") (StringLit s)` (and variants — `s`, `chordPat`, whatever Pattern-parser functions exist), rewrite to `App (Var "liveMini") (IntLit n)` and accumulate the original string `s` at position `n`.
3. Emit a parallel `slot_init_M<hash>/0` function in the module that populates the ETS table with the original strings on first load.

The pass is local and mechanical. The pipeline downstream (purs-backend-erl emit, erlc compile, code:load_file) doesn't change.

**Open: which functions are eligible.** v1 hardcodes a list (`mini`, possibly `s`, `chordPat`, others). A future iteration could mark eligible argument positions at the type level — `mini :: MiniText -> Pattern String` where `MiniText` is a newtype the compiler recognizes — but this is type-level PureScript work that's not v1-essential.

### The fire-time diff

Calypso frontend keeps the last-fired source for each cell. On fire:

1. Parse current and last-fired source as PureScript ASTs.
2. Compare: if the ASTs differ only in string-literal contents at corresponding positions, send `set-mini` for each changed slot. Don't re-cue.
3. Otherwise, fall back to full `cue` + `play-armed`.

PureScript-AST diffing is mechanical. The "only string literals differ" predicate is a structural-equality check that treats string nodes as wildcards.

## Wrinkles

**Pattern query timing.** Patterns are pure values today — given a time arc, produce events. `SlotPat` introduces effectful query (read ETS). The runtime evaluator already runs in a process that can do ETS reads; the change is contained.

**Cache invalidation across voices.** Multiple voices can install the same module (`play-armed bass M<hash>` and `play-armed lead M<hash>`). A slot update affects both. That's almost certainly the desired behaviour, but worth being explicit in the design.

**Initial slot values vs. subsequent updates.** The compiled module carries initial values. If a session has been running and slots have been updated mid-session, then the module is reloaded (e.g., a structural edit triggers a new `cue`), the new module's initial values would clobber the mid-session updates. Resolution: each new compile gets a new hash and a new ETS table. Old module's state is left in place until garbage-collected. The new module starts fresh with the new initial values. That matches what "structural edit" semantically means anyway.

**Set-mini verb naming.** "set-mini" is specific to mini-notation. If the slot system generalizes (numbers, lists, etc.) a unified `set-slot <module-hash> <slot-id> <typed-value>` is cleaner. Decision deferred to implementation time.

## Scope estimate

Roughly a focused week, broken down:

- Per-module slot ETS infrastructure + the new verb: half a day.
- Pattern type extension for `SlotPat` + voice query path: 1–2 days.
- Compile pass that recognizes literal strings and emits slot refs + init function: 1–2 days. This is the most invasive piece.
- Frontend AST diff at fire time: 1 day.
- Integration testing + perf validation: 1–2 days.

Total: ~5–7 working days for a single-language version (mini-notation only). Generalization to other literal kinds adds incremental days per kind.

## What to look at when revisiting

If/when this is reopened, start by reading:

1. **`reference_purerl_tidal_live_control_substrate`** memory pin and the relevant code in `tidal_control_bus.erl`, `Tidal.Pattern.*` for the existing live-control bus. This is the direct precedent.
2. **The cue pipeline in `Handler.erl`** (the `{cue, Body}` arm calling `tidal_compiler:compile_and_load/2`). Understand where in that pipeline the new compile pass would slot in.
3. **The Pattern type in `Tidal.Pattern.Types`** — see how patterns are constructed and queried; the `SlotPat` constructor needs to coexist.
4. **The frontend cell-fire path** at `Shell.purs:782 (FireCell handler)` — that's where the AST diff would intercept.

Bring fresh perspective from playing-time experience. The design above is a sketch; specifics may shift once you know what the actual common-edit patterns are during performance.

## Adjacent ideas (not in scope)

If slotted strings prove valuable, the natural extensions are:

- **Slotted numbers** for things like `slow 2`, `every 4 rev`, `# gain 0.7` — convert numeric literals to slot refs at compile time, allow `set-slot` updates. May be subsumed by the existing live-control bus if users already write `slow (live "speed")` explicitly.
- **Slotted lists** for fan-out specs like `[1, 2, 3]` — useful when the structure stays put but the list contents tweak.
- **Slotted typed values** generally — anything the user might want to tweak without changing the surrounding code shape.

The string case is the highest-leverage starting point because mini-notation IS where most musical content lives.
