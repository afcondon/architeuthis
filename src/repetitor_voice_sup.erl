%% @doc Repetitor voice supervisor — `simple_one_for_one` for
%% repetitor_voice gen_servers.  Sibling of balistes_voice_sup.  Children
%% are started dynamically on session-walker registration of
%% `RegisterRepetitor` events.  Crashes don't restart automatically
%% (`temporary` child spec): a Repetitor voice dying mid-session is a
%% configuration bug, not something to retry silently.
-module(repetitor_voice_sup).
-behaviour(supervisor).

-export([start_link/0,
         start_voice/2,
         stop_voice/1,
         which_voices/0,
         lookup_voice/1]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a Repetitor voice under this supervisor.
start_voice(Name, Config) ->
    case supervisor:start_child(?MODULE, [Name, Config]) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

%% @doc Stop a Repetitor voice by name.  Idempotent.
stop_voice(Name) ->
    case lookup_voice(Name) of
        undefined -> ok;
        Pid -> supervisor:terminate_child(?MODULE, Pid)
    end.

%% @doc List all Pids under this supervisor.  Used by tidal_clock's
%% broadcast_compute_window to fan ticks out to every Repetitor voice.
which_voices() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE),
            is_pid(Pid)].

%% @doc Resolve a Repetitor voice by its registered name.  Returns
%% undefined if no such voice is running.
lookup_voice(Name) when is_atom(Name) ->
    whereis(repetitor_voice:registered_name(Name));
lookup_voice(Name) when is_binary(Name) ->
    lookup_voice(binary_to_atom(Name, utf8)).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 5,
                 period => 30},
    ChildSpec = #{id => repetitor_voice,
                  start => {repetitor_voice, start_link, []},
                  restart => temporary,
                  shutdown => 2000,
                  type => worker,
                  modules => [repetitor_voice]},
    {ok, {SupFlags, [ChildSpec]}}.
