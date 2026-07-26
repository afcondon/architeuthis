%% @doc Balistes voice gen_server — one instance per `balistes` Session
%% binding.  Subscribes (via tidal_clock's broadcast) to the master
%% `{compute_until, Window}` ticks; on each tick, evaluates any new
%% 32-step Balistes steps that fall in the window, runs the engine, and
%% emits MIDI note-on/off events to the configured FH-2 channel.
%%
%% Architecture (per `project_parameter_as_pattern_lift`):
%%
%%     PureScript: BalistesConfig { x :: Pattern Int, y :: Pattern Int, … }
%%                          |
%%                          v   (registered opaquely via walker)
%%     Erlang:     balistes_voice gen_server holds the Foreign BalistesConfig
%%                 + step state.  Per step: FFI call to PS-side
%%                 `Tidal.Balistes.evaluateParamsAt(cfg, cyclePos)` → 7 Ints
%%                 → reef_balistes_engine@ps:evaluateStep → MIDI events.
%%
%% Phase 2 (this commit): params are a static tuple, no Pattern queries
%% yet.  Phase 3 swaps in the PS-side FFI call.  The voice's outer
%% shape doesn't change.
-module(balistes_voice).
-behaviour(gen_server).

-export([start_link/2,
         compute_until/2,
         set_config/2,
         get_state/1,
         registered_name/1]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(STEPS_PER_CYCLE, 32).
-define(NUM_INSTRUMENTS, 3).

%% gen_server state.
-record(st, {
    name           :: atom(),
    %% MIDI output config.
    port_name      :: binary(),     % e.g. <<"FH-2">> — CoreMIDI port
    channel        :: 1..16,
    note_bd        :: 0..127,
    note_sd        :: 0..127,
    note_hh        :: 0..127,
    vel            :: 0..127,
    vel_accent     :: 0..127,
    dur_ms         :: 1..2000,
    %% Live config — opaque PureScript BalistesConfig value.  The voice
    %% calls `Tidal.Balistes.evaluateParamsAt(cfg, cyclePos)` per step
    %% to query each of the seven Pattern Int slots.
    cfg            :: term(),
    %% Engine running state.
    last_step      :: integer(),    % -1 before first emit
    perturbations  :: array:array(integer()),  % reef array [Pb, Ps, Ph]
    rng_state      :: integer(),
    %% Output socket — shared by all calls from this voice.
    midi_socket    :: gen_udp:socket() | undefined,
    %% F-LAT — device latency compensation in microseconds.  See
    %% odonus_voice.erl for rationale and tools/timing-data/phase-4-diagnostic-f1/.
    latency_us     :: integer(),
    %% F1 — cache the per-tick ControlMap; rebuild only when the
    %% control-bus version counter advances.
    control_version :: integer(),
    cached_controls :: term() | undefined
}).

%% =========================================================================
%% Public API
%% =========================================================================

%% Config keys (all required):
%%   port_name   :: binary()  MIDI port (e.g. <<"FH-2">>)
%%   channel     :: 1..16
%%   note_bd     :: 0..127
%%   note_sd     :: 0..127
%%   note_hh     :: 0..127
%%   vel         :: 0..127
%%   vel_accent  :: 0..127
%%   dur_ms      :: int      MIDI note duration
%%   params      :: {X,Y,FillBd,FillSd,FillHh,Random,Mode}  static for now
%%   rng_seed    :: integer (optional; default: hash of Name + system time)
start_link(Name, Config) when is_atom(Name); is_binary(Name) ->
    Atom = to_atom(Name),
    gen_server:start_link({local, registered_name(Atom)}, ?MODULE,
                          {Atom, Config}, []).

compute_until(Name, Window) ->
    gen_server:cast(registered_name(Name), {compute_until, Window}).

%% @doc Replace the voice's BalistesConfig with a fresh value (cell re-fire
%% path).  Patterns swap atomically; the very next step will read the
%% new patterns.  Engine state (step counter, perturbations) is
%% preserved across re-fires so the pattern doesn't reset mid-bar.
set_config(Name, Cfg) ->
    gen_server:cast(registered_name(Name), {set_config, Cfg}).

get_state(Name) ->
    gen_server:call(registered_name(Name), get_state).

registered_name(Name) when is_atom(Name) ->
    binary_to_atom(<<"balistes_voice_", (atom_to_binary(Name, utf8))/binary>>, utf8);
registered_name(Name) when is_binary(Name) ->
    registered_name(binary_to_atom(Name, utf8)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({Name, Config}) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Seed0 = maps:get(rng_seed, Config,
                     erlang:phash2({Name, erlang:system_time()})),
    State = #st{
        name        = Name,
        port_name   = ensure_binary(maps:get(port_name, Config)),
        channel     = maps:get(channel,    Config),
        note_bd     = maps:get(note_bd,    Config, 36),
        note_sd     = maps:get(note_sd,    Config, 38),
        note_hh     = maps:get(note_hh,    Config, 42),
        vel         = maps:get(vel,        Config, 90),
        vel_accent  = maps:get(vel_accent, Config, 127),
        dur_ms      = maps:get(dur_ms,     Config, 30),
        cfg         = maps:get(cfg,        Config,
                                                undefined),
        last_step   = -1,
        %% a reef array (not a list): it feeds reef_balistes_engine@ps:evaluateStep
        %% on the first tick if that tick is not a pattern start.
        perturbations = array:from_list([0, 0, 0]),
        rng_state   = Seed0 band 16#FFFFFFFF,
        midi_socket = Sock,
        latency_us  = round(maps:get(latency_ms, Config, 0.0) * 1000),
        control_version = -1,
        cached_controls = undefined
    },
    tidal_log:info("balistes_voice ~p started on ~s ch~B (BD/SD/HH ~B/~B/~B)~n",
                   [Name, State#st.port_name, State#st.channel,
                    State#st.note_bd, State#st.note_sd, State#st.note_hh]),
    {ok, State}.

handle_call(get_state, _From, State) ->
    Snap = #{
        name          => State#st.name,
        port_name     => State#st.port_name,
        channel       => State#st.channel,
        last_step     => State#st.last_step,
        perturbations => array:to_list(State#st.perturbations)
    },
    {reply, Snap, State}.

handle_cast({compute_until, Window}, State) ->
    NewState = process_window(Window, State),
    {noreply, NewState};
handle_cast({set_config, Cfg}, State) ->
    {noreply, State#st{cfg = Cfg}}.

terminate(_Reason, State) ->
    case State#st.midi_socket of
        undefined -> ok;
        Sock -> catch gen_udp:close(Sock)
    end,
    ok.

%% =========================================================================
%% Tick handling
%% =========================================================================

%% Process a {compute_until, Window} broadcast.  Emits any 32-step
%% Balistes steps whose absolute index lies in (last_step, EndStep].
process_window(Window, State) ->
    CurrentCycle = maps:get(currentCycle,    Window),
    LookAhead    = maps:get(lookAheadCycle,  Window),
    CycleDurMs   = maps:get(cycleDurationMs, Window),
    NowUs        = maps:get(nowUnixUs,       Window),
    ControlPairs = maps:get(controlPairs, Window, array:from_list([])),
    ControlVersion = maps:get(controlVersion, Window, -1),
    %% F1 — rebuild ControlMap only on bus version change.  See
    %% odonus_voice for the rationale and benchmark.
    {Controls, State1} =
        case ControlVersion =:= State#st.control_version
             andalso State#st.cached_controls =/= undefined of
            true ->
                {State#st.cached_controls, State};
            false ->
                Built = 'tidal_balistes@ps':buildControlMap(ControlPairs),
                {Built, State#st{control_version = ControlVersion,
                                 cached_controls = Built}}
        end,
    LastStep = State1#st.last_step,
    NowStep = trunc(CurrentCycle * ?STEPS_PER_CYCLE),
    %% F-FUTURE — discover step S as soon as lookAhead reaches StepCycle,
    %% rather than waiting for trunc to advance past StepCycle + 1/sp.
    %% Lands WallUs ~lookAheadMs in the future instead of in the past.
    EndStepExcl = trunc(LookAhead * ?STEPS_PER_CYCLE) + 1,
    %% Resume point, CLAMPED to the clock. `LastStep + 1' alone replays the
    %% whole backlog after a bpm change or a Link-sync transition moves
    %% currentCycle by hours of cycles — thousands of past-dated steps in one
    %% cast, each spawning a process in Tidal.OSC. See tidal_step_window.
    StartStep = tidal_step_window:start_step(
                  LastStep, NowStep, EndStepExcl,
                  #{name => State1#st.name, cycle => CurrentCycle,
                    spc => ?STEPS_PER_CYCLE}),
    case EndStepExcl - StartStep > 8 of
        true ->
            tidal_anchor_log:record({voice_step_burst, State1#st.name,
                                     StartStep, EndStepExcl, CurrentCycle,
                                     ?STEPS_PER_CYCLE});
        false -> ok
    end,
    case EndStepExcl > StartStep of
        false ->
            tidal_anchor_log:record({voice_dropout, State1#st.name,
                                     State1#st.last_step,
                                     CurrentCycle, EndStepExcl, ?STEPS_PER_CYCLE}),
            State1;
        true ->
            Steps = lists:seq(StartStep, EndStepExcl - 1),
            FinalState = lists:foldl(
                fun(S, Acc) ->
                    emit_step(S, Controls, CurrentCycle, CycleDurMs, NowUs, Acc)
                end, State1, Steps),
            FinalState#st{last_step = EndStepExcl - 1}
    end.

%% Emit a single Balistes step S.  S is absolute (across cycles); the
%% wrap to 0..31 happens here.  Per the parameter-as-Pattern lift,
%% the seven parameter values come from a PureScript-side query
%% (`Tidal.Balistes.evaluateParamsAt`) against the live BalistesConfig at
%% this step's cycle position.  At step-in-pattern 0, regenerate
%% perturbations using the randomness value as scale.
emit_step(S, Controls, CurrentCycle, CycleDurMs, NowUs, State0) ->
    StepInPat = S rem ?STEPS_PER_CYCLE,
    StepCycle = S / ?STEPS_PER_CYCLE,
    Snap = case State0#st.cfg of
        undefined ->
            %% Should not happen — start_link guarantees cfg is set.
            %% Defensive fallback: silent step.
            #{x => 128, y => 128,
              fillBd => 0, fillSd => 0, fillHh => 0,
              randomness => 0, mode => 0};
        Cfg ->
            'tidal_balistes@ps':evaluateParamsAtControls(Cfg, Controls, StepCycle)
    end,
    X       = maps:get(x,          Snap),
    Y       = maps:get(y,          Snap),
    FBd     = maps:get(fillBd,     Snap),
    FSd     = maps:get(fillSd,     Snap),
    FHh     = maps:get(fillHh,     Snap),
    Random  = maps:get(randomness, Snap),
    State1 =
        if StepInPat =:= 0 ->
               %% reef's freshPerturbations returns a PureScript record, i.e. an
               %% Erlang map #{perts => [...], rng => _}. This is the SINGLE shared
               %% Grids engine (reef_balistes_engine@ps), byte-identical to the
               %% Triggerfish frontend (Reef.Conformance.balistesRun) — it replaces
               %% the hand-written balistes_engine.erl, whose unmasked xorshift
               %% silently disagreed with the frontend RNG.
               #{perts := Perts, rng := RngNext} =
                   'reef_balistes_engine@ps':freshPerturbations(Random, State0#st.rng_state),
               State0#st{perturbations = Perts, rng_state = RngNext};
           true ->
               State0
        end,
    %% reef's Array Int / Array Trigger cross the boundary as Erlang `array`
    %% records, not lists (reference_purerl_array_is_erlang_array_module): the
    %% densities go in via array:from_list, the fired triggers come back as an
    %% array and are drained via array:to_list. `perturbations` is already a reef
    %% array (from freshPerturbations above), so it passes through untouched.
    Triggers = 'reef_balistes_engine@ps':evaluateStep(
                 StepInPat, X, Y,
                 array:from_list([FBd, FSd, FHh]),
                 State1#st.perturbations),
    %% F-LAT — subtract device latency so link-spike / CoreMIDI have
    %% lead time to schedule precisely.
    WallUs = round(NowUs + (StepCycle - CurrentCycle) * CycleDurMs * 1000)
             - State1#st.latency_us,
    lists:foreach(fun(T) -> emit_trigger(T, WallUs, State1) end,
                  array:to_list(Triggers)),
    State1.

emit_trigger(#{inst := Inst, accent := Accent}, WallUs, State) ->
    Note = note_for(Inst, State),
    Vel = if Accent -> State#st.vel_accent;
             true   -> State#st.vel
          end,
    %% scheduleNoteAt returns an Effect thunk per the PureScript ABI;
    %% bind then invoke.
    Thunk = tidal_mIDIBridge@foreign:scheduleNoteAt(
              State#st.midi_socket,
              State#st.port_name,
              State#st.channel,
              Note,
              Vel,
              State#st.dur_ms,
              WallUs),
    Thunk(),
    ok.

note_for(bd, S) -> S#st.note_bd;
note_for(sd, S) -> S#st.note_sd;
note_for(hh, S) -> S#st.note_hh.

%% =========================================================================
%% Helpers
%% =========================================================================

to_atom(N) when is_atom(N) -> N;
to_atom(N) when is_binary(N) -> binary_to_atom(N, utf8);
to_atom(N) when is_list(N) -> list_to_atom(N).

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8).
