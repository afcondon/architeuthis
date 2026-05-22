%% @doc Clock — gen_statem driving the per-voice scheduler tick.
%%
%% States: `running` (timer fires `tick` every Config.tickIntervalMs ms)
%% and `paused` (no timer). Transitions are external events: `pause`
%% and `resume`.
%%
%% On each tick (in `running`):
%%   1. Read `tidal_link_anchor:scheduler_clock/2` for current beat-time
%%      (free-runs from Config.bpm if no Link anchor available).
%%   2. Compute the cycle window [now, now + lookAheadMs].
%%   3. Cast `{compute_until, EndCycle}` to every voice in
%%      `tidal_voice_sup`.
%%
%% PR1.3 introduces this module as scaffolding. It runs harmlessly even
%% when no voices exist (broadcast to empty list) and even when
%% tidal_voice_sup isn't started (early-return). Wired into the boot
%% path in PR1.4. See `docs/per-voice-refactor-plan.md`.
%%
%% Why gen_statem and not gen_server: pause/resume is a state-machine
%% concept (different message-handling shape per state). Modeling it as
%% explicit states is what gen_statem is for; bolting an "is_paused"
%% boolean onto a gen_server would scatter the state-dependent
%% behaviour across handle_call clauses.
-module(tidal_clock).
-behaviour(gen_statem).

-export([start_link/1,
         pause/0, resume/0,
         set_bpm/1, get_bpm/0,
         get_info/0,
         is_running/0,
         stop/0]).

-export([init/1, callback_mode/0,
         running/3, paused/3,
         terminate/3]).

%% =========================================================================
%% Public API
%% =========================================================================

%% Start the clock with config map:
%%   #{bpm => 110.0, tickIntervalMs => 50, lookAheadMs => 200.0,
%%     startTimeMs => Now}
start_link(Config) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, Config, []).

pause()       -> gen_statem:call(?MODULE, pause).
resume()      -> gen_statem:call(?MODULE, resume).
set_bpm(B)    -> gen_statem:call(?MODULE, {set_bpm, B}).
get_bpm()     -> gen_statem:call(?MODULE, get_bpm).
get_info()    -> gen_statem:call(?MODULE, get_info).
is_running()  -> gen_statem:call(?MODULE, is_running).
stop()        -> gen_statem:stop(?MODULE).

%% =========================================================================
%% gen_statem callbacks
%% =========================================================================

callback_mode() -> [state_functions].

init(Config) ->
    State = 'tidal_clock@ps':initialState(Config),
    Tick = maps:get(tickIntervalMs, Config),
    %% Start in `running` with first tick scheduled.
    {ok, running, State, [{state_timeout, Tick, tick}]}.

%% --- running state -------------------------------------------------------

running(state_timeout, tick, State) ->
    Info = 'tidal_clock@ps':info(State),
    Bpm = maps:get(bpm, Info),
    StartTimeMs = maps:get(startTimeMs, Info),
    Clock = tidal_link_anchor:scheduler_clock(round(StartTimeMs), Bpm),
    %% Anchor-log ghost trap: record transitions between anchored
    %% (Link-synced) and free-running modes.  Each transition shifts
    %% CurrentCycle, which can leave vmod voices' LastStep ahead of
    %% the new clock position → silent dropout in process_window.
    Synced = maps:get(synced, Clock, false),
    case persistent_term:get({tidal_clock, last_synced}, undefined) of
        Synced -> ok;
        Prev   ->
            tidal_anchor_log:record({clock_transition, Prev, Synced}),
            persistent_term:put({tidal_clock, last_synced}, Synced)
    end,
    ElapsedMs = maps:get(elapsedMs, Clock),
    CycleDur = maps:get(cycleDurationMs, Clock),
    LookAhead = maps:get(lookAheadMs, Info),
    NowUs = erlang:system_time(microsecond),
    %% Snapshot the live control bus.  PureScript's Window expects
    %% `Array { name :: String, value :: Number }` — and `Array a`
    %% in purs-backend-erl is the stdlib `array` module's
    %% representation, NOT a plain Erlang list.  Build the list of
    %% record-maps first, then wrap with `array:from_list/1` so the
    %% PureScript-side `Array.foldl` over `controlPairs` finds what
    %% it expects.  Reading on the clock's tick (rather than per
    %% voice) keeps the snapshot consistent across all voices in
    %% this scheduling pass.
    ControlPairsList = [#{name => K, value => V}
                        || {K, V} <- tidal_control_bus:snapshot()],
    ControlPairs = array:from_list(ControlPairsList),
    ControlVersion = tidal_control_bus:version(),
    %% Active scale for Degree → MIDI rendering — read once per tick
    %% so all voices in this pass see the same scale (set-scale
    %% mid-tick still atomic relative to event emission).
    ActiveScale = tidal_scale_bus:current_scale(),
    Window = #{currentCycle => ElapsedMs / CycleDur,
               lookAheadCycle => (ElapsedMs + LookAhead) / CycleDur,
               cycleDurationMs => CycleDur,
               nowUnixUs => float(NowUs),
               controlPairs => ControlPairs,
               controlVersion => ControlVersion,
               activeScale => ActiveScale},
    broadcast_compute_window(Window),
    broadcast_conductor(Window),
    Tick = maps:get(tickIntervalMs, Info),
    {keep_state_and_data, [{state_timeout, Tick, tick}]};
running({call, From}, pause, State) ->
    {next_state, paused, State, [{reply, From, ok}]};
running({call, From}, resume, _State) ->
    {keep_state_and_data, [{reply, From, ok}]};
running({call, From}, {set_bpm, B}, State) ->
    {keep_state, 'tidal_clock@ps':setBpm(B, State), [{reply, From, ok}]};
running({call, From}, get_bpm, State) ->
    Info = 'tidal_clock@ps':info(State),
    {keep_state_and_data, [{reply, From, maps:get(bpm, Info)}]};
running({call, From}, get_info, State) ->
    Snap = 'tidal_clock@ps':snapshot(State),
    {keep_state_and_data, [{reply, From, maps:put(running, true, Snap)}]};
running({call, From}, is_running, _State) ->
    {keep_state_and_data, [{reply, From, true}]};
running(info, _Msg, _State) ->
    %% Drop unexpected info messages (typically late timeout-receive
    %% leaks from sibling Erlang processes like tidal_link_anchor — see
    %% the call/1 timeout pattern there).  We don't log per-drop because
    %% the rate can be high under load; if a real-time-sensitive consumer
    %% sends to the clock, route it via gen_statem:cast/call instead.
    {keep_state_and_data, []}.

%% --- paused state --------------------------------------------------------

paused({call, From}, pause, _State) ->
    {keep_state_and_data, [{reply, From, ok}]};
paused({call, From}, resume, State) ->
    Info = 'tidal_clock@ps':info(State),
    Tick = maps:get(tickIntervalMs, Info),
    {next_state, running, State, [{reply, From, ok},
                                  {state_timeout, Tick, tick}]};
paused({call, From}, {set_bpm, B}, State) ->
    {keep_state, 'tidal_clock@ps':setBpm(B, State), [{reply, From, ok}]};
paused({call, From}, get_bpm, State) ->
    Info = 'tidal_clock@ps':info(State),
    {keep_state_and_data, [{reply, From, maps:get(bpm, Info)}]};
paused({call, From}, get_info, State) ->
    Snap = 'tidal_clock@ps':snapshot(State),
    {keep_state_and_data, [{reply, From, maps:put(running, false, Snap)}]};
paused({call, From}, is_running, _State) ->
    {keep_state_and_data, [{reply, From, false}]};
paused(info, _Msg, _State) ->
    %% Same defensive drop as in `running` — late timeout-receive leaks
    %% from sibling processes mustn't take the clock down.
    {keep_state_and_data, []}.

terminate(_Reason, _StateName, _State) ->
    ok.

%% =========================================================================
%% Internal
%% =========================================================================

%% Broadcast `{compute_until, Window}` to every voice in tidal_voice_sup
%% AND every BEAM-native virtual-module voice (currently just
%% balistes_voice_sup; future vmods can opt in by adding their supervisor
%% to the broadcast list).  Window is a map with currentCycle,
%% lookAheadCycle, cycleDurationMs, nowUnixUs — sufficient for each
%% voice to convert its pattern's cycle-events to absolute Unix
%% microsecond wall times.  Safe when any supervisor isn't started yet
%% (returns ok immediately) or has no children.
broadcast_compute_window(Window) ->
    broadcast_to(tidal_voice_sup, fun tidal_voice_sup:which_voices/0, Window),
    broadcast_to(balistes_voice_sup, fun balistes_voice_sup:which_voices/0, Window),
    broadcast_to(repetitor_voice_sup, fun repetitor_voice_sup:which_voices/0, Window),
    broadcast_to(odonus_voice_sup, fun odonus_voice_sup:which_voices/0, Window),
    broadcast_to(virtual_polysignal_voice_sup,
                 fun virtual_polysignal_voice_sup:which_voices/0, Window),
    ok.

broadcast_to(SupName, WhichFn, Window) ->
    case whereis(SupName) of
        undefined -> ok;
        _ ->
            [gen_server:cast(V, {compute_until, Window}) || V <- WhichFn()],
            ok
    end.

%% Forward the tick window to the conductor (MVP-2 section-firing).
%% Tight no-op when no piece is active so the broadcast is cheap
%% even when sections are unused.
broadcast_conductor(Window) ->
    case whereis(tidal_conductor) of
        undefined -> ok;
        _ -> tidal_conductor:compute_until(Window)
    end.
