%% @doc Application callback module for purerl_tidal.
%%
%% Entry point for `application:start(purerl_tidal)`. The supervisor
%% returned is currently empty — the per-voice supervision tree is
%% being built up incrementally; existing services (MIDIScheduler, the
%% Cowboy listener) still bare-spawn from Main.purs. As the refactor
%% progresses, those services migrate to being children of
%% `purerl_tidal_sup`.
%%
%% See `docs/per-voice-refactor-plan.md`.
-module(purerl_tidal_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    purerl_tidal_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
