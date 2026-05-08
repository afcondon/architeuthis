%% @doc Voice supervisor — `simple_one_for_one` dynamic supervisor for
%% per-voice gen_servers.
%%
%% A single child template (the voice); voices are added at runtime by
%% the WS handler's `bind` verb via `tidal_voice_sup:add_voice/2`.
%%
%% Restart strategy: `transient` per voice — a normal exit (e.g. unbind)
%% does not trigger restart; a crash does. Restart intensity is generous
%% (10/60s) because pathological patterns can crash a voice repeatedly
%% as the user iterates; we don't want intensity-exceeded shutting down
%% the whole supervisor for what's effectively user error.
%%
%% See `docs/per-voice-refactor-plan.md` §3.
-module(tidal_voice_sup).
-behaviour(supervisor).

-export([start_link/0,
         add_voice/2,
         add_voice_cont/2,
         set_voice/4,
         set_voice_pat/3,
         set_voice_cont_pat/3,
         remove_voice/1,
         find_voice/1,
         which_voices/0,
         hush_all/0]).
-export([init/1]).

%% =========================================================================
%% Public API
%% =========================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Add a new Discrete voice. Returns {ok, Pid} on success.
%% Idempotent: re-adding an existing name returns the original Pid.
add_voice(Name, Binding) ->
    case supervisor:start_child(?MODULE, [Name, {discrete, Binding}]) of
        {error, {already_started, Pid}} -> {ok, Pid};
        Other -> Other
    end.

%% Add a new Continuous voice. Returns {ok, Pid} on success.
%% Idempotent: re-adding an existing name returns the original Pid.
%% Dest is a `Tidal.Binding.ContDest` term — the supervisor passes it
%% through to tidal_voice:start_link as `{continuous, Dest}`.
add_voice_cont(Name, Dest) ->
    case supervisor:start_child(?MODULE, [Name, {continuous, Dest}]) of
        {error, {already_started, Pid}} -> {ok, Pid};
        Other -> Other
    end.

%% Upsert a voice's pattern + params. The semantic mirrors what
%% MIDIScheduler.PlayByName does today: if the voice exists, replace
%% its pattern + params (preserving phase + binding); if not, create
%% with the given binding then install.
%%
%% Phase preservation matches Tidal-compat: re-issuing `play name "x"`
%% doesn't reset cycle position. Users who want a barline reset use
%% `unbind` then `bind` then play again.
%%
%% Binding refresh: existing voices keep their original binding even
%% if the registry has been updated since voice creation. This matches
%% MIDIScheduler's BoundTrack behaviour (BoundTracks snapshot binding
%% at install time). Re-bind + re-play creates a fresh voice with the
%% new binding only if the existing voice was unbound first.
%%
%% Returns:
%%   ok                 — pattern installed
%%   {error, Reason}    — pattern parse error (the voice still exists
%%                        but its previous pattern is unchanged)
set_voice(Name, Binding, PatStr, ParamSpecs) ->
    case find_voice(Name) of
        not_found ->
            case add_voice(Name, Binding) of
                {ok, _Pid} ->
                    tidal_voice:install_from_spec(Name, PatStr, ParamSpecs);
                Err ->
                    Err
            end;
        {ok, _Pid} ->
            tidal_voice:install_from_spec(Name, PatStr, ParamSpecs)
    end.

%% Sister of set_voice/4 that takes an already-parsed Pattern (the
%% PureScript `Pattern String` value) instead of a source string.
%% Used by the PlayByNameExpr migration: the WS handler evaluates the
%% expression via Tidal.Expr first, so by the time it calls into the
%% voice tree the Pattern is already typed. No param specs — the
%% colon-expr form doesn't currently support `#` joins.
set_voice_pat(Name, Binding, Pattern) ->
    case find_voice(Name) of
        not_found ->
            case add_voice(Name, Binding) of
                {ok, _Pid} ->
                    tidal_voice:set_pattern(Name, Pattern);
                Err ->
                    Err
            end;
        {ok, _Pid} ->
            tidal_voice:set_pattern(Name, Pattern)
    end.

%% Continuous-voice analogue of set_voice_pat/3. Pattern is a
%% `Pattern Number` (the result of Tidal.Expr.parseEvalNumPattern);
%% Dest is a `Tidal.Binding.ContDest`. Upserts: creates a Continuous
%% voice if absent, otherwise just replaces the pattern. Phase
%% preserved, mute preserved.
%%
%% No param specs — continuous voices don't carry `#`-join params
%% (they evaluate a single Pattern Number per tick). The destination
%% is captured at create-time, mirroring how Discrete voices snapshot
%% their Binding.
set_voice_cont_pat(Name, Dest, Pattern) ->
    case find_voice(Name) of
        not_found ->
            case add_voice_cont(Name, Dest) of
                {ok, _Pid} ->
                    tidal_voice:set_continuous_pattern(Name, Pattern);
                Err ->
                    Err
            end;
        {ok, _Pid} ->
            tidal_voice:set_continuous_pattern(Name, Pattern)
    end.

%% Remove a voice by name. Idempotent: missing voices return ok.
remove_voice(Name) ->
    case find_voice(Name) of
        {ok, Pid} ->
            supervisor:terminate_child(?MODULE, Pid);
        not_found ->
            ok
    end.

%% Look up a voice by its bound name. Resolves through the registered-name
%% atom; doesn't pay the cost of walking the supervisor's child list.
find_voice(Name) ->
    case whereis(tidal_voice:registered_name(Name)) of
        undefined -> not_found;
        Pid -> {ok, Pid}
    end.

%% List currently-running voice pids. Used by the clock for tick fanout.
which_voices() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE),
            is_pid(Pid)].

%% Tidal-compat hush: clear every voice's pattern. Voices stay alive
%% (pids preserved, binding preserved, phase keeps advancing) but
%% computeUntil produces no events so nothing reaches the dispatcher.
%% A subsequent re-fire installs a fresh pattern and the voice picks
%% up at the current cycle position — same as MIDIScheduler.Hush
%% which dropped tracks (re-fires recompute from current elapsedMs).
%%
%% Calls clear_pattern directly on each pid (via gen_server:call with
%% the pid rather than the registered name) — saves the round-trip
%% through whereis when we already have the pid list.
hush_all() ->
    [gen_server:call(Pid, clear_pattern) || Pid <- which_voices()],
    ok.

%% =========================================================================
%% supervisor callback
%% =========================================================================

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 10,
                 period => 60},
    ChildSpec =
        #{id => tidal_voice,
          start => {tidal_voice, start_link, []},
          restart => transient,
          shutdown => 5000,
          type => worker,
          modules => [tidal_voice]},
    {ok, {SupFlags, [ChildSpec]}}.
