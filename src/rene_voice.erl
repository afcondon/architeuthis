%% @doc René machine voice gen_server — one instance per `rene`
%% Session binding.  Subscribes to master clock; per step, optionally
%% fires step_y (when the Y-clock pattern is true at this position),
%% always fires step_x, then emits MIDI for the new cursor cell.
%%
%% Architecture mirrors grids_voice / repetitor_voice.  Single MIDI
%% channel per [[feedback_drumkit_single_midi_channel]].  Live-mutable
%% via cell-text re-fire (set_config).  Phase 4 will add Twister-driven
%% live mutation through the live-control bus.
-module(rene_voice).
-behaviour(gen_server).

-export([start_link/2,
         compute_until/2,
         set_config/2,
         get_state/1,
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
    %% Engine state (rene_engine map).
    engine         :: map(),
    %% Live config — opaque PureScript ReneConfig value.  Per-step
    %% FFI query returns a snapshot of {step_y_now :: Bool}.
    cfg            :: term(),
    %% Engine running state.
    last_step      :: integer(),
    %% Output socket.
    midi_socket    :: gen_udp:socket() | undefined
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
%%   cfg              :: opaque PS ReneConfig | undefined
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

registered_name(Name) when is_atom(Name) ->
    binary_to_atom(<<"rene_voice_",
                     (atom_to_binary(Name, utf8))/binary>>, utf8);
registered_name(Name) when is_binary(Name) ->
    registered_name(binary_to_atom(Name, utf8)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({Name, Config}) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Engine = rene_engine:new(Config),
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
        midi_socket     = Sock
    },
    tidal_log:info(
      "rene_voice ~p started on ~s ch~B (nav=~p)~n",
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
    {reply, Snap, State}.

handle_cast({compute_until, Window}, State) ->
    NewState = process_window(Window, State),
    {noreply, NewState};
handle_cast({set_config, Cfg}, State) ->
    %% Cfg is a partial-update map.  Engine arrays (notes/skip/gate/
    %% glide) update via rene_engine:set_field which preserves the
    %% (x, y) cursor — same shape as Grids/Repetitor live-mutation:
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
                  Val       -> rene_engine:set_field(Eng, Field, Val)
              end
      end, Engine, Fields).

%% =========================================================================
%% Tick handling
%% =========================================================================

process_window(Window, State) ->
    CurrentCycle = maps:get(currentCycle,    Window),
    LookAhead    = maps:get(lookAheadCycle,  Window),
    CycleDurMs   = maps:get(cycleDurationMs, Window),
    NowUs        = maps:get(nowUnixUs,       Window),
    ControlPairs = maps:get(controlPairs, Window, array:from_list([])),
    StepsPerCycle = State#st.steps_per_cycle,
    LastStep = State#st.last_step,
    StartStep =
        if LastStep =:= -1 -> trunc(CurrentCycle * StepsPerCycle);
           true            -> LastStep + 1
        end,
    EndStepExcl = trunc(LookAhead * StepsPerCycle),
    case EndStepExcl > StartStep of
        false -> State;
        true ->
            Steps = lists:seq(StartStep, EndStepExcl - 1),
            FinalState = lists:foldl(
                fun(S, Acc) ->
                    emit_step(S, ControlPairs, CurrentCycle,
                              CycleDurMs, NowUs, Acc)
                end, State, Steps),
            FinalState#st{last_step = EndStepExcl - 1}
    end.

%% Emit a single step S.  Order:
%%   1. Query Y-clock pattern (true → step_y first).
%%   2. step_x (the master tick always advances X).
%%   3. read current cell; emit MIDI if not silent_step.
%%
%% The engine guarantees the cursor lands on a non-skipped cell, so
%% emit logic just discriminates emit vs silent_step.
emit_step(S, ControlPairs, CurrentCycle, CycleDurMs, NowUs, State) ->
    StepCycle = S / State#st.steps_per_cycle,
    WallUs = round(NowUs + (StepCycle - CurrentCycle) * CycleDurMs * 1000),
    StepYNow = case State#st.cfg of
        undefined -> false;
        Cfg ->
            Snap = 'tidal_rene@ps':evaluateParamsAt(
                     Cfg, ControlPairs, StepCycle),
            maps:get(stepYNow, Snap, false)
    end,
    Engine0 = State#st.engine,
    Engine1 = case StepYNow of
        true  -> rene_engine:step_y(Engine0);
        false -> Engine0
    end,
    Engine2 = rene_engine:step_x(Engine1),
    case rene_engine:current_event(Engine2) of
        {emit, Note, _Idx} ->
            emit_note(Note, WallUs, State);
        {silent_step, _Idx} ->
            ok
    end,
    State#st{engine = Engine2}.

emit_note(Note, WallUs, State) ->
    Thunk = tidal_mIDIBridge@foreign:scheduleNoteAt(
              State#st.midi_socket,
              State#st.port_name,
              State#st.channel,
              Note,
              State#st.vel,
              State#st.dur_ms,
              WallUs),
    Thunk(),
    ok.

%% =========================================================================
%% Helpers
%% =========================================================================

to_atom(N) when is_atom(N) -> N;
to_atom(N) when is_binary(N) -> binary_to_atom(N, utf8);
to_atom(N) when is_list(N) -> list_to_atom(N).

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8).
