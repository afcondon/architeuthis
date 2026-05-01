%% FFI bindings for Tidal.MIDIBridge — sends OSC to link-spike's MIDI
%% dispatcher on UDP 127.0.0.1:57122. Replaces the os:cmd sendmidi
%% subprocess-spawn path with a single UDP send per event.

-module(tidal_mIDIBridge@foreign).
-export([startClient/0, scheduleNoteAt/7, scheduleCCAt/6]).

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

%% Send /midi/note/at.
scheduleNoteAt(Socket, PortName, Channel, Note, Velocity, DurationMs, UnixUsAt) ->
    fun() ->
        Packet = encode_note_at(PortName, Channel, Note, Velocity, DurationMs, UnixUsAt),
        gen_udp:send(Socket, ?LINK_SPIKE_HOST, ?LINK_SPIKE_PORT, Packet),
        unit
    end.

%% Send /midi/cc/at.
scheduleCCAt(Socket, PortName, Channel, CC, Value, UnixUsAt) ->
    fun() ->
        Packet = encode_cc_at(PortName, Channel, CC, Value, UnixUsAt),
        gen_udp:send(Socket, ?LINK_SPIKE_HOST, ?LINK_SPIKE_PORT, Packet),
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

%% Pad a string to a 4-byte boundary with at least one trailing null.
pad_string(Bin) when is_binary(Bin) ->
    Len = byte_size(Bin) + 1,
    Padding = (4 - (Len rem 4)) rem 4,
    <<Bin/binary, 0:8, 0:(Padding*8)>>.

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> list_to_binary(L).
