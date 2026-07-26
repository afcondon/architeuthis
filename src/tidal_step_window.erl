%%%-------------------------------------------------------------------
%%% @doc Where does a step-driven voice RESUME after the clock moves?
%%%
%%% == The question this module answers ==
%%%
%%% A step voice keeps a cursor (`last_step') and, on every clock cast,
%%% emits the steps between that cursor and the lookahead horizon. The
%%% obvious resume point is `last_step + 1' — "carry on where I left
%%% off". That is correct only while the clock advances smoothly.
%%%
%%% The clock does NOT always advance smoothly. `currentCycle' is
%%% derived as `elapsedMs / cycleDurationMs', so:
%%%
%%%   * `bpm N' rescales `cycleDurationMs' against TOTAL UPTIME, moving
%%%     `currentCycle' by hours' worth of cycles in one tick;
%%%   * the free-run -> Link-sync transition swaps in the absolute Link
%%%     beat, a magnitude unrelated to VM uptime;
%%%   * a transport restart can move the beat BACKWARD.
%%%
%%% After such a jump, `last_step + 1' can be tens of thousands of steps
%%% away from the clock. Emitting that range "to catch up" folds the
%%% whole backlog into a single `handle_cast': every step computes a
%%% wall-clock time in the PAST (so it is not even musically useful),
%%% and each one spawns a process and a socket in `Tidal.OSC'. That is a
%%% self-inflicted denial of service in the middle of a performance.
%%%
%%% == The rule ==
%%%
%%% A voice may be AHEAD of the clock (that is what lookahead means) but
%%% must never be BEHIND it, and must never be so far ahead that it has
%%% stranded itself in silence waiting for a far-future step. So:
%%%
%%%   * `Start &lt; NowStep' — the clock jumped FORWARD past us. Do not
%%%     replay the gap. Snap to now; the missed steps are in the past
%%%     and playing them late is worse than not playing them.
%%%   * `Start > NowStep + SnapAhead' — the clock jumped BACKWARD and
%%%     we are stranded in the future. Snap to now, or the voice goes
%%%     silent until the clock organically catches up.
%%%   * otherwise — carry on from the cursor, unchanged.
%%%
%%% Missed work is DISCARDED, never replayed. That is the whole point:
%%% for a musical event, late is not merely worse than on-time, it is
%%% worse than never.
%%%
%%% == Why the threshold is computed, not a constant ==
%%%
%%% `reef_voice' and friends use a fixed `?SNAP_AHEAD' of 8 steps, which
%%% is right for them: their window is ~1.6 steps, so 8 is ~5x headroom.
%%% The vmod voices cannot use a constant, because their legitimate
%%% lookahead in steps is `lookAheadMs / cycleDurationMs * StepsPerCycle'
%%% — which grows with TEMPO and with `steps_per_cycle'. At 480 bpm a
%%% 32-step balistes voice is legitimately ~13 steps ahead, and a fixed
%%% 8 would snap on every tick, shredding playback.
%%%
%%% So the threshold is derived from the window the clock just handed
%%% us (`EndStepExcl - NowStep'), with the same ~4x headroom, floored at
%%% 8 so it is never tighter than the reef constant.
%%%
%%% == Use ==
%%%
%%% Compute `NowStep' and `EndStepExcl' first, then let this module
%%% decide the resume point:
%%%
%%% ```
%%%   NowStep     = trunc(CurrentCycle * StepsPerCycle),
%%%   EndStepExcl = trunc(LookAhead * StepsPerCycle) + 1,
%%%   StartStep   = tidal_step_window:start_step(
%%%                   LastStep, NowStep, EndStepExcl,
%%%                   #{name => Name, cycle => CurrentCycle,
%%%                     spc => StepsPerCycle}),
%%% '''
%%%
%%% `LastStep' of -1 means "never emitted" and resumes at `NowStep'.
%%% A snap records a `{voice_step_snap, ...}' row in `tidal_anchor_log',
%%% so the clock discontinuity stays visible in the diagnostics rather
%%% than being silently swallowed.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(tidal_step_window).

-export([start_step/4]).

%% Headroom over the clock's own lookahead window before we conclude the
%% beat jumped backward rather than merely jittered. 4x matches the ratio
%% reef_voice's fixed ?SNAP_AHEAD of 8 has over its ~1.6-step window.
-define(SNAP_AHEAD_FACTOR, 4).

%% Never tighter than reef_voice's ?SNAP_AHEAD, however small the window.
-define(SNAP_AHEAD_MIN, 8).

-spec start_step(integer(), integer(), integer(), map()) -> integer().
start_step(LastStep, NowStep, EndStepExcl, Diag) ->
    Start0 =
        if LastStep =:= -1 -> NowStep;
           true            -> LastStep + 1
        end,
    WindowSteps = erlang:max(1, EndStepExcl - NowStep),
    SnapAhead = erlang:max(?SNAP_AHEAD_MIN, ?SNAP_AHEAD_FACTOR * WindowSteps),
    Behind = Start0 < NowStep,
    Stranded = Start0 > NowStep + SnapAhead,
    case Behind orelse Stranded of
        false ->
            Start0;
        true ->
            Reason = if Behind -> clock_jumped_forward;
                        true   -> clock_jumped_backward
                     end,
            tidal_anchor_log:record(
              {voice_step_snap, maps:get(name, Diag, unknown), Reason,
               Start0, NowStep, Start0 - NowStep,
               maps:get(cycle, Diag, undefined),
               maps:get(spc, Diag, undefined)}),
            NowStep
    end.
