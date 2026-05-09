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
    %% Hash cache.  If the .beam already exists AND is loadable we
    %% skip the whole pipeline.  We don't trust a previous load alone
    %% (`code:is_loaded/1`) — across BEAM restarts the loaded table
    %% is empty but the .beam on disk is still good — so we always
    %% try `code:load_file/1` if the file is there.  load_file is
    %% idempotent on an already-loaded module.
    case filelib:is_regular("ebin/" ++ atom_to_list(ErlAtom) ++ ".beam") of
        true ->
            case code:load_file(ErlAtom) of
                {module, M}    -> {ok, M};
                {error, LoadE} -> {error, {load, LoadE}}
            end;
        false ->
            do_compile(PursPath, PursModule, Source, ErlPath, ErlAtom)
    end.

do_compile(PursPath, PursModule, Source, ErlPath, ErlAtom) ->
    ok = filelib:ensure_dir(PursPath),
    case write_purs(PursPath, PursModule, Source) of
        {error, R} ->
            {error, {write, R}};
        ok ->
            case run("spago", ["build"]) of
                {error, R1} ->
                    {error, {spago, R1}};
                ok ->
                    case run("erlc", ["-disable-feature", "maybe_expr",
                                      "-o", "ebin", ErlPath]) of
                        {error, R2} ->
                            {error, {erlc, R2}};
                        ok ->
                            case code:load_file(ErlAtom) of
                                {module, M}    -> {ok, M};
                                {error, LoadE} -> {error, {load, LoadE}}
                            end
                    end
            end
    end.

%% =========================================================================
%% Internal
%% =========================================================================

%% Render the cell body into the fixed cell template.  A cell exports
%% `pattern :: Pattern String` — that's the whole contract.  Callers
%% wanting richer types provide the `pure ...` / combinator expression
%% inside Source.
%%
%% NOTE: imports are intentionally minimal — Prelude (for `pure`) and
%% Tidal.Pattern.Types (for the `Pattern` type).  When richer cell
%% bodies need more imports, the template grows; or the body itself
%% can include qualified references like `Tidal.Pattern.Core.fastCat`.
write_purs(Path, ModName, Body) ->
    Content = iolist_to_binary([
        "-- Generated by tidal_compiler.  Do not edit by hand.\n",
        "module ", ModName, " where\n\n",
        "import Prelude\n",
        "import Tidal.Pattern.Types (Pattern)\n",
        "\n",
        "pattern :: Pattern String\n",
        "pattern = ", Body, "\n"
    ]),
    file:write_file(Path, Content).

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
