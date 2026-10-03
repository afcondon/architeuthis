%% @doc Top-level supervisor for purerl_tidal.
%%
%% Strategy is `rest_for_one`: the child order encodes a dependency
%% chain, voices first then dispatcher/clock/state-pub/conductor.  A
%% crash restarts the crasher AND everything started after it, but
%% earlier children are untouched.  In practice this means:
%%
%%   - clock crashes      → clock + state_pub + conductor restart;
%%                          voices keep playing (silently, until the
%%                          next tick broadcasts resume ~50ms later).
%%   - dispatcher crashes → dispatcher + clock + state_pub + conductor
%%                          restart; voices keep playing but emit-side
%%                          fan-out pauses briefly.
%%   - any voice_sup crash → cascade, same as one_for_all — the
%%                          registration substrate is gone and partial
%%                          state isn't recoverable from here anyway.
%%
%% Previously `one_for_all`, which wiped every voice on any crash.
%% See [[reference_purerl_tidal_silent_supervisor_cascade]] — the
%% 2026-05-19 link-anchor RPC race took the whole rig dark from a
%% single clock crash; the defensive `info` clause closed that
%% specific cascade, but the strategy itself is the durable fix.
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
    SupFlags = #{strategy => rest_for_one,
                 intensity => 3,
                 period => 60},

    Bpm         = application:get_env(purerl_tidal, bpm, 120.0),
    TickMs      = application:get_env(purerl_tidal, tickIntervalMs, 50),
    %% Default 300 ms — 1.5× max expected step interval at 120 BPM × 16
    %% stepsPerCycle (= 125 ms).  Vmod voices rely on `WallUs = NowUs +
    %% (StepCycle - currentCycle) * cycleDur` landing comfortably in the
    %% future; minimum lead time at higher densities was hitting near zero
    %% with the 100 ms default, exposing rare BEAM preemptions as audible
    %% glitches.  See tools/timing-data/phase-4-diagnostic-f1-f2/.  The
    %% Tidal-pattern path is insensitive to this value (it queries by
    %% integer-cycle window).
    LookAheadMs = application:get_env(purerl_tidal, lookAheadMs, 300.0),
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
         #{id => balistes_voice_sup,
           start => {balistes_voice_sup, start_link, []},
           restart => permanent,
           shutdown => infinity,
           type => supervisor,
           modules => [balistes_voice_sup]},
         #{id => repetitor_voice_sup,
           start => {repetitor_voice_sup, start_link, []},
           restart => permanent,
           shutdown => infinity,
           type => supervisor,
           modules => [repetitor_voice_sup]},
         #{id => odonus_voice_sup,
           start => {odonus_voice_sup, start_link, []},
           restart => permanent,
           shutdown => infinity,
           type => supervisor,
           modules => [odonus_voice_sup]},
         #{id => virtual_selene_voice_sup,
           start => {virtual_selene_voice_sup, start_link, []},
           restart => permanent,
           shutdown => infinity,
           type => supervisor,
           modules => [virtual_selene_voice_sup]},
         #{id => selene_pattern_voice_sup,
           start => {selene_pattern_voice_sup, start_link, []},
           restart => permanent,
           shutdown => infinity,
           type => supervisor,
           modules => [selene_pattern_voice_sup]},
         %% Tidal's streams d1..d16 (Limulus), straight to SuperDirt.
         #{id => tidal_dirt_voice_sup,
           start => {tidal_dirt_voice_sup, start_link, []},
           restart => permanent,
           shutdown => infinity,
           type => supervisor,
           modules => [tidal_dirt_voice_sup]},
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
           modules => [tidal_conductor]},
         %% Near the end, so under rest_for_one its restart touches only odonus_feeds.
         %% It holds only what pages pushed, so a restart loses the record
         %% of what is loaded, never the sound.
         #{id => tidal_stage,
           start => {tidal_stage, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker,
           modules => [tidal_stage]},
         %% After the stage it subscribes to, so a stage restart restarts it.
         #{id => odonus_feeds,
           start => {odonus_feeds, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker,
           modules => [odonus_feeds]},
         %% Loop windows driven by patterns from Limulus (slide "…", widen "…").
         %% Last, so its restart under rest_for_one touches nothing else.
         #{id => window_patterns,
           start => {window_patterns, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker,
           modules => [window_patterns]}],
    {ok, {SupFlags, ChildSpecs}}.
