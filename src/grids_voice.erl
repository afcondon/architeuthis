%% @doc Grids voice gen_server — one instance per `grids` Session
%% binding.  Subscribes (via tidal_clock's broadcast) to the master
%% `{compute_until, Window}` ticks; on each tick, evaluates any new
%% 32-step Grids steps that fall in the window, runs the engine, and
%% emits MIDI note-on/off events to the configured FH-2 channel.
%%
%% Architecture (per `project_parameter_as_pattern_lift`):
%%
%%     PureScript: GridsConfig { x :: Pattern Int, y :: Pattern Int, … }
%%                          |
%%                          v   (registered opaquely via walker)
%%     Erlang:     grids_voice gen_server holds the Foreign GridsConfig
%%                 + step state.  Per step: FFI call to PS-side
%%                 `Tidal.Grids.evaluateParamsAt(cfg, cyclePos)` → 7 Ints
%%                 → grids_engine:evaluate_step → MIDI events.
%%
%% Phase 2 (this commit): params are a static tuple, no Pattern queries
%% yet.  Phase 3 swaps in the PS-side FFI call.  The voice's outer
%% shape doesn't change.
-module(grids_voice).
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
    %% Live config — opaque PureScript GridsConfig value.  The voice
    %% calls `Tidal.Grids.evaluateParamsAt(cfg, cyclePos)` per step
    %% to query each of the seven Pattern Int slots.
    cfg            :: term(),
    %% Engine running state.
    last_step      :: integer(),    % -1 before first emit
    perturbations  :: [integer()],  % [Pb, Ps, Ph]
    rng_state      :: integer(),
    %% Output socket — shared by all calls from this voice.
    midi_socket    :: gen_udp:socket() | undefined
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

%% @doc Replace the voice's GridsConfig with a fresh value (cell re-fire
%% path).  Patterns swap atomically; the very next step will read the
%% new patterns.  Engine state (step counter, perturbations) is
%% preserved across re-fires so the pattern doesn't reset mid-bar.
set_config(Name, Cfg) ->
    gen_server:cast(registered_name(Name), {set_config, Cfg}).

get_state(Name) ->
    gen_server:call(registered_name(Name), get_state).

registered_name(Name) when is_atom(Name) ->
    binary_to_atom(<<"grids_voice_", (atom_to_binary(Name, utf8))/binary>>, utf8);
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
        perturbations = [0, 0, 0],
        rng_state   = Seed0 band 16#FFFFFFFF,
        midi_socket = Sock
    },
    tidal_log:info("grids_voice ~p started on ~s ch~B (BD/SD/HH ~B/~B/~B)~n",
                   [Name, State#st.port_name, State#st.channel,
                    State#st.note_bd, State#st.note_sd, State#st.note_hh]),
    {ok, State}.

handle_call(get_state, _From, State) ->
    Snap = #{
        name          => State#st.name,
        port_name     => State#st.port_name,
        channel       => State#st.channel,
        last_step     => State#st.last_step,
        perturbations => State#st.perturbations
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
%% Grids steps whose absolute index lies in (last_step, EndStep].
process_window(Window, State) ->
    CurrentCycle = maps:get(currentCycle,    Window),
    LookAhead    = maps:get(lookAheadCycle,  Window),
    CycleDurMs   = maps:get(cycleDurationMs, Window),
    NowUs        = maps:get(nowUnixUs,       Window),
    %% controlPairs is the live-control snapshot the clock takes per
    %% tick from `tidal_control_bus:snapshot/0`.  Thread it through so
    %% `liveIntOr "name"` slots in the GridsConfig read the current
    %% values.  Defaulted to empty array if a future Window omits it
    %% (defensive — the current clock always populates it).
    ControlPairs = maps:get(controlPairs, Window, array:from_list([])),
    %% Steps to emit: every absolute step S such that
    %%   last_step < S < floor(LookAhead * 32)
    %% On the very first window, also catch up from CurrentCycle (we
    %% don't emit retroactively for events that should have happened
    %% before `now`).
    LastStep = State#st.last_step,
    StartStep =
        if LastStep =:= -1 -> trunc(CurrentCycle * ?STEPS_PER_CYCLE);
           true            -> LastStep + 1
        end,
    EndStepExcl = trunc(LookAhead * ?STEPS_PER_CYCLE),
    case EndStepExcl > StartStep of
        false -> State;
        true ->
            Steps = lists:seq(StartStep, EndStepExcl - 1),
            FinalState = lists:foldl(
                fun(S, Acc) ->
                    emit_step(S, ControlPairs, CurrentCycle, CycleDurMs, NowUs, Acc)
                end, State, Steps),
            FinalState#st{last_step = EndStepExcl - 1}
    end.

%% Emit a single Grids step S.  S is absolute (across cycles); the
%% wrap to 0..31 happens here.  Per the parameter-as-Pattern lift,
%% the seven parameter values come from a PureScript-side query
%% (`Tidal.Grids.evaluateParamsAt`) against the live GridsConfig at
%% this step's cycle position.  At step-in-pattern 0, regenerate
%% perturbations using the randomness value as scale.
emit_step(S, ControlPairs, CurrentCycle, CycleDurMs, NowUs, State0) ->
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
            'tidal_grids@ps':evaluateParamsAt(Cfg, ControlPairs, StepCycle)
    end,
    X       = maps:get(x,          Snap),
    Y       = maps:get(y,          Snap),
    FBd     = maps:get(fillBd,     Snap),
    FSd     = maps:get(fillSd,     Snap),
    FHh     = maps:get(fillHh,     Snap),
    Random  = maps:get(randomness, Snap),
    State1 =
        if StepInPat =:= 0 ->
               {Perts, RngNext} =
                   grids_engine:fresh_perturbations(Random, State0#st.rng_state),
               State0#st{perturbations = Perts, rng_state = RngNext};
           true ->
               State0
        end,
    Triggers = grids_engine:evaluate_step(
                 StepInPat, X, Y,
                 [FBd, FSd, FHh],
                 State1#st.perturbations),
    WallUs = round(NowUs + (StepCycle - CurrentCycle) * CycleDurMs * 1000),
    lists:foreach(fun(T) -> emit_trigger(T, WallUs, State1) end, Triggers),
    State1.

emit_trigger({Inst, Accent}, WallUs, State) ->
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
