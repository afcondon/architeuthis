%% @doc René voice supervisor — `simple_one_for_one` for rene_voice
%% gen_servers.  Mirror of grids_voice_sup / repetitor_voice_sup.
-module(rene_voice_sup).
-behaviour(supervisor).

-export([start_link/0,
         start_voice/2,
         stop_voice/1,
         which_voices/0,
         lookup_voice/1]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_voice(Name, Config) ->
    case supervisor:start_child(?MODULE, [Name, Config]) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

stop_voice(Name) ->
    case lookup_voice(Name) of
        undefined -> ok;
        Pid -> supervisor:terminate_child(?MODULE, Pid)
    end.

which_voices() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE),
            is_pid(Pid)].

lookup_voice(Name) when is_atom(Name) ->
    whereis(rene_voice:registered_name(Name));
lookup_voice(Name) when is_binary(Name) ->
    lookup_voice(binary_to_atom(Name, utf8)).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 5,
                 period => 30},
    ChildSpec = #{id => rene_voice,
                  start => {rene_voice, start_link, []},
                  restart => temporary,
                  shutdown => 2000,
                  type => worker,
                  modules => [rene_voice]},
    {ok, {SupFlags, [ChildSpec]}}.
