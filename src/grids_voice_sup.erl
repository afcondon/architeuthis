%% @doc Grids voice supervisor — `simple_one_for_one` for grids_voice
%% gen_servers.  Sibling of tidal_voice_sup.  Children are started
%% dynamically on session walker registration of `RegisterGrids` events.
%%
%% Crashes don't restart automatically (`temporary` child spec): a
%% Grids voice dying mid-session is a configuration bug, not something
%% to retry silently.  The next reload-baseline re-spawns whatever was
%% registered.
-module(grids_voice_sup).
-behaviour(supervisor).

-export([start_link/0,
         start_voice/2,
         stop_voice/1,
         which_voices/0,
         lookup_voice/1]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a Grids voice under this supervisor.  Returns the Pid.
%% Config map: see grids_voice:init/1 for the keys.
start_voice(Name, Config) ->
    case supervisor:start_child(?MODULE, [Name, Config]) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

%% @doc Stop a Grids voice by name.  Idempotent.
stop_voice(Name) ->
    case lookup_voice(Name) of
        undefined -> ok;
        Pid -> supervisor:terminate_child(?MODULE, Pid)
    end.

%% @doc List all Pids under this supervisor.  Used by tidal_clock's
%% broadcast_compute_window to fan ticks out to every Grids voice.
which_voices() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE),
            is_pid(Pid)].

%% @doc Resolve a Grids voice by its registered name.  Returns
%% undefined if no such voice is running.
lookup_voice(Name) when is_atom(Name) ->
    whereis(Name);
lookup_voice(Name) when is_binary(Name) ->
    lookup_voice(binary_to_atom(Name, utf8)).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 5,
                 period => 30},
    ChildSpec = #{id => grids_voice,
                  start => {grids_voice, start_link, []},
                  restart => temporary,
                  shutdown => 2000,
                  type => worker,
                  modules => [grids_voice]},
    {ok, {SupFlags, [ChildSpec]}}.
