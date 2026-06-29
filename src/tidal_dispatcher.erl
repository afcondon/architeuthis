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
         set_link_tempo/1,
         register_osc_router/3,
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

%% Broadcast a new BPM to link-spike (which propagates it to all
%% Link peers). Cast — fire-and-forget; the dispatcher's PS handler
%% sends `/link/set-tempo` via its bridgeClient socket.
set_link_tempo(Bpm) ->
    gen_server:cast(?MODULE, {set_link_tempo, Bpm}).

%% Open (or replace) the OSC client for a router alias at runtime.
%% Called when a session declares a `registerCvRouter <alias> <host>
%% <port>` endpoint, so the typed Studio `CvRouter` / SuperDirt
%% declarations open real sockets at the aliases the dispatcher routes
%% against.  Idempotent — re-registering an alias swaps its socket.
register_osc_router(Alias, Host, Port) ->
    gen_server:call(?MODULE, {register_osc_router, Alias, Host, Port}).

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
    %% Alias-type registry for the routing-grammar (Calypso composition
    %% grammar) device declarations.  Keyed by alias binary; value is
    %% {Alias, Type, Parent, Detail} where Type ∈ {midi, fh2, yarns,
    %% es9, es5, esx_8gt, esx_8cv, fhx_8gt, osc}, Parent is the parent
    %% alias binary for expanders (or `undefined`), and Detail is a map
    %% with type-specific extras (port, host, etc).  Read by Handler.erl
    %% to resolve `gate`/`cv` bindings against their device's type.
    case ets:info(tidal_alias_types) of
        undefined ->
            ets:new(tidal_alias_types, [set, public, named_table]);
        _ -> ok
    end,
    %% FH-2 voice → channel/output/mode mapping populated by `fh2-config`,
    %% read by the `gate` verb when its target is an FH-2 alias.  Keyed
    %% by {AliasBin, Voice}.
    case ets:info(tidal_fh2_voices) of
        undefined ->
            ets:new(tidal_fh2_voices, [set, public, named_table]);
        _ -> ok
    end,
    %% Configurable via the purerl_tidal application env. Defaults
    %% match Main.purs's existing GateConfig.
    %%
    %% PR 2c.2 / workstream C: the `es9` alias moved off 57120 to 57130
    %% so the conventional Dirt port (57120) is free for a real SuperDirt
    %% instance, reached via the `superdirt` alias.  es9-daemon's own
    %% listen port and link-spike's ES9_DAEMON_ADDR were moved to match.
    GateEnabled  = application:get_env(purerl_tidal, gateEnabled, true),
    GateHost     = application:get_env(purerl_tidal, gateHost, "127.0.0.1"),
    GatePort     = application:get_env(purerl_tidal, gatePort, 57130),
    GateDuration = application:get_env(purerl_tidal, gateDuration, 50.0),
    CvLeadMs     = application:get_env(purerl_tidal, cvLeadMs, 5.0),

    %% SuperDirt OSC target — the `superdirt` alias.  Enabled by default
    %% (a UDP send socket is harmless even with no SuperDirt listening);
    %% override host/port via app-env for a remote/non-default SC server.
    SuperDirtEnabled = application:get_env(purerl_tidal, superDirtEnabled, true),
    SuperDirtHost    = application:get_env(purerl_tidal, superDirtHost, "127.0.0.1"),
    SuperDirtPort    = application:get_env(purerl_tidal, superDirtPort, 57120),

    %% Bridge client — always open. Talks to link-spike on UDP 57122.
    BridgeClient = ('tidal_mIDIBridge@foreign':startClient())(),

    %% Per-alias OSC clients.  Built as a list of #{alias, client} so the
    %% PureScript side (`Dispatcher.initialState`) folds it into a Map
    %% String OSCClient.  `es9` is the CV/gate path; `superdirt` the audio
    %% path.  Each entry is gated by its enabled flag.
    OscClients =
        [ #{alias => <<"es9">>,
            client => open_osc(GateHost, GatePort)}
          || GateEnabled ]
        ++
        [ #{alias => <<"superdirt">>,
            client => open_osc(SuperDirtHost, SuperDirtPort)}
          || SuperDirtEnabled ],

    %% `oscClients` is a PureScript `Array` on the other side — purs-backend-erl
    %% represents that as Erlang's `array` module, so wrap the list (mirrors
    %% tidal_clock's controlPairs handoff).
    InitArgs = #{bridgeClient => BridgeClient,
                 oscClients   => array:from_list(OscClients),
                 gateDuration => float(GateDuration),
                 cvLeadMs     => float(CvLeadMs)},
    PsState = 'tidal_dispatcher@ps':initialState(InitArgs),
    {ok, PsState}.

%% Open a UDP OSC send socket for {Host, Port}, returning the opaque
%% OSCClient the PureScript layer threads through unread.
open_osc(Host, Port) ->
    Config = #{host => list_to_binary(Host), port => Port},
    ('tidal_oSC@foreign':startClient(Config))().

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
handle_call({register_osc_router, Alias, Host, Port}, _From, PsState) ->
    Client = open_osc(binary_to_list(iolist_to_binary(Host)), Port),
    NewState = 'tidal_dispatcher@ps':registerOscClient(Alias, Client, PsState),
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
    {noreply, NewState};
handle_cast({set_link_tempo, Bpm}, PsState) ->
    %% setLinkTempo is Effect Unit; thunk it but discard the result.
    %% State unchanged (this just sends OSC out the bridgeClient).
    ('tidal_dispatcher@ps':setLinkTempo(float(Bpm), PsState))(),
    {noreply, PsState}.

terminate(_Reason, _State) -> ok.
