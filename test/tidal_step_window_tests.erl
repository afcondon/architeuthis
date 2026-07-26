%%%-------------------------------------------------------------------
%%% @doc Tests for the step-window clamp.
%%%
%%% Two things must hold, and they pull in opposite directions:
%%%
%%%   1. A clock jump must NOT replay its backlog (the bug: a bpm change
%%%      after an hour of uptime folded ~28,800 past-dated steps into one
%%%      handle_cast, each spawning a process in Tidal.OSC).
%%%   2. Ordinary lookahead must NOT be mistaken for a jump. This is the
%%%      easy way to get the fix wrong: the legitimate ahead-distance
%%%      grows with tempo and steps_per_cycle, so a fixed threshold
%%%      (reef_voice's ?SNAP_AHEAD of 8) snaps every tick on a 32-step
%%%      voice at high tempo and shreds playback.
%%%
%%% Run: make test-erl
%%% @end
%%%-------------------------------------------------------------------
-module(tidal_step_window_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DIAG, #{name => test_voice, cycle => 0.0, spc => 32}).

%% The window the clock hands a voice, in steps, for a given tempo and
%% steps_per_cycle — mirrors tidal_clock:broadcast (lookAheadMs default 200).
window(Bpm, Spc, Cycle) ->
    CycleDur = 240000.0 / Bpm,
    LookAhead = Cycle + (200.0 / CycleDur),
    {trunc(Cycle * Spc), trunc(LookAhead * Spc) + 1}.

%% ── 1. ordinary operation must never snap ──────────────────────────────

%% Walk a voice through many ticks at several tempi and step resolutions,
%% exactly as the clock would drive it, and assert it never snaps. A fixed
%% ?SNAP_AHEAD of 8 fails this at 480 bpm / 32 spc.
normal_advance_never_snaps_test_() ->
    [{lists:flatten(io_lib:format("~p bpm, ~p steps/cycle", [Bpm, Spc])),
      fun() -> walk(Bpm, Spc) end}
     || Bpm <- [60.0, 120.0, 180.0, 240.0, 480.0], Spc <- [4, 8, 16, 32]].

walk(Bpm, Spc) ->
    CycleDur = 240000.0 / Bpm,
    TickCycles = 50.0 / CycleDur,          % 50 ms clock tick
    lists:foldl(
      fun(N, LastStep) ->
              Cycle = 10.0 + N * TickCycles,
              {NowStep, EndStepExcl} = window(Bpm, Spc, Cycle),
              Start = tidal_step_window:start_step(
                        LastStep, NowStep, EndStepExcl,
                        #{name => t, cycle => Cycle, spc => Spc}),
              %% the whole point: an untouched cursor
              Expect = if LastStep =:= -1 -> NowStep; true -> LastStep + 1 end,
              ?assertEqual(Expect, Start),
              case EndStepExcl > Start of
                  true  -> EndStepExcl - 1;
                  false -> LastStep
              end
      end, -1, lists:seq(0, 200)).

%% ── 2. the bug: a forward jump must not replay its backlog ─────────────

%% The real incident shape: an hour of uptime at 120 bpm, then `bpm 180'
%% rescales currentCycle against total uptime. Pre-fix this emitted the
%% entire gap in one cast.
bpm_change_after_an_hour_does_not_replay_test() ->
    Spc = 32,
    CycleAt120 = 3600000.0 / 2000.0,                  % 1 h / 2 s per cycle
    CycleAt180 = 3600000.0 / (240000.0 / 180.0),      % same uptime, new tempo
    {NowStep0, End0} = window(120.0, Spc, CycleAt120),
    LastStep = End0 - 1,
    {NowStep1, End1} = window(180.0, Spc, CycleAt180),

    %% precondition: this really is a huge jump (the bug's raw magnitude)
    Naive = LastStep + 1,
    ?assert(NowStep1 - Naive > 20000),

    Start = tidal_step_window:start_step(LastStep, NowStep1, End1,
                                         #{name => t, cycle => CycleAt180,
                                           spc => Spc}),
    ?assertEqual(NowStep1, Start),
    Emitted = max(0, End1 - Start),
    ?assert(Emitted =< 16),
    %% and NowStep0 was genuinely behind — sanity that the fixture moved forward
    ?assert(NowStep1 > NowStep0).

%% A backward jump (transport restart / re-sync) must not strand the voice
%% in the future waiting for a step the clock will not reach for hours.
backward_jump_snaps_test() ->
    Spc = 32,
    Stranded = 500000,
    {NowStep, End} = window(120.0, Spc, 10.0),
    Start = tidal_step_window:start_step(Stranded - 1, NowStep, End, ?DIAG),
    ?assertEqual(NowStep, Start).

%% ── 3. boundaries ──────────────────────────────────────────────────────

first_emission_starts_at_now_test() ->
    {NowStep, End} = window(120.0, 32, 10.0),
    ?assertEqual(NowStep, tidal_step_window:start_step(-1, NowStep, End, ?DIAG)).

%% Exactly at the threshold is tolerated; one step beyond snaps. Guards the
%% off-by-one in `Start0 > NowStep + SnapAhead'.
threshold_boundary_test() ->
    NowStep = 1000,
    EndStepExcl = NowStep + 3,                 % window of 3 steps
    SnapAhead = max(8, 4 * 3),                 % mirrors the module's rule
    AtEdge = NowStep + SnapAhead,
    ?assertEqual(AtEdge,
                 tidal_step_window:start_step(AtEdge - 1, NowStep, EndStepExcl, ?DIAG)),
    ?assertEqual(NowStep,
                 tidal_step_window:start_step(AtEdge, NowStep, EndStepExcl, ?DIAG)).

%% One step behind is still behind — the clamp is not a "large jump only"
%% heuristic, because any lateness emits past-dated events.
one_step_behind_snaps_test() ->
    NowStep = 1000,
    ?assertEqual(NowStep,
                 tidal_step_window:start_step(NowStep - 2, NowStep, NowStep + 3, ?DIAG)).

%% A degenerate window (lookahead below one step) must not divide by zero
%% or snap spuriously on the ordinary cursor.
degenerate_window_test() ->
    NowStep = 1000,
    ?assertEqual(NowStep + 1,
                 tidal_step_window:start_step(NowStep, NowStep, NowStep, ?DIAG)).
