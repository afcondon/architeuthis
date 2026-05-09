# Per-cell compilation + hot-load — PR1 plan

Status: spike in progress on branch `per-cell-compile` (started 2026-05-09).
Goal: replace the mini-notation interpreter as the path from cell text to
voice pattern with a compile-then-hot-load pipeline that turns each cell
into a generated PureScript module, compiles it through purs-backend-erl
to a `.beam`, and installs the resulting `Pattern String` value into the
voice gen_server.

Once landed end-to-end, the pre-condition for "cells are real PureScript"
is met: anything a `.purs` file can express becomes a legal cell body.

## Decisions made

- **Cell exports** `pattern :: Pattern String` (Option A from the
  brainstorm). Cells become `Voice -> Voice` transformers later if
  needed; today the install path is `setPattern` verbatim.
- **Module naming**: hash-based. `Tidal.Generated.M_<sha256-prefix>`.
  Cache key is the canonicalized source. Same source on different cells
  → same module → no recompile.
- **Compile strategy** (v0): per-shot bare `purs compile` against the
  pre-warm `output/`, then `purs-backend-erl`, then `erlc`. No long-
  running daemon yet. Andrew's preference is to skip `spago build` even
  for v0 because spago's per-invocation overhead is real (500ms-ish) and
  unnecessary once the project has been built once.
- **Cue vs Play** (frontend semantics, deferred to PR3):
  - **Cue** triggers compile + typecheck. Reply carries `{armed, Module}`
    or `{compileError, ...}`. On success, the cell becomes "armed".
  - **Play** is grayed out until the cell has an armed module. Pressing
    it installs the armed module's pattern into the voice (via the
    voice gen_server's existing `setPattern` path, but receiving the
    value from the loaded module instead of the parser).
- **Errors** flow through the existing per-cell `cellResults` reply
  path. Modal already renders them — we just need the backend to
  return structured error text.

## Out of scope for PR1

- WebSocket verb routing (PR2)
- Frontend Cue/Play distinction + arm tracking (PR3)
- `purs ide` daemon for compile speed (PR4)
- Cycle-boundary-armed swap on the clock (PR4 or later)

PR1 is a backend-only spike. By the end of PR1 we should be able to
start an `erl` shell and:

```erlang
{ok, Mod} = tidal_compiler:compile_and_load(<<"pure \"bd\"">>, <<"abc123">>).
P = ('tidal_generated_m_abc123@ps':pattern())().
%% P is a Pattern String value; can be queried directly.
```

That is the success criterion for PR1.

## PR1 sub-steps

### 1. Recon — DONE

- `Pattern String` is the discrete voice's pattern type, exported from
  `Tidal.Pattern.Types`.
- `Tidal.Voice.setPattern :: Pattern String -> State -> State` is the
  install API. Already wired through the `tidal_voice` gen_server.
- Erlang module-name encoding for purs-backend-erl: PureScript module
  `Tidal.Generated.M_xxx` becomes Erlang atom `'tidal_generated_m_xxx@ps'`.
  Functions become 0-arg getters returning the Erlang representation
  of the value.

### 2. Hand-write a Tidal.Generated.M_test cell

Goal: prove the template type-checks and produces a usable
`Pattern String` value before automating any of the pipeline.

Template (sketch — refine during step 2):

```purescript
module Tidal.Generated.M_test where

import Prelude

import Tidal.Pattern.Types (Pattern)
import Tidal.Pattern.Core as P

pattern :: Pattern String
pattern = P.pure "bd"
```

Acceptance:
- `make` (or `make ps && make erl`) builds without errors.
- `output-erl/Tidal.Generated.M_test/tidal_generated_m_test@ps.erl`
  exists.
- `ebin/tidal_generated_m_test@ps.beam` exists.

### 3. Manual purs → purs-backend-erl → erlc walkthrough — DONE

Walked the full pipeline by hand on `src/Tidal/Generated/Mtest.purs`
(`pattern = pure "bd2"`).  The pipeline rounds-trips: the .beam
loads, `pattern/0` returns the expected `Pattern String` closure.

#### Surprises

- **PureScript module names disallow underscores.**  `Tidal.Generated.M_test`
  fails with "Invalid module name; underscores and primes are not
  allowed in module names".  Hash-based module names must use
  hex-only `[A-Fa-f0-9]+` after a leading uppercase prefix:
  `Tidal.Generated.M<hexhash>`.

- **purs-backend-erl rewalks all modules on any corefn change.**  A
  one-line edit to a leaf cell module triggers a 7-second rebuild
  even though purs itself only recompiles the one changed module.
  `[N of 371] Building <every module>` shows on every rebuild.
  This is the dominant cost in the pipeline and rules out the
  per-shot strategy for live use; the daemon path (PR4) becomes a
  hard requirement for the type-and-fire workflow, not just a
  speed optimization.

- **Voice's `pattern` field has 0-arg + 1-arg generated forms.**
  purs-backend-erl emits both `pattern/0` (returns the curried
  Pattern closure) and `pattern/1` (an uncurried specialization
  that takes a query state directly).  The voice install path uses
  `pattern/0`.

#### Measured timings (cold MBP, post-rename baseline)

| step | command | time |
|---|---|---|
| spago build, no-op | `spago build` (no source changes) | ~1.3s |
| spago build, leaf-module change | `spago build` after editing Mtest's body | ~7.0s |
| erlc one .erl alone | `erlc -disable-feature maybe_expr -o ebin output-erl/Tidal.Generated.Mtest/*.erl` | ~0.26s |
| `erl -noshell` load + invoke | fresh shell → `code:load_file` → call `pattern/0` | sub-100ms |

The 7s figure is the bottleneck.  PR1's compiler will accept it as
the v0 cost; PR4 must drop it.

#### Confirmed Erlang invocation shape

Module name: `tidal_generated_mtest@ps`.

```
%% From a fresh erl shell with -pa ebin:
code:load_file('tidal_generated_mtest@ps').
%%   {module, 'tidal_generated_mtest@ps'}

'tidal_generated_mtest@ps':pattern().
%%   #Fun<tidal_pattern_types@ps.95.69950188>
%%   (the Pattern closure inside the Pattern newtype)
```

### 4. tidal_compiler.erl — DONE

`src/tidal_compiler.erl` exports `compile_and_load(Source, Hash) ->
{ok, Module} | {error, {Stage, Detail}}`.  Stages:

- `write` — failed to write the generated `.purs` (filesystem error)
- `spago` — `spago build` failed; Detail is `{ExitCode, Output}` with
  the captured stderr+stdout binary (purs error report verbatim)
- `erlc` — `erlc` failed on the generated `.erl`; same shape as spago
- `load` — `code:load_file/1` failed (rare; usually means corruption)

Generated cell location: `src/Tidal/Generated/M<Hash>.purs`.
Spago picks them up via the existing `src/**/*.purs` glob, no
config change needed.  Hash-named generated files are gitignored;
a hand-curated `Mtest.purs` stays as a reference template.

### 5. Hash cache — DONE

Cache check is the first thing `compile_and_load/2` does: if
`ebin/<module>.beam` exists, just call `code:load_file/1` (idempotent
on already-loaded modules) and return.  Skips the whole pipeline.

Across BEAM restarts the on-disk `.beam` survives but the loaded
table doesn't, so we don't gate on `code:is_loaded/1` — `load_file/1`
is cheap and correct in both cases.

#### Measured cache effectiveness

| scenario | time |
|---|---|
| cold compile, new hash | ~7.6s |
| cache hit, .beam on disk, fresh BEAM | ~1.15s (mostly `erl` startup) |
| cache hit, inside running BEAM | sub-millisecond (just the `code:load_file/1`) |

### 6. Commit + capture — DONE

Branch: `per-cell-compile`.  Files:

- `src/tidal_compiler.erl` — the pipeline runner
- `src/Tidal/Generated/Mtest.purs` — reference template (committed)
- `src/Tidal/Generated/M<hash>.purs` — generated, gitignored
- `Makefile` — adds `tidal_compiler.erl` to the explicit erlc list
- `.gitignore` — excludes hash-named generated cells
- `docs/per-cell-compile-plan.md` — this doc

## Future PR backlog (context only)

- **PR2** — WS verb `cue <cellId> <source>`, voice
  `install_compiled_module(Voice, Module)` that stores the loaded
  module's `pattern` value into the voice's State.
- **PR3** — Frontend Cue/Play distinction, armed-module tracking,
  Play disabled until armed.
- **PR4** — Switch the per-shot `purs compile` to a `purs ide`
  daemon. Drop typical compile latency to 100-300ms. Needed for the
  100-200ms type-and-fire workflow.
- **PR5+** — Cycle-boundary arming via clock; export contract grows
  from `Pattern String` to richer shapes.
