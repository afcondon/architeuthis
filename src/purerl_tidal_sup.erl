%% @doc Top-level supervisor for purerl_tidal.
%%
%% Strategy is `one_for_all` because the children are tightly coupled:
%% if any of {voice_sup, dispatcher, clock} crashes hard enough to
%% exceed restart intensity, the whole rig should reset rather than run
%% with partial state.
%%
%% Children, in start order:
%%   1. tidal_voice_sup — empty supervisor; voices added by `bind` verb.
%%   2. tidal_dispatcher — OSC owner (skeletal at PR1.4a; route+format
%%      + send migrates from MIDIScheduler in PR1.4c).
%%   3. tidal_clock — gen_statem broadcasting compute_until ticks. Last
%%      because it broadcasts to voice_sup; harmless if voice_sup is
%%      gone but tidier to start later.
%%
%% MIDIScheduler is intentionally NOT a child of this supervisor. It
%% continues to be bare-spawned from Main.purs during the migration so
%% the existing (channel/bus-keyed) dispatch path keeps working
%% alongside the new (bound-name) path. Once the migration completes,
%% MIDIScheduler is dismantled — see `docs/per-voice-refactor-plan.md`.
%%
%% Clock config is read from the `purerl_tidal` application env, with
%% defaults matching the current Main.purs values (bpm 120, tick 50ms,
%% lookahead 100ms). startTimeMs is computed at supervisor init so the
%% free-running clock has a fresh reference point on each boot.
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

    Bpm         = application:get_env(purerl_tidal, bpm, 120.0),
    TickMs      = application:get_env(purerl_tidal, tickIntervalMs, 50),
    LookAheadMs = application:get_env(purerl_tidal, lookAheadMs, 100.0),
    StartTimeMs = float(erlang:system_time(millisecond)),
    ClockConfig = #{bpm             => Bpm,
                    tickIntervalMs  => TickMs,
                    lookAheadMs     => LookAheadMs,
                    startTimeMs     => StartTimeMs},

    ChildSpecs =
        [#{id => tidal_voice_sup,
           start => {tidal_voice_sup, start_link, []},
           restart => permanent,
           shutdown => infinity,
           type => supervisor,
           modules => [tidal_voice_sup]},
         #{id => tidal_dispatcher,
           start => {tidal_dispatcher, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker,
           modules => [tidal_dispatcher]},
         #{id => tidal_clock,
           start => {tidal_clock, start_link, [ClockConfig]},
           restart => permanent,
           shutdown => 5000,
           type => worker,
           modules => [tidal_clock]},
         #{id => tidal_state_pub,
           start => {tidal_state_pub, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker,
           modules => [tidal_state_pub]},
         #{id => tidal_conductor,
           start => {tidal_conductor, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker,
           modules => [tidal_conductor]}],
    {ok, {SupFlags, ChildSpecs}}.
