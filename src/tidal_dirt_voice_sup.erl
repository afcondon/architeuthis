%% @doc Supervisor for the Tidal streams `d1`..`d16` (tidal_dirt_voice).
%%
%% A stream is started the first time a pattern is sent to it and then kept:
%% Tidal's `hush` silences the streams rather than removing them, as GHCi
%% does. tidal_clock broadcasts each window to `which_voices/0`.
-module(tidal_dirt_voice_sup).
-behaviour(supervisor).

-export([start_link/0, set/2, hush_all/0, which_voices/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Play Pattern on stream N, starting the stream if it is new.
set(N, Pattern) ->
    case whereis(tidal_dirt_voice:registered_name(N)) of
        undefined ->
            case supervisor:start_child(?MODULE, [N]) of
                {ok, _} -> tidal_dirt_voice:set_pattern(N, Pattern);
                {error, {already_started, _}} -> tidal_dirt_voice:set_pattern(N, Pattern);
                Err -> Err
            end;
        _ ->
            tidal_dirt_voice:set_pattern(N, Pattern)
    end.

%% Tidal's hush: every stream to silence.
hush_all() ->
    Silence = 'tidal_pattern_types@ps':silence(),
    [gen_server:call(Pid, {set_pattern, Silence}) || Pid <- which_voices()],
    ok.

which_voices() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE), is_pid(Pid)].

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 60},
    ChildSpec = #{id => tidal_dirt_voice,
                  start => {tidal_dirt_voice, start_link, []},
                  restart => transient,
                  shutdown => 5000,
                  type => worker,
                  modules => [tidal_dirt_voice]},
    {ok, {SupFlags, [ChildSpec]}}.
