%% @doc Repetitor (ZR-inspired) voice gen_server — one instance per
%% `repetitor` Session binding.  Subscribes (via tidal_clock's
%% broadcast) to the master `{compute_until, Window}` ticks; on each
%% tick, emits any pattern steps that fall in the window.
%%
%% Architecture mirrors balistes_voice.  Phase 2 (this file): config is a
%% static map containing pattern slug + per-row offsets.  Phase 3
%% swaps in a PS-side FFI call against a Foreign config so offsets
%% become `Pattern Int` slots.
%%
%% Output: M/C1/C2/C3 fire on a single MIDI channel with four distinct
%% note numbers (per
%% [[feedback_drumkit_single_midi_channel]] — all drumkit-style
%% emitters use one channel + per-row notes, never per-row channels).
-module(repetitor_voice).
-behaviour(gen_server).

-export([start_link/2,
         compute_until/2,
         set_config/2,
         get_state/1,
         registered_name/1]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

%% Number of pattern steps per Tidal cycle.  Default 4 = one step
%% per beat (assuming 4/4 cycle = 4 beats).  Mirrors the hardware
%% ZR, where the BEAT input clocks one pattern step per pulse — a
%% beat is a beat.  Pattern length then determines how many cycles
%% before the pattern repeats: King 1 (length 12) spans 3 cycles,
%% Chachar (length 32) spans 8.  Pattern lengths != cycle length
%% are the *point* — the engine plays polyrhythmically against the
%% bar by construction.  Override via the `steps_per_cycle` config
%% key (e.g. 2 for half-note clocking, 8 for eighth-note clocking).
-define(DEFAULT_STEPS_PER_CYCLE, 4).

-define(ROWS, [m, c1, c2, c3]).

-record(st, {
    name           :: atom(),
    %% MIDI output config.
    port_name      :: binary(),
    channel        :: 1..16,
    note_m         :: 0..127,
    note_c1        :: 0..127,
    note_c2        :: 0..127,
    note_c3        :: 0..127,
    vel            :: 0..127,
    dur_ms         :: 1..2000,
    steps_per_cycle :: pos_integer(),
    %% Engine config.
    library_mod    :: module(),       % e.g. repetitor_library_zr_african
    pattern_slug   :: atom() | binary(),  % atom key or binary name
    cfg            :: term(),         % opaque PS RepetitorConfig — per-step FFI
    %% Static fallback offsets (used when cfg is undefined).
    offsets        :: map(),          % #{m, c1, c2, c3 => Int}
    %% Cached current pattern (refreshed when pattern_slug changes).
    pattern        :: map() | undefined,
    %% Engine running state.
    last_step      :: integer(),   % absolute step counter; -1 before first emit
    %% Output socket.
    midi_socket    :: gen_udp:socket() | undefined,
    %% F-LAT — device latency compensation in microseconds.  See
    %% rene_voice.erl + tools/timing-data/phase-4-diagnostic-f1/.
    latency_us     :: integer(),
    %% F1 — cache the per-tick ControlMap; rebuild only on bus version bump.
    control_version :: integer(),
    cached_controls :: term() | undefined
}).

%% =========================================================================
%% Public API
%% =========================================================================

%% Config keys (all required unless noted):
%%   port_name        :: binary()
%%   channel          :: 1..16
%%   note_m           :: 0..127 (default 36)
%%   note_c1          :: 0..127 (default 38)
%%   note_c2          :: 0..127 (default 40)
%%   note_c3          :: 0..127 (default 41)
%%   vel              :: 0..127 (default 100)
%%   dur_ms           :: integer (default 30)
%%   steps_per_cycle  :: pos_integer (default 16)
%%   library_mod      :: atom — module name like repetitor_library_zr_african
%%   pattern_slug     :: atom — pattern key in that library
%%   offsets          :: #{m, c1, c2, c3 => Int} (defaults 0)
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
    binary_to_atom(<<"repetitor_voice_",
                     (atom_to_binary(Name, utf8))/binary>>, utf8);
registered_name(Name) when is_binary(Name) ->
    registered_name(binary_to_atom(Name, utf8)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({Name, Config}) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    LibMod = maps:get(library_mod, Config),
    Slug   = maps:get(pattern_slug, Config),
    {ok, Pat} = LibMod:pattern(Slug),
    State = #st{
        name            = Name,
        port_name       = ensure_binary(maps:get(port_name, Config)),
        channel         = maps:get(channel,    Config),
        note_m          = maps:get(note_m,     Config, 36),
        note_c1         = maps:get(note_c1,    Config, 38),
        note_c2         = maps:get(note_c2,    Config, 40),
        note_c3         = maps:get(note_c3,    Config, 41),
        vel             = maps:get(vel,        Config, 100),
        dur_ms          = maps:get(dur_ms,     Config, 30),
        steps_per_cycle = maps:get(steps_per_cycle, Config, ?DEFAULT_STEPS_PER_CYCLE),
        library_mod     = LibMod,
        pattern_slug    = Slug,
        cfg             = maps:get(cfg, Config, undefined),
        offsets         = normalise_offsets(maps:get(offsets, Config, #{})),
        pattern         = Pat,
        last_step       = -1,
        midi_socket     = Sock,
        latency_us      = round(maps:get(latency_ms, Config, 0.0) * 1000),
        control_version = -1,
        cached_controls = undefined
    },
    tidal_log:info(
      "repetitor_voice ~p started on ~s ch~B (pattern ~p, M/C1/C2/C3 ~B/~B/~B/~B)~n",
      [Name, State#st.port_name, State#st.channel, Slug,
       State#st.note_m, State#st.note_c1, State#st.note_c2, State#st.note_c3]),
    {ok, State}.

handle_call(get_state, _From, State) ->
    Snap = #{
        name         => State#st.name,
        port_name    => State#st.port_name,
        channel      => State#st.channel,
        pattern_slug => State#st.pattern_slug,
        offsets      => State#st.offsets,
        last_step    => State#st.last_step
    },
    {reply, Snap, State}.

handle_cast({compute_until, Window}, State) ->
    NewState = process_window(Window, State),
    {noreply, NewState};
handle_cast({set_config, Cfg}, State) ->
    %% Cfg is a partial-update map.  Pattern slug change triggers
    %% pattern re-lookup; cfg payload + offsets update in place;
    %% MIDI routing is set-once at start_link.
    NewSlug = maps:get(pattern_slug, Cfg, State#st.pattern_slug),
    NewPat = case NewSlug =:= State#st.pattern_slug of
        true  -> State#st.pattern;
        false ->
            {ok, P} = (State#st.library_mod):pattern(NewSlug),
            P
    end,
    NewCfg = maps:get(cfg, Cfg, State#st.cfg),
    NewOffsets = case maps:get(offsets, Cfg, undefined) of
        undefined -> State#st.offsets;
        Off       -> normalise_offsets(Off)
    end,
    {noreply, State#st{pattern_slug = NewSlug,
                       pattern      = NewPat,
                       cfg          = NewCfg,
                       offsets      = NewOffsets}}.

terminate(_Reason, State) ->
    case State#st.midi_socket of
        undefined -> ok;
        Sock -> catch gen_udp:close(Sock)
    end,
    ok.

%% =========================================================================
%% Tick handling
%% =========================================================================

%% Process a {compute_until, Window} broadcast.  Emit any pattern
%% steps whose absolute index lies in (last_step, EndStep].
process_window(Window, State) ->
    CurrentCycle = maps:get(currentCycle,    Window),
    LookAhead    = maps:get(lookAheadCycle,  Window),
    CycleDurMs   = maps:get(cycleDurationMs, Window),
    NowUs        = maps:get(nowUnixUs,       Window),
    ControlPairs = maps:get(controlPairs, Window, array:from_list([])),
    ControlVersion = maps:get(controlVersion, Window, -1),
    %% F1 — cache the per-tick ControlMap; rebuild only on version change.
    {Controls, State1} =
        case ControlVersion =:= State#st.control_version
             andalso State#st.cached_controls =/= undefined of
            true ->
                {State#st.cached_controls, State};
            false ->
                Built = 'tidal_repetitor@ps':buildControlMap(ControlPairs),
                {Built, State#st{control_version = ControlVersion,
                                 cached_controls = Built}}
        end,
    StepsPerCycle = State1#st.steps_per_cycle,
    LastStep = State1#st.last_step,
    StartStep =
        if LastStep =:= -1 -> trunc(CurrentCycle * StepsPerCycle);
           true            -> LastStep + 1
        end,
    %% F-FUTURE — discover one step ahead so WallUs lands in the future.
    EndStepExcl = trunc(LookAhead * StepsPerCycle) + 1,
    case EndStepExcl - StartStep > 8 of
        true ->
            tidal_anchor_log:record({voice_step_burst, State1#st.name,
                                     StartStep, EndStepExcl, CurrentCycle,
                                     StepsPerCycle});
        false -> ok
    end,
    case EndStepExcl > StartStep of
        false ->
            tidal_anchor_log:record({voice_dropout, State1#st.name,
                                     State1#st.last_step,
                                     CurrentCycle, EndStepExcl, StepsPerCycle}),
            State1;
        true ->
            Steps = lists:seq(StartStep, EndStepExcl - 1),
            FinalState = lists:foldl(
                fun(S, Acc) ->
                    emit_step(S, Controls, CurrentCycle,
                              CycleDurMs, NowUs, Acc)
                end, State1, Steps),
            FinalState#st{last_step = EndStepExcl - 1}
    end.

%% Emit a single step S (absolute across cycles).  Pattern's own
%% length L wraps separately from the master cycle, producing the
%% characteristic ZR cross-cycle hits-against-the-bar pattern.
%% When cfg is a Foreign payload, query PureScript per step so the
%% four offset slots can be live patterns (Pattern Int).
emit_step(S, Controls, CurrentCycle, CycleDurMs, NowUs, State) ->
    Pat = State#st.pattern,
    StepCycle = S / State#st.steps_per_cycle,
    Offsets = case State#st.cfg of
        undefined -> State#st.offsets;
        Cfg ->
            Snap = 'tidal_repetitor@ps':evaluateParamsAtControls(
                     Cfg, Controls, StepCycle),
            #{m  => maps:get(offsetM,  Snap, 0),
              c1 => maps:get(offsetC1, Snap, 0),
              c2 => maps:get(offsetC2, Snap, 0),
              c3 => maps:get(offsetC3, Snap, 0)}
    end,
    %% F-LAT — subtract device latency.
    WallUs = round(NowUs + (StepCycle - CurrentCycle) * CycleDurMs * 1000)
             - State#st.latency_us,
    Bits = repetitor_engine:evaluate_step(Pat, S, Offsets),
    lists:foreach(
      fun({_, 0}) -> ok;
         ({Row, 1}) -> emit_row(Row, WallUs, State)
      end, Bits),
    State.

emit_row(Row, WallUs, State) ->
    Note = note_for(Row, State),
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

note_for(m,  S) -> S#st.note_m;
note_for(c1, S) -> S#st.note_c1;
note_for(c2, S) -> S#st.note_c2;
note_for(c3, S) -> S#st.note_c3.

%% =========================================================================
%% Helpers
%% =========================================================================

normalise_offsets(Off) when is_map(Off) ->
    maps:from_list(
      [{Row, maps:get(Row, Off, 0)} || Row <- ?ROWS]).

to_atom(N) when is_atom(N) -> N;
to_atom(N) when is_binary(N) -> binary_to_atom(N, utf8);
to_atom(N) when is_list(N) -> list_to_atom(N).

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8).
