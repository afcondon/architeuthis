%% @doc René machine voice gen_server — one instance per `odonus`
%% Session binding.  Subscribes to master clock; per step, optionally
%% fires step_y (when the Y-clock pattern is true at this position),
%% always fires step_x, then emits MIDI for the new cursor cell.
%%
%% Architecture mirrors balistes_voice / repetitor_voice.  Single MIDI
%% channel per [[feedback_drumkit_single_midi_channel]].  Live-mutable
%% via cell-text re-fire (set_config).  Phase 4 will add Twister-driven
%% live mutation through the live-control bus.
-module(odonus_voice).
-behaviour(gen_server).

-export([start_link/2,
         compute_until/2,
         set_config/2,
         get_state/1,
         get_samples/1,
         clear_samples/1,
         phase_resync/1,
         hush/1,
         unhush/1,
         registered_name/1]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

%% Default: 4 steps per cycle = one step per beat in 4/4.  Same as
%% Repetitor.  René patterns are 16 cells, so without Y-stepping a
%% bare X-clock at 4/cycle loops the first-row 4 cells per bar.
%% Set step_y_pattern to fire less often to traverse rows.
-define(DEFAULT_STEPS_PER_CYCLE, 4).

-record(st, {
    name           :: atom(),
    %% MIDI output config (single channel + distinct note numbers
    %% would be per-cell; here notes come from the engine.  So we
    %% need only channel + velocity + duration; the note value
    %% comes from the engine's current cell).
    port_name      :: binary(),
    channel        :: 1..16,
    vel            :: 0..127,
    dur_ms         :: 1..2000,
    steps_per_cycle :: pos_integer(),
    %% Engine state (odonus_engine map).
    engine         :: map(),
    %% Live config — opaque PureScript OdonusConfig value.  Per-step
    %% FFI query returns a snapshot of {step_y_now :: Bool}.
    cfg            :: term(),
    %% Engine running state.
    last_step      :: integer(),
    %% Output socket.
    midi_socket    :: gen_udp:socket() | undefined,
    %% F-LAT — device latency compensation in microseconds.  Tidal's
    %% Dispatcher.purs subtracts `dev.latencyMs * 1000` from `wallUs`
    %% before scheduleNoteAt; without that lead time, link-spike /
    %% CoreMIDI fire at-or-past target and Live block-quantises,
    %% producing the 17 ms IOI stdev / 12.6 % short beats we saw on
    %% Phase 4.  Sourced from the device's `latencyMs` at register
    %% time (walker pulls it from the device-latencies map it built
    %% from registerMidiDevice events).
    latency_us     :: integer(),
    %% F1 — cache the per-tick ControlMap so we rebuild it from the
    %% control-bus snapshot only when its version counter changes.
    %% `cached_controls` is an opaque purescript `Map String Value`
    %% value; we never inspect it from Erlang.  `control_version` is
    %% the value of `tidal_control_bus:version/0` at the time the
    %% cache was built; -1 means "no cache yet, rebuild on first use".
    control_version :: integer(),
    cached_controls :: term() | undefined,
    %% Hush flag — when true, emit_step does the engine advance and
    %% sample work but skips MIDI emit, so the playheads still keep
    %% in lockstep with the master clock but silently.  Toggled by the
    %% L-mid Globals "hush" / "unhush" buttons.  Default false (audible).
    hushed         :: boolean(),
    %% Phase 4 timing instrumentation — per-step timestamp record.
    %% Each entry is the tuple emitted in emit_step/6.  Prepended
    %% (most recent first); no bound — caller is expected to dump
    %% and clear between captures.  Cost per step: ~6 monotonic_time
    %% calls (~300 ns total) plus a list cons; well under what
    %% we're trying to measure.
    samples        :: [tuple()]
}).

%% =========================================================================
%% Public API
%% =========================================================================

%% Config keys (all required unless noted):
%%   port_name        :: binary()
%%   channel          :: 1..16
%%   vel              :: 0..127 (default 100)
%%   dur_ms           :: integer (default 100)
%%   steps_per_cycle  :: pos_integer (default 4)
%%   notes/skip/gate/glide  :: list of 16 entries
%%   nav_mode         :: cartesian | forward | reverse
%%   cfg              :: opaque PS OdonusConfig | undefined
start_link(Name, Config) when is_atom(Name); is_binary(Name) ->
    Atom = to_atom(Name),
    gen_server:start_link({local, registered_name(Atom)}, ?MODULE,
                          {Atom, Config}, []).

compute_until(Name, Window) ->
    gen_server:cast(registered_name(Name), {compute_until, Window}).

set_config(Name, Cfg) ->
    gen_server:cast(registered_name(Name), {set_config, Cfg}).

get_state(Name) ->
    gen_server:call(registered_name(Name), get_state).

%% @doc Dump per-step timing samples accumulated since last clear.
%% Each entry: {NowUsCast, TRecv, TEvalDone, TRefreshDone, TEngineDone,
%% TEmitDone, WallUs} — all microseconds, monotonic time origin.
%% Returns a list (most-recent first).  Use for timing-jitter
%% diagnosis ([[project_timing_jitter_investigation_queued]]).
get_samples(Name) ->
    gen_server:call(registered_name(Name), get_samples).

%% @doc Reset the timing-sample buffer.  Call between measurement
%% takes so a fresh dump only includes the take of interest.
clear_samples(Name) ->
    gen_server:cast(registered_name(Name), clear_samples).

%% @doc Reset every playhead's cursor + phase accumulator to zero.
%% Cells / notes / gates / glides / config all preserved — only the
%% traversal state resets.  Used by the `phase-resync` WS verb when
%% an Odonus voice has drifted out of step with the bar (e.g. after
%% manual cursor poking) and needs to re-align at downbeat 0.
phase_resync(Name) ->
    gen_server:cast(registered_name(Name), phase_resync).

%% @doc Silence this Odonus voice — emit_step still runs the engine
%% advance (so playheads stay in step with the master clock) but skips
%% MIDI output.  Use `unhush/1` to resume emission.
hush(Name) ->
    gen_server:cast(registered_name(Name), hush).

%% @doc Resume MIDI emission after a hush.
unhush(Name) ->
    gen_server:cast(registered_name(Name), unhush).

registered_name(Name) when is_atom(Name) ->
    binary_to_atom(<<"odonus_voice_",
                     (atom_to_binary(Name, utf8))/binary>>, utf8);
registered_name(Name) when is_binary(Name) ->
    registered_name(binary_to_atom(Name, utf8)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({Name, Config}) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Engine = odonus_engine:new(Config),
    State = #st{
        name            = Name,
        port_name       = ensure_binary(maps:get(port_name, Config)),
        channel         = maps:get(channel, Config),
        vel             = maps:get(vel,     Config, 100),
        dur_ms          = maps:get(dur_ms,  Config, 100),
        steps_per_cycle = maps:get(steps_per_cycle, Config, ?DEFAULT_STEPS_PER_CYCLE),
        engine          = Engine,
        cfg             = maps:get(cfg, Config, undefined),
        last_step       = -1,
        midi_socket     = Sock,
        latency_us      = round(maps:get(latency_ms, Config, 0.0) * 1000),
        control_version = -1,
        cached_controls = undefined,
        hushed          = false,
        samples         = []
    },
    tidal_log:info(
      "odonus_voice ~p started on ~s ch~B (nav=~p)~n",
      [Name, State#st.port_name, State#st.channel,
       maps:get(nav_mode, Engine)]),
    {ok, State}.

handle_call(get_state, _From, State) ->
    Snap = #{
        name       => State#st.name,
        port_name  => State#st.port_name,
        channel    => State#st.channel,
        engine     => State#st.engine,
        last_step  => State#st.last_step
    },
    {reply, Snap, State};
handle_call(get_samples, _From, State) ->
    {reply, State#st.samples, State}.

handle_cast({compute_until, Window}, State) ->
    NewState = process_window(Window, State),
    {noreply, NewState};
handle_cast(clear_samples, State) ->
    {noreply, State#st{samples = []}};
handle_cast(phase_resync, State) ->
    %% Reset every playhead's cursor + accumulator + pend_step to zero.
    %% Also reset last_step to -1 so process_window/2's "first tick"
    %% branch fires next, aligning step emission with the current
    %% master cycle rather than continuing from the pre-reset count.
    Engine = odonus_engine:reset_playheads(State#st.engine),
    {noreply, State#st{engine = Engine, last_step = -1}};
handle_cast(hush, State) ->
    {noreply, State#st{hushed = true}};
handle_cast(unhush, State) ->
    {noreply, State#st{hushed = false}};
handle_cast({set_config, Cfg}, State) ->
    %% Cfg is a partial-update map.  Engine arrays (notes/skip/gate/
    %% glide) update via odonus_engine:set_field which preserves the
    %% (x, y) cursor — same shape as Balistes/Repetitor live-mutation:
    %% mid-stream changes don't reset the position counter.
    Engine0 = State#st.engine,
    Engine1 = update_engine(Engine0, Cfg),
    NewCfg = maps:get(cfg, Cfg, State#st.cfg),
    {noreply, State#st{engine = Engine1, cfg = NewCfg}}.

terminate(_Reason, State) ->
    case State#st.midi_socket of
        undefined -> ok;
        Sock -> catch gen_udp:close(Sock)
    end,
    ok.

update_engine(Engine, Cfg) ->
    Fields = [notes, skip, gate, glide, nav_mode],
    lists:foldl(
      fun(Field, Eng) ->
              case maps:get(Field, Cfg, undefined) of
                  undefined -> Eng;
                  Val       -> odonus_engine:set_field(Eng, Field, Val)
              end
      end, Engine, Fields).

%% =========================================================================
%% Tick handling
%% =========================================================================

process_window(Window, State) ->
    %% T_RECV — instrumentation: time the cast actually starts being
    %% handled in this gen_server.  Compared to NowUs in the Window
    %% (which is when tidal_clock fired the broadcast), the delta
    %% measures gen_server mailbox / scheduler latency.
    TRecv = erlang:monotonic_time(microsecond),
    CurrentCycle = maps:get(currentCycle,    Window),
    LookAhead    = maps:get(lookAheadCycle,  Window),
    CycleDurMs   = maps:get(cycleDurationMs, Window),
    NowUs        = maps:get(nowUnixUs,       Window),
    ControlPairs = maps:get(controlPairs, Window, array:from_list([])),
    %% Active scale from tidal_scale_bus, threaded by tidal_clock into
    %% every Window.  Pushed to the PS evaluator as a `Maybe Scale` —
    %% `{just, S}` overrides the binding's static `cfg.scale`,
    %% `{nothing}` falls back.  This is how `set-scale c-minor` retunes
    %% all running Odonus voices on the next tick.
    ActiveScale  = maps:get(activeScale, Window, {nothing}),
    %% F1 — rebuild the opaque PureScript ControlMap only when the
    %% bus's version counter advances.  Pre-F1 each step rebuilt the
    %% Map from scratch inside `evaluateParamsAt`, costing ~1 ms of
    %% the 2.18 ms mean FFI time.  See tools/timing-data/phase-4-diagnostic/.
    %% `controlVersion` is missing in older callers (tests, replay);
    %% fall through to "always rebuild" by treating absence as -1.
    ControlVersion = maps:get(controlVersion, Window, -1),
    {Controls, State1} =
        case ControlVersion =:= State#st.control_version
             andalso State#st.cached_controls =/= undefined of
            true ->
                {State#st.cached_controls, State};
            false ->
                Built = 'tidal_odonus@ps':buildControlMap(ControlPairs),
                {Built, State#st{control_version = ControlVersion,
                                 cached_controls = Built}}
        end,
    StepsPerCycle = State1#st.steps_per_cycle,
    LastStep = State1#st.last_step,
    StartStep =
        if LastStep =:= -1 -> trunc(CurrentCycle * StepsPerCycle);
           true            -> LastStep + 1
        end,
    %% F-FUTURE — discover each step one ahead of `trunc(lookAhead*sp)`.
    %% Without this, a step at cycle-position StepCycle was only emitted
    %% once `lookAhead` crossed StepCycle + 1/sp, by which point currentCycle
    %% had already passed StepCycle and WallUs landed ~150 ms in the past
    %% on every step.  With the +1, step S is emitted as lookAhead reaches
    %% StepCycle, so WallUs is reliably ~lookAheadMs in the future — same
    %% shape Voice.purs has for the Tidal-pattern path (which queries by
    %% integer-cycle window and never falls behind).  See
    %% tools/timing-data/phase-4-diagnostic-f1/ for the discovery I made.
    EndStepExcl = trunc(LookAhead * StepsPerCycle) + 1,
    StepCount = EndStepExcl - StartStep,
    %% Anchor-log ghost trap: forward clock jump signature.  Normal
    %% cast emits 0-1 steps at typical lookAhead/step ratios; >8 means
    %% the clock leapt forward (anchor transition, BPM change, etc.).
    case StepCount > 8 of
        true ->
            tidal_anchor_log:record({voice_step_burst, State1#st.name,
                                     StartStep, EndStepExcl, CurrentCycle,
                                     StepsPerCycle});
        false -> ok
    end,
    case EndStepExcl > StartStep of
        false ->
            %% Anchor-log ghost trap: silent dropout — clock retreated
            %% relative to LastStep+1, voice can't emit.
            tidal_anchor_log:record({voice_dropout, State1#st.name,
                                     State1#st.last_step,
                                     CurrentCycle, EndStepExcl, StepsPerCycle}),
            State1;
        true ->
            Steps = lists:seq(StartStep, EndStepExcl - 1),
            FinalState = lists:foldl(
                fun(S, Acc) ->
                    emit_step(S, Controls, ActiveScale, CurrentCycle,
                              CycleDurMs, NowUs, TRecv, Acc)
                end, State1, Steps),
            FinalState#st{last_step = EndStepExcl - 1}
    end.

%% Emit a single step S.  Order:
%%   1. Query Y-clock pattern (true → step_y first).
%%   2. step_x (the master tick always advances X).
%%   3. read current cell; emit MIDI if not silent_step.
%%
%% The engine guarantees the cursor lands on a non-skipped cell, so
%% emit logic just discriminates emit vs silent_step.
emit_step(S, Controls, ActiveScale, CurrentCycle, CycleDurMs, NowUs, TRecv, State) ->
    StepCycle = S / State#st.steps_per_cycle,
    %% F-LAT — subtract device latency so link-spike / CoreMIDI have
    %% lead time to schedule precisely; mirrors Dispatcher.purs's
    %% `adjustedUnixUs = wallUs - dev.latencyMs * 1000`.
    WallUs = round(NowUs + (StepCycle - CurrentCycle) * CycleDurMs * 1000)
             - State#st.latency_us,
    %% Snapshot the live config — stepYNow + 16 per-cell notes + 16
    %% per-cell skip values, all sampled at this step's cycle position.
    %% When cfg is undefined (registration without a config) the engine
    %% keeps its registration-time arrays.  Controls is the cached
    %% ControlMap built once per bus version in process_window/2 (F1).
    Snap = case State#st.cfg of
        undefined -> #{stepYNow => false, advance => true};
        Cfg ->
            'tidal_odonus@ps':evaluateParamsAtControls(
                Cfg, Controls, ActiveScale, StepCycle)
    end,
    TEvalDone = erlang:monotonic_time(microsecond),
    %% The advance gate decides whether this micro-tick steps the
    %% engine at all.  When false, we still consume the step (so
    %% last_step bookkeeping in the caller works) but produce no
    %% X/Y advance and no emit.  This is the seam through which
    %% irregular clock sources (a Tidal euclidean rhythm, a MIDI
    %% trigger pattern, a controller gate) drive René — and the
    %% same shape applies to every step-sequencer-flavoured vmod.
    Advance = maps:get(advance, Snap, true),
    case Advance of
        false ->
            State;
        true ->
            StepYNow = maps:get(stepYNow, Snap, false),
            Engine0  = refresh_from_snapshot(State#st.engine, Snap),
            TRefreshDone = erlang:monotonic_time(microsecond),
            Engine1 = case StepYNow of
                true  -> odonus_engine:step_y_all(Engine0);
                false -> Engine0
            end,
            %% Slab 6.2 — advance every playhead by its phase-accumulator
            %% (snap.speed[K]) in the direction (snap.direction[K]).
            %% Returns updated engine state with new cursors / pend_step
            %% remainders.
            SpeedList = snap_array_as_list(Snap, speed),
            DirList   = snap_array_as_list(Snap, direction),
            Engine2 = odonus_engine:advance_all(Engine1, SpeedList, DirList),
            %% Step duration in microseconds — width of the per-step
            %% wall-time window.  Used to space ratchet sub-emits
            %% evenly across the step.
            StepDurUs = round((CycleDurMs * 1000) / State#st.steps_per_cycle),
            %% Per-playhead emit: for each cursor, look up the cell's
            %% note + gate + vel from the snapshot, apply transp[K],
            %% then route through maybe_emit_with_ratchet (probability +
            %% ratchet fan-out reuse the per-cell snapshot arrays).
            %% Muted playheads (snap.mute[K] = true) still had their
            %% cursors advanced by advance_all/3 above — the emit just
            %% gets skipped, so re-enabling resumes in step.
            Cursors = odonus_engine:current_cursors(Engine2),
            TranspList = snap_array_as_list(Snap, transp),
            MuteList   = snap_array_as_list(Snap, mute),
            %% Hush gate: engine advance + cursor bookkeeping still run
            %% (so the playheads stay in step with the master clock and
            %% unhush picks up cleanly), but MIDI emission is suppressed.
            case State#st.hushed of
                true  -> ok;
                false -> emit_all_playheads(Cursors, TranspList, MuteList,
                                            WallUs, StepDurUs, Snap, State)
            end,
            TEmitDone = erlang:monotonic_time(microsecond),
            %% Per-step diagnostic sample.  Tuple shape (microseconds):
            %% { NowUs       — when tidal_clock fired the broadcast
            %% , TRecv       — when this gen_server began handling
            %% , TEvalDone   — after FFI evaluateParamsAt returned
            %% , TRefreshDone — after refresh_from_snapshot returned
            %% , TEmitDone   — after scheduleNoteAt thunk returned
            %% , WallUs      — scheduled MIDI-emit wall time
            %% }
            %% Engine step_x/y is so cheap we fold it into the eval
            %% phase rather than instrument separately.
            Sample = {NowUs, TRecv, TEvalDone, TRefreshDone,
                      TEmitDone, WallUs},
            State#st{engine = Engine2,
                     samples = [Sample | State#st.samples]}
    end.

%% Pull per-cell arrays out of the snapshot (if present) and refresh
%% the engine's stored copies before this step's traversal runs.  This
%% is the seam through which controller-bus writes (Twister knobs →
%% odonus.note0..15, odonus.gate0..15, …) reach the engine's skip-aware
%% step_x and current_event logic.
%%
%% Slab 6.1: gate + glide added.  gate gates the per-cell emit (silent
%% vs sounding step), glide is engine-internal only today (carried for
%% the future per-cell portamento hook).
%%
%% Per [[reference_purerl_array_is_erlang_array_module]] PureScript
%% Arrays cross the boundary as Erlang `array` records, not lists;
%% convert with array:to_list/1 before handing to odonus_engine:set_field.
refresh_from_snapshot(Engine, Snap) ->
    Fields = [notes, skip, gate, glide],
    lists:foldl(
      fun(Field, Eng) ->
              case maps:get(Field, Snap, undefined) of
                  undefined -> Eng;
                  Arr       -> odonus_engine:set_field(
                                 Eng, Field, array:to_list(Arr))
              end
      end, Engine, Fields).

emit_note(Note, Vel, WallUs, DurMs, State) ->
    Thunk = tidal_mIDIBridge@foreign:scheduleNoteAt(
              State#st.midi_socket,
              State#st.port_name,
              State#st.channel,
              Note,
              Vel,
              DurMs,
              WallUs),
    Thunk(),
    ok.

%% Iterate playheads and emit per-cursor.  Slab 6.2.  Each playhead K
%% has its own cursor; the cell's note + gate come from the snapshot
%% at that cursor's position, the per-playhead transp is added to the
%% note before MIDI emit.  Gate-off cells produce silent steps (no
%% MIDI emit, but advance bookkeeping in advance_all already happened).
emit_all_playheads([], _T, _M, _WallUs, _StepDurUs, _Snap, _State) -> ok;
emit_all_playheads(Cursors, Transps, Mutes, WallUs, StepDurUs, Snap, State) ->
    %% Zip cursor list with playhead-index 0..N-1 so we can index per-
    %% playhead arrays.
    Indexed = lists:zip(lists:seq(0, length(Cursors) - 1), Cursors),
    lists:foreach(
      fun({K, Cursor}) ->
              emit_one_playhead(K, Cursor, Transps, Mutes,
                                WallUs, StepDurUs, Snap, State)
      end, Indexed).

emit_one_playhead(K, Cursor, _Transps, Mutes, WallUs, StepDurUs, Snap, State) ->
    Muted = lists_nth_or(K + 1, Mutes, false),
    case Muted of
        true -> ok;   % per-playhead silent (cursor already advanced)
        false ->
            Gate = snap_bool_at(Snap, gate, Cursor, true),
            case Gate of
                false -> ok;  % per-cell silent step
                true ->
                    %% Read the pre-resolved note from the snapshot's
                    %% P × 16 transposedNotes grid (scale-degree shift
                    %% already applied in PureScript via
                    %% shiftDegreesInScale).  Fall back to raw notes[Cursor]
                    %% when transposedNotes is missing or short — that's
                    %% the identity-shift case (transp K = 0 equivalent).
                    RawNote = snap_int_at(Snap, notes, Cursor, 60),
                    FinalNote = clamp_note(
                        snap_2d_int_at(Snap, transposedNotes,
                                       K, Cursor, RawNote)),
                    maybe_emit_with_ratchet(FinalNote, Cursor, WallUs,
                                            StepDurUs, Snap, State)
            end
    end.

clamp_note(N) when N < 0   -> 0;
clamp_note(N) when N > 127 -> 127;
clamp_note(N) -> N.

%% Indexed lookup with a default for shortfall.  Used to apply the
%% per-playhead transp / speed lists with the spec §5.3 forgiving
%% semantics — surplus dropped (we only access K+1), shortfall defaulted.
lists_nth_or(N, L, _Default) when N >= 1, N =< length(L) ->
    lists:nth(N, L);
lists_nth_or(_, _, Default) -> Default.

%% Read a per-cell array from the snapshot as an Erlang list.  Snapshot
%% arrays cross the FFI boundary as Erlang `array` records (per
%% [[reference_purerl_array_is_erlang_array_module]]); convert with
%% `array:to_list/1` so the voice can index by position via lists:nth.
%% Absent / non-array values fall back to the empty list — the caller
%% then takes the zip-with-default path.
snap_array_as_list(Snap, Key) ->
    case maps:get(Key, Snap, undefined) of
        undefined -> [];
        Arr ->
            try array:to_list(Arr)
            catch _:_ when is_list(Arr) -> Arr;
                  _:_ -> []
            end
    end.

%% Probability gate + ratchet expansion.  Called once per emit step.
%% Reads the per-cell probability, ratchet, and velocity from the
%% snapshot (PureScript Arrays delivered as Erlang `array` records —
%% see [[reference_purerl_array_is_erlang_array_module]]).  A failed
%% probability roll silences the entire step regardless of ratchet
%% count; a successful roll emits Ratchet evenly-spaced sub-notes
%% across the step's wall-time window at the per-cell velocity.  Each
%% sub-note's MIDI dur_ms is clamped so back-to-back ratchets don't
%% overlap.
%%
%% Slab 6.1: vel is now per-cell.  Falls back to the binding's scalar
%% `vel` if the snapshot lacks a vel array (older callers / cfg-less
%% registrations).  MIDI range clamped to 0..127.
maybe_emit_with_ratchet(Note, Idx, WallUs, StepDurUs, Snap, State) ->
    Prob    = snap_number_at(Snap, probability, Idx, 1.0),
    Ratchet = max(1, snap_int_at(Snap, ratchet, Idx, 1)),
    Vel     = clamp_vel(snap_int_at(Snap, vel, Idx, State#st.vel)),
    Roll    = rand:uniform(),
    case Roll =< Prob of
        false ->
            ok;
        true ->
            SubDurUs = StepDurUs div Ratchet,
            SubDurMs = max(1, SubDurUs div 1000),
            EmitDurMs = min(State#st.dur_ms, SubDurMs),
            lists:foreach(
                fun(K) ->
                    SubWallUs = WallUs + K * SubDurUs,
                    emit_note(Note, Vel, SubWallUs, EmitDurMs, State)
                end,
                lists:seq(0, Ratchet - 1))
    end.

clamp_vel(V) when V < 0   -> 0;
clamp_vel(V) when V > 127 -> 127;
clamp_vel(V) -> V.

snap_int_at(Snap, Key, Idx, Default) ->
    case maps:get(Key, Snap, undefined) of
        undefined -> Default;
        Arr       -> array_get_or(Arr, Idx, Default)
    end.

snap_number_at(Snap, Key, Idx, Default) ->
    case maps:get(Key, Snap, undefined) of
        undefined -> Default;
        Arr       -> array_get_or(Arr, Idx, Default)
    end.

snap_bool_at(Snap, Key, Idx, Default) ->
    case maps:get(Key, Snap, undefined) of
        undefined -> Default;
        Arr       -> array_get_or(Arr, Idx, Default)
    end.

%% PureScript Arrays cross the boundary as Erlang `array` records.
%% array:get/2 throws on out-of-bounds, so guard with a size check.
array_get_or(Arr, Idx, Default) ->
    case Idx >= 0 andalso Idx < array:size(Arr) of
        true  -> array:get(Idx, Arr);
        false -> Default
    end.

%% Two-level snapshot lookup: outer indexed by playhead K, inner by
%% cell cursor.  Used for the transposedNotes grid (P × 16) where each
%% entry is the cell's note already shifted by transp[K] scale-degrees.
%% Either bound out of range falls back to Default.
snap_2d_int_at(Snap, Key, K, Idx, Default) ->
    case maps:get(Key, Snap, undefined) of
        undefined -> Default;
        Outer ->
            case K >= 0 andalso K < array:size(Outer) of
                false -> Default;
                true ->
                    Inner = array:get(K, Outer),
                    case Idx >= 0 andalso Idx < array:size(Inner) of
                        false -> Default;
                        true  -> array:get(Idx, Inner)
                    end
            end
    end.

%% =========================================================================
%% Helpers
%% =========================================================================

to_atom(N) when is_atom(N) -> N;
to_atom(N) when is_binary(N) -> binary_to_atom(N, utf8);
to_atom(N) when is_list(N) -> list_to_atom(N).

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8).
