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
                                 encode_note_at(PortName, Channel, Note, Velocity, DurationMs, UnixUsAt))
        end
    end.

%% Send /midi/on/at and /midi/off/at: a note held until its note-off, for
%% legato, where a held note's end is not known when it starts.
scheduleNoteOnAt(Socket, PortName, Channel, Note, Velocity, UnixUsAt) ->
    fun() ->
        case learning() of
            true -> unit;
            false -> send_or_log(Socket, "scheduleNoteOnAt",
                                 encode_on_at(PortName, Channel, Note, Velocity, UnixUsAt))
        end
    end.

scheduleNoteOffAt(Socket, PortName, Channel, Note, UnixUsAt) ->
    fun() -> send_or_log(Socket, "scheduleNoteOffAt",
                         encode_off_at(PortName, Channel, Note, UnixUsAt)) end.

%% gen_udp:send's result is checked though not propagated: a `closed`
%% error says the socket has died (its owning process exited), which would
%% otherwise be silent, and tidal_log:err always prints.
send_or_log(Socket, What, Packet) ->
    case gen_udp:send(Socket, ?LINK_SPIKE_HOST, ?LINK_SPIKE_PORT, Packet) of
        ok -> ok;
        {error, Reason} ->
            tidal_log:err("MIDIBridge.~s: gen_udp:send failed: ~p~n", [What, Reason])
    end,
    unit.

%% Send /midi/cc/at.
scheduleCCAt(Socket, PortName, Channel, CC, Value, UnixUsAt) ->
    fun() ->
        case cc_passes(PortName, Channel, CC) of
            true -> send_or_log(Socket, "scheduleCCAt",
                                encode_cc_at(PortName, Channel, CC, Value, UnixUsAt));
            false -> unit
        end
    end.

%% Send /link/set-tempo. link-spike's handler captures its AblLink
%% session, mutates tempo, commits — Link broadcasts to all peers.
setLinkTempo(Socket, Bpm) ->
    fun() ->
        Packet = encode_link_set_tempo(Bpm),
        case gen_udp:send(Socket, ?LINK_SPIKE_HOST, ?LINK_SPIKE_PORT, Packet) of
            ok -> ok;
            {error, Reason} ->
                tidal_log:err("MIDIBridge.setLinkTempo: gen_udp:send failed: ~p~n",
                              [Reason])
        end,
        unit
    end.

%% =========================================================================
%% OSC encoding
%% =========================================================================
%%
%% Inline rather than using Tidal.OSC's encode_args because we need an
%% int64 (h) typetag for the timestamp, which the existing encoder
%% doesn't generate. The existing encoder is also general-purpose
%% (infers types from Erlang values); ours is fixed-shape so it's
%% slightly faster — relevant when firing thousands of events/sec on
%% dense CC streams.

%% /midi/note/at  ,siiiih  port channel note velocity duration_ms unix_us_at
encode_note_at(PortName, Channel, Note, Velocity, DurationMs, UnixUsAt) ->
    Addr = pad_string(<<"/midi/note/at">>),
    TypeTag = pad_string(<<",siiiih">>),
    PortPadded = pad_string(ensure_binary(PortName)),
    Body = <<
        (round(Channel)):32/big-signed-integer,
        (round(Note)):32/big-signed-integer,
        (round(Velocity)):32/big-signed-integer,
        (round(DurationMs)):32/big-signed-integer,
        (round(UnixUsAt)):64/big-signed-integer
    >>,
    <<Addr/binary, TypeTag/binary, PortPadded/binary, Body/binary>>.

%% /midi/on/at  ,siiih  port channel note velocity unix_us_at
encode_on_at(PortName, Channel, Note, Velocity, UnixUsAt) ->
    Addr = pad_string(<<"/midi/on/at">>),
    TypeTag = pad_string(<<",siiih">>),
    PortPadded = pad_string(ensure_binary(PortName)),
    Body = <<
        (round(Channel)):32/big-signed-integer,
        (round(Note)):32/big-signed-integer,
        (round(Velocity)):32/big-signed-integer,
        (round(UnixUsAt)):64/big-signed-integer
    >>,
    <<Addr/binary, TypeTag/binary, PortPadded/binary, Body/binary>>.

%% /midi/off/at  ,siih  port channel note unix_us_at
encode_off_at(PortName, Channel, Note, UnixUsAt) ->
    Addr = pad_string(<<"/midi/off/at">>),
    TypeTag = pad_string(<<",siih">>),
    PortPadded = pad_string(ensure_binary(PortName)),
    Body = <<
        (round(Channel)):32/big-signed-integer,
        (round(Note)):32/big-signed-integer,
        (round(UnixUsAt)):64/big-signed-integer
    >>,
    <<Addr/binary, TypeTag/binary, PortPadded/binary, Body/binary>>.

%% /midi/cc/at  ,siiih  port channel cc value unix_us_at
encode_cc_at(PortName, Channel, CC, Value, UnixUsAt) ->
    Addr = pad_string(<<"/midi/cc/at">>),
    TypeTag = pad_string(<<",siiih">>),
    PortPadded = pad_string(ensure_binary(PortName)),
    Body = <<
        (round(Channel)):32/big-signed-integer,
        (round(CC)):32/big-signed-integer,
        (round(Value)):32/big-signed-integer,
        (round(UnixUsAt)):64/big-signed-integer
    >>,
    <<Addr/binary, TypeTag/binary, PortPadded/binary, Body/binary>>.

%% /link/set-tempo  ,f  bpm  — single 32-bit IEEE 754 big-endian float.
%% Link's tempo range is 20..999 BPM; clamp on the link-spike side.
encode_link_set_tempo(Bpm) ->
    Addr = pad_string(<<"/link/set-tempo">>),
    TypeTag = pad_string(<<",f">>),
    BpmF = case is_float(Bpm) of true -> Bpm; false -> float(Bpm) end,
    Body = <<BpmF:32/float-big>>,
    <<Addr/binary, TypeTag/binary, Body/binary>>.

%% Pad a string to a 4-byte boundary with at least one trailing null.
pad_string(Bin) when is_binary(Bin) ->
    Len = byte_size(Bin) + 1,
    Padding = (4 - (Len rem 4)) rem 4,
    <<Bin/binary, 0:8, 0:(Padding*8)>>.

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> list_to_binary(L).
