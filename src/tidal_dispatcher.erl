%% @doc Dispatcher — gen_server owning OSC + MIDI bridge sockets and
%% routing voice events to the appropriate destination.
%%
%% Voices push events here as `dispatch_event/3` casts:
%%   {event, BindingName, Token, WallTimeUs}
%%
%% The dispatcher looks up `BindingName` in its binding cache, walks
%% each PrimAction (Gate / CV / ESX / ES5Gate / MidiNote / MidiCC),
%% and formats + sends the appropriate OSC / MIDI. Logic lives in
%% `Tidal.Dispatcher` (PureScript); this module is the Erlang shell
%% holding the gen_server callbacks and the OSC/bridge client handles.
%%
%% Sockets are opened in init/1 — they're linked to this process and
%% close when it exits, so socket lifetime tracks dispatcher lifetime
%% (which is supervised by purerl_tidal_sup).
%%
%% PR1.4c implementation note: still scaffolding for the real boot
%% path. The bindings cache is empty until PR1.4d wires the WS handler
%% to call `set_binding` on `bind` verbs; until then, voices that push
%% events here will hit the unknown-binding silent no-op path.
%%
%% See `docs/per-voice-refactor-plan.md`.
-module(tidal_dispatcher).
-behaviour(gen_server).

-export([start_link/0,
         dispatch_event/4,
         dispatch_cont_event/3,
         set_binding/2,
         set_binding_from_spec/2,
         set_continuous_binding/2,
         remove_binding/1,
         lookup_binding/1,
         lookup_continuous_binding/1,
         register_midi_device/3,
         set_fh2_voice_channel/2,
         dispatch_fh2_shape/5,
         get_info/0,
         get_publisher_snapshot/0,
         stop/0]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

%% =========================================================================
%% Public API
%% =========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Voices cast events here. `Params` is a map of pre-sampled per-event
%% values for `#`-joined parameter patterns (Map String String at the
%% PureScript level; Erlang `#{}` here). Dispatcher uses it for slot
%% overrides on the matching PrimAction (e.g. `vel` → MidiNote.velocity)
%% and compositional fanout to other registered bindings.
dispatch_event(BindingName, Token, WallTimeUs, Params) ->
    gen_server:cast(?MODULE,
                    {event, BindingName, Token, WallTimeUs, Params}).

%% Continuous-voice event cast. Value is a 0..1 (or wider, with
%% transforms) Number; the dispatcher consults `continuousBindings` to
%% pick the destination (MIDI CC or CV bus) and emits one update.
dispatch_cont_event(BindingName, Value, WallTimeUs) ->
    gen_server:cast(?MODULE,
                    {cont_event, BindingName, Value, WallTimeUs}).

%% Cache a binding for a voice name. Called by the WS handler when a
%% `bind` verb is processed (PR1.4d).
set_binding(Name, Binding) ->
    gen_server:call(?MODULE, {set_binding, Name, Binding}).

%% Cache a continuous-voice destination for a voice name. The WS
%% handler can use this directly when it has an already-parsed
%% ContDest term; in the typical bind flow `set_binding_from_spec`
%% already covers this since it tries parseContBinding first.
set_continuous_binding(Name, Dest) ->
    gen_server:call(?MODULE, {set_continuous_binding, Name, Dest}).

%% Parse a `bind <name> <action-spec>` body and install the resulting
%% Binding. Called by the WS handler at PR1.4d-i so the dispatcher
%% gets the parsed binding without the WS handler having to call into
%% PureScript itself. Returns `ok` on success, `{error, Reason}` on
%% parse failure (the caller logs and continues — the dual-write means
%% MIDIScheduler is the user-visible error path during transition).
set_binding_from_spec(Name, ActionSpec) ->
    gen_server:call(?MODULE, {set_binding_from_spec, Name, ActionSpec}).

remove_binding(Name) ->
    gen_server:call(?MODULE, {remove_binding, Name}).

%% Look up a binding by name. Used by the WS handler at PR1.4d-ii-b
%% to decide whether the play verb routes to the new voice tree
%% (binding exists) or falls back to MIDIScheduler's legacy path.
%% Returns `{just, Binding}` or `{nothing}` (purs-backend-erl Maybe
%% encoding — the caller pattern-matches on the tuple).
lookup_binding(Name) ->
    gen_server:call(?MODULE, {lookup_binding, Name}).

%% Look up a continuous binding by name. Used by the PR1.5-b WS
%% handler — falls back to this when `lookup_binding` returns
%% `{nothing}` so the play-by-name-expr verb can route a continuous
%% voice through `tidal_voice_sup:set_voice_cont_pat`.
%% Returns `{just, ContDest}` or `{nothing}`.
lookup_continuous_binding(Name) ->
    gen_server:call(?MODULE, {lookup_continuous_binding, Name}).

%% Register a MIDI device alias. Mirrors the existing
%% `midi-device <alias> <real-name> [lat <ms>]` verb.
register_midi_device(Alias, DeviceName, LatencyMs) ->
    gen_server:call(?MODULE,
                    {register_midi_device, Alias, DeviceName, LatencyMs}).

%% Map an FH-2 voice index to a MIDI channel. Called by the WS
%% handler's `fh2-envelope` verb so subsequent Fh2Trigger PrimAction
%% dispatches can resolve the channel. Idempotent — re-registration
%% replaces the channel mapping for that voice.
set_fh2_voice_channel(Voice, Channel) ->
    gen_server:call(?MODULE,
                    {set_fh2_voice_channel, Voice, Channel}).

%% Live ADSR push for an FH-2 voice. Sends 4 MIDI CCs (per-MCV
%% offset 70..73 / 74..77 / …) on the voice's MIDI channel. Cast,
%% not call — fire-and-forget; the dispatcher's PS handler emits
%% scheduleCCAt directly.
dispatch_fh2_shape(Voice, A, D, S, R) ->
    gen_server:cast(?MODULE,
                    {fh2_shape, Voice, A, D, S, R}).

get_info() ->
    gen_server:call(?MODULE, get_info).

%% Snapshot for the state publisher (tidal_state_pub). Returns the
%% PureScript record opaque to Erlang — passed straight through to
%% Tidal.StatePublisher.serializeSnapshot.
get_publisher_snapshot() ->
    gen_server:call(?MODULE, get_publisher_snapshot).

stop() ->
    gen_server:stop(?MODULE).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init([]) ->
    %% Configurable via the purerl_tidal application env. Defaults
    %% match Main.purs's existing GateConfig.
    GateEnabled  = application:get_env(purerl_tidal, gateEnabled, true),
    GateHost     = application:get_env(purerl_tidal, gateHost, "127.0.0.1"),
    GatePort     = application:get_env(purerl_tidal, gatePort, 57120),
    GateDuration = application:get_env(purerl_tidal, gateDuration, 50.0),
    CvLeadMs     = application:get_env(purerl_tidal, cvLeadMs, 5.0),

    %% Bridge client — always open. Talks to link-spike on UDP 57122.
    BridgeClient = ('tidal_mIDIBridge@foreign':startClient())(),

    %% OSC client — opened only if gate output is enabled. Maybe-typed
    %% on the PureScript side, encoded as {just, Client} | {nothing}.
    OscClient = case GateEnabled of
        true ->
            Config = #{host => list_to_binary(GateHost),
                       port => GatePort},
            Client = ('tidal_oSC@foreign':startClient(Config))(),
            {just, Client};
        false ->
            {nothing}
    end,

    InitArgs = #{bridgeClient => BridgeClient,
                 oscClient    => OscClient,
                 gateDuration => float(GateDuration),
                 cvLeadMs     => float(CvLeadMs)},
    PsState = 'tidal_dispatcher@ps':initialState(InitArgs),
    {ok, PsState}.

handle_call({set_binding, Name, Binding}, _From, PsState) ->
    NewState = 'tidal_dispatcher@ps':setBinding(Name, Binding, PsState),
    {reply, ok, NewState};
handle_call({set_continuous_binding, Name, Dest}, _From, PsState) ->
    NewState = 'tidal_dispatcher@ps':setContinuousBinding(Name, Dest, PsState),
    {reply, ok, NewState};
handle_call({set_binding_from_spec, Name, ActionSpec}, _From, PsState) ->
    case 'tidal_dispatcher@ps':setBindingFromSpec(Name, ActionSpec, PsState) of
        {right, NewState} ->
            {reply, ok, NewState};
        {left, Err} ->
            %% Genuine parse error — neither `parseContBinding` nor
            %% `parseCompoundAction` matched. (As of PR1.5-a the
            %% dispatcher handles both shapes natively, so reaching
            %% Left here means the user's spec is malformed.)
            tidal_log:debug(
                "dispatcher: setBindingFromSpec ~s ignored: ~s~n",
                [Name, Err]),
            {reply, {error, Err}, PsState}
    end;
handle_call({remove_binding, Name}, _From, PsState) ->
    NewState = 'tidal_dispatcher@ps':removeBinding(Name, PsState),
    {reply, ok, NewState};
handle_call({lookup_binding, Name}, _From, PsState) ->
    {reply, 'tidal_dispatcher@ps':lookupBinding(Name, PsState), PsState};
handle_call({lookup_continuous_binding, Name}, _From, PsState) ->
    {reply, 'tidal_dispatcher@ps':lookupContinuousBinding(Name, PsState),
     PsState};
handle_call({register_midi_device, Alias, Name, Lat}, _From, PsState) ->
    Device = #{name => Name, latencyMs => float(Lat)},
    NewState = 'tidal_dispatcher@ps':registerMidiDevice(Alias, Device, PsState),
    {reply, ok, NewState};
handle_call({set_fh2_voice_channel, Voice, Channel}, _From, PsState) ->
    NewState = 'tidal_dispatcher@ps':setFh2VoiceChannel(
                 Voice, Channel, PsState),
    {reply, ok, NewState};
handle_call(get_info, _From, PsState) ->
    {reply, 'tidal_dispatcher@ps':snapshot(PsState), PsState};
handle_call(get_publisher_snapshot, _From, PsState) ->
    {reply, 'tidal_dispatcher@ps':publisherSnapshot(PsState), PsState}.

handle_cast({event, BindingName, Token, WallTimeUs, Params}, PsState) ->
    EventMap = #{name       => BindingName,
                 token      => Token,
                 wallTimeUs => float(WallTimeUs),
                 params     => Params},
    %% dispatchEvent is Effect-returning — execute the thunk.
    NewState = ('tidal_dispatcher@ps':dispatchEvent(EventMap, PsState))(),
    {noreply, NewState};
handle_cast({cont_event, BindingName, Value, WallTimeUs}, PsState) ->
    EventMap = #{name       => BindingName,
                 value      => float(Value),
                 wallTimeUs => float(WallTimeUs)},
    NewState = ('tidal_dispatcher@ps':dispatchContEvent(EventMap, PsState))(),
    {noreply, NewState};
handle_cast({fh2_shape, Voice, A, D, S, R}, PsState) ->
    %% Field name `sustain` rather than `s` because PureScript's
    %% record-pattern desugar would clash with the State pattern's
    %% own `s` binding inside dispatchFh2Shape.
    Args = #{voice => Voice, a => A, d => D, sustain => S, r => R},
    NewState = ('tidal_dispatcher@ps':dispatchFh2Shape(Args, PsState))(),
    {noreply, NewState}.

terminate(_Reason, _State) -> ok.
