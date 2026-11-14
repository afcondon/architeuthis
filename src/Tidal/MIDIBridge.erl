%% FFI bindings for Tidal.MIDIBridge — sends OSC to link-spike's MIDI
%% dispatcher on UDP 127.0.0.1:57122. Replaces the os:cmd sendmidi
%% subprocess-spawn path with a single UDP send per event.

-module(tidal_mIDIBridge@foreign).
-export([startClient/0, scheduleNoteAt/7, scheduleNoteOnAt/6, scheduleNoteOffAt/5, scheduleCCAt/6, setLinkTempo/2]).
-export([learn_gate/1]).

-define(LINK_SPIKE_HOST, "127.0.0.1").
-define(LINK_SPIKE_PORT, 57122).

%% Open a UDP socket. The host/port are constants so we don't carry them
%% in the client — just the socket. Sockets are cheap; sharing one
%% across all events is fine.
startClient() ->
    fun() ->
        {ok, Socket} = gen_udp:open(0, [binary]),
        Socket
    end.

%% Learn (selene_midi, docs/kb/plans/selene-midi-signals.md): while one
%% Selene signal is learned, this is the one gate every MIDI message the rig
%% sends passes, and it lets through that signal's controller alone, so the
%% instrument learning hears nothing else. The gate is `off` (all pass),
%% `{Port, Channel, CC}` (that alone), or `shut` (learning a signal that has
%% no CC just now: none pass). A note-off always passes, so a note held when
%% learn begins still ends. Held in a persistent_term: read on every send,
%% written only when learn begins, ends or its signal moves.
-define(LEARN, {?MODULE, learn}).

learn_gate(Gate) ->
    case persistent_term:get(?LEARN, off) of
        Gate -> ok;
        _ when Gate =:= off -> persistent_term:erase(?LEARN), ok;
        _ -> persistent_term:put(?LEARN, Gate)
    end.

learning() -> persistent_term:get(?LEARN, off) =/= off.

cc_passes(PortName, Channel, CC) ->
    case persistent_term:get(?LEARN, off) of
        off -> true;
        {Port, Ch, C} -> Ch == Channel andalso C == CC andalso Port =:= ensure_binary(PortName);
        _ -> false
    end.

%% Send /midi/note/at.
scheduleNoteAt(Socket, PortName, Channel, Note, Velocity, DurationMs, UnixUsAt) ->
    fun() ->
        case learning() of
            true -> unit;
            false -> send_or_log(Socket, "scheduleNoteAt",
                                 rig_wire:note_at(PortName, Channel, Note, Velocity, DurationMs, UnixUsAt))
        end
    end.

%% Send /midi/on/at and /midi/off/at: a note held until its note-off, for
%% legato, where a held note's end is not known when it starts.
scheduleNoteOnAt(Socket, PortName, Channel, Note, Velocity, UnixUsAt) ->
    fun() ->
        case learning() of
            true -> unit;
            false -> send_or_log(Socket, "scheduleNoteOnAt",
                                 rig_wire:on_at(PortName, Channel, Note, Velocity, UnixUsAt))
        end
    end.

scheduleNoteOffAt(Socket, PortName, Channel, Note, UnixUsAt) ->
    fun() -> send_or_log(Socket, "scheduleNoteOffAt",
                         rig_wire:off_at(PortName, Channel, Note, UnixUsAt)) end.

%% gen_udp:send's result is checked though not propagated: a `closed`
%% error says the socket has died (its owning process exited), which would
%% otherwise be silent, and tidal_log:err always prints.
send_or_log(Socket, What, Message) ->
    case rig_wire:send(Socket, ?LINK_SPIKE_HOST, ?LINK_SPIKE_PORT, Message) of
        ok -> ok;
        %% Counted and logged by rig_wire.
        {refused, _} -> ok;
        {error, Reason} ->
            tidal_log:err("MIDIBridge.~s: gen_udp:send failed: ~p~n", [What, Reason])
    end,
    unit.

%% Send /midi/cc/at.
scheduleCCAt(Socket, PortName, Channel, CC, Value, UnixUsAt) ->
    fun() ->
        case cc_passes(PortName, Channel, CC) of
            true -> send_or_log(Socket, "scheduleCCAt",
                                rig_wire:cc_at(PortName, Channel, CC, Value, UnixUsAt));
            false -> unit
        end
    end.

%% Send /link/set-tempo. link-spike's handler captures its AblLink
%% session, mutates tempo, commits — Link broadcasts to all peers.
setLinkTempo(Socket, Bpm) ->
    fun() -> send_or_log(Socket, "setLinkTempo", rig_wire:set_tempo(Bpm)) end.

%% The packets are laid out by rig_wire, from the declared descriptions
%% (binnacle/conformance/DIAPHUS-INBOUND.md). A value that breaks a declared
%% rule is counted there and not sent.

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> list_to_binary(L).
