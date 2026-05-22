%% @doc Virtual polysignal voice supervisor — `simple_one_for_one`
%% for virtual_selene_voice gen_servers.  Sibling of
%% balistes_voice_sup / odonus_voice_sup / repetitor_voice_sup.  Children
%% start dynamically when the session walker emits
%% `RegisterVirtualSelene` events.
%%
%% Crashes don't restart automatically (`temporary` child spec): a
%% voice dying mid-session is a configuration bug, not something
%% to retry silently.  The next reload-baseline re-spawns whatever
%% was registered.
-module(virtual_selene_voice_sup).
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
    whereis(virtual_selene_voice:registered_name(Name));
lookup_voice(Name) when is_binary(Name) ->
    lookup_voice(binary_to_atom(Name, utf8)).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 5,
                 period => 30},
    ChildSpec = #{id => virtual_selene_voice,
                  start => {virtual_selene_voice, start_link, []},
                  restart => temporary,
                  shutdown => 2000,
                  type => worker,
                  modules => [virtual_selene_voice]},
    {ok, {SupFlags, [ChildSpec]}}.
