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
         remove_voice/1,
         find_voice/1,
         which_voices/0]).
-export([init/1]).

%% =========================================================================
%% Public API
%% =========================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Add a new voice. Returns {ok, Pid} on success.
%% Idempotent: re-adding an existing name returns the original Pid.
add_voice(Name, Binding) ->
    case supervisor:start_child(?MODULE, [Name, Binding]) of
        {error, {already_started, Pid}} -> {ok, Pid};
        Other -> Other
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
