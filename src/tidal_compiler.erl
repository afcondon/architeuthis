%% @doc Per-cell PureScript compile + hot-load pipeline (PR1 spike).
%%
%% Public API: `compile_and_load(Source, Hash)` writes a generated
%% `Tidal.Generated.M<Hash>.purs` file from a fixed template, runs
%% `spago build` (which chains purs-backend-erl), then `erlc` on the
%% resulting `.erl`, then `code:load_file/1` on the new module.
%% Returns `{ok, ModuleAtom}` or `{error, {Stage, Detail}}`.
%%
%% v0 limitations (acceptable for PR1, fixed in later PRs):
%%   - Hash is provided by the caller (callers will use a SHA-256
%%     prefix; we don't hash here so this stays a pure pipeline runner).
%%   - Per-shot spago build — every cell change triggers a full
%%     purs-backend-erl re-emit cycle (~7s).  PR4 replaces this with
%%     a long-running daemon path (purs ide or similar).
%%   - Generated files live in the main `src/` tree alongside hand-
%%     authored modules; later we'll move them to `generated/src/`
%%     with a separate spago source glob.
%%   - Working directory must be the project root (cwd = the
%%     directory containing `spago.yaml`).  Same convention as
%%     `make run`.
%%
%% See `docs/per-cell-compile-plan.md`.
-module(tidal_compiler).

-export([compile_and_load/2]).

%% =========================================================================
%% Public API
%% =========================================================================

%% Compile a cell and hot-load the resulting .beam.
%%
%% Source: cell body — the right-hand-side of the generated module's
%%   `pattern` binding.  PureScript syntax.  E.g. `<<"pure \"bd\"">>`
%%   produces a Pattern containing the constant string "bd".
%%
%% Hash: hex-only suffix `[a-fA-F0-9]+` used to make the module name
%%   unique and cache-stable.  PureScript module names disallow
%%   underscores and primes; the caller must supply a hex-clean hash.
%%
%% Returns `{ok, Module}` where Module is the loaded atom (e.g.
%% `tidal_generated_mabc123@ps`), or `{error, {Stage, Detail}}` where
%% Stage is one of `write`, `spago`, `erlc`, `load`.
compile_and_load(Source, Hash) when is_binary(Source) ->
    compile_and_load(binary_to_list(Source), Hash);
compile_and_load(Source, Hash) when is_binary(Hash) ->
    compile_and_load(Source, binary_to_list(Hash));
compile_and_load(Source, Hash) when is_list(Source), is_list(Hash) ->
    PursModule = "Tidal.Generated.M" ++ Hash,
    ErlAtom    = list_to_atom("tidal_generated_m" ++ Hash ++ "@ps"),
    PursDir    = "src/Tidal/Generated",
    PursPath   = PursDir ++ "/M" ++ Hash ++ ".purs",
    %% purs-backend-erl writes to output-erl/<PursModule>/<atom>.erl.
    ErlPath    = "output-erl/" ++ PursModule ++ "/tidal_generated_m"
                 ++ Hash ++ "@ps.erl",
    %% Hash cache.  Three states:
    %%
    %%   1. Module already loaded → return immediately.  Skipping the
    %%      load also avoids Erlang's "old/current" version slot
    %%      mechanic: load_file demotes current to old, and a third
    %%      load with old still occupied returns `not_purged`.
    %%   2. .beam on disk but not loaded (e.g. across BEAM restarts)
    %%      → `code:load_file/1` is enough; no compile, no purge.
    %%   3. Neither on disk nor loaded → full compile pipeline.
    case code:is_loaded(ErlAtom) of
        {file, _} ->
            {ok, ErlAtom};
        false ->
            case filelib:is_regular("ebin/" ++ atom_to_list(ErlAtom)
                                    ++ ".beam") of
                true ->
                    safe_load(ErlAtom);
                false ->
                    do_compile(PursPath, PursModule, Source,
                               ErlPath, ErlAtom)
            end
    end.

do_compile(PursPath, PursModule, Source, ErlPath, ErlAtom) ->
    ok = filelib:ensure_dir(PursPath),
    %% Sweep stale generated .purs sources before each build.  spago
    %% walks the whole src/ tree, so any leftover broken .purs from a
    %% prior failed cue (e.g. a typo or compile error) breaks every
    %% subsequent cue.  Once a module is successfully cued its .purs
    %% is no longer needed — the .beam in ebin/ is the cache.
    sweep_stale_generated(PursPath),
    case write_purs(PursPath, PursModule, Source) of
        {error, R} ->
            {error, {write, R}};
        ok ->
            case run("spago", ["build"]) of
                {error, R1} ->
                    %% Compile failed — drop the .purs we wrote so it
                    %% doesn't poison the next cue (same reason as
                    %% sweep above, applied to the current attempt).
                    file:delete(PursPath),
                    {error, {spago, R1}};
                ok ->
                    case run("erlc", ["-disable-feature", "maybe_expr",
                                      "-o", "ebin", ErlPath]) of
                        {error, R2} ->
                            file:delete(PursPath),
                            {error, {erlc, R2}};
                        ok ->
                            safe_load(ErlAtom)
                    end
            end
    end.

%% =========================================================================
%% Internal
%% =========================================================================

%% Render the cell body into the fixed cell template.
%%
%% PR2 integrated-test phase: cells export `result :: Int`.  Bodies
%% like `2 + 2` round-trip through compile + hot-load + invoke and we
%% can verify "the pipeline works" without conflating it with the
%% Tidal pattern surface.  Once the round-trip is proven end-to-end
%% from the modal, PR3 flips the template back to
%% `pattern :: Pattern String` and wires voice install.
write_purs(Path, ModName, Body) ->
    Content = iolist_to_binary([
        "-- Generated by tidal_compiler.  Do not edit by hand.\n",
        "module ", ModName, " where\n\n",
        "import Prelude\n",
        "\n",
        "result :: Int\n",
        "result = ", Body, "\n"
    ]),
    file:write_file(Path, Content).

%% Delete every M<hex>.purs in src/Tidal/Generated/ EXCEPT Mtest.purs
%% (reference template, hand-curated) and the path we're about to
%% write.  Successfully-cued modules don't need their .purs source
%% anymore — the cache for those lives in ebin/<module>.beam.
sweep_stale_generated(KeepPath) ->
    Dir = "src/Tidal/Generated",
    KeepBase = filename:basename(KeepPath),
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(
              fun(F) ->
                  case should_sweep(F, KeepBase) of
                      true  -> file:delete(filename:join(Dir, F));
                      false -> ok
                  end
              end, Files);
        _ -> ok
    end.

%% Sweep iff: ends in .purs, starts with M followed by a hex digit,
%% and isn't the file we're about to write.  Mtest.purs (alphabetic)
%% and any non-M-prefixed file are preserved.
should_sweep(Filename, Keep) when Filename =:= Keep ->
    false;
should_sweep("Mtest.purs", _) ->
    false;
should_sweep(Filename, _) ->
    case Filename of
        [$M, C | _] when (C >= $0 andalso C =< $9) orelse
                         (C >= $a andalso C =< $f) ->
            filename:extension(Filename) =:= ".purs";
        _ -> false
    end.

%% Load a (possibly already-loaded) module.  Erlang keeps two slots
%% per module — `current` and `old`.  Each `code:load_file/1` demotes
%% current → old; a third load with old still occupied fails with
%% `not_purged`.  Purge before loading to keep the version pipeline
%% always-clear.  `code:soft_purge/1` is no-op if there's nothing to
%% purge and refuses to purge if a process is running old code; in
%% that rare case we fall back to forced `code:purge/1` (kills the
%% offending processes — fine for live-coding cells where nothing
%% should be running ephemeral cell code).
safe_load(Module) ->
    code:soft_purge(Module),
    case code:load_file(Module) of
        {module, M} ->
            {ok, M};
        {error, not_purged} ->
            code:purge(Module),
            case code:load_file(Module) of
                {module, M}    -> {ok, M};
                {error, LoadE} -> {error, {load, LoadE}}
            end;
        {error, LoadE} ->
            {error, {load, LoadE}}
    end.

%% Run an external command, capturing stderr-merged-with-stdout.
%% Returns `ok` on exit 0, `{error, {ExitCode, Output}}` otherwise.
%%
%% open_port with exit_status gives us a clean success/failure signal
%% — os:cmd would lose the exit code.  We collect output in reverse
%% then iolist-flatten on completion.
run(Cmd, Args) ->
    case os:find_executable(Cmd) of
        false -> {error, {executable_not_found, Cmd}};
        Path ->
            Port = open_port({spawn_executable, Path},
                             [{args, Args},
                              stderr_to_stdout,
                              exit_status,
                              binary]),
            collect(Port, [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, D}} ->
            collect(Port, [D | Acc]);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, N}} ->
            {error, {N, iolist_to_binary(lists:reverse(Acc))}}
    end.
