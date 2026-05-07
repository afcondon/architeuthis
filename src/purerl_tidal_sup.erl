%% @doc Top-level supervisor for purerl_tidal.
%%
%% Strategy is `one_for_all` because the children are tightly coupled:
%% if any of {clock, voice_sup, dispatcher, link_bridge} crashes hard
%% enough to exceed restart intensity, the whole rig should reset
%% rather than run with partial state.
%%
%% Children list is currently empty — services migrate in over the
%% course of the refactor. See `docs/per-voice-refactor-plan.md`.
-module(purerl_tidal_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_all,
                 intensity => 3,
                 period => 60},
    ChildSpecs = [],
    {ok, {SupFlags, ChildSpecs}}.
