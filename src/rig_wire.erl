%% @doc rig_wire: every OSC packet Architeuthis sends to Diaphus (UDP 57122)
%% and to es9-daemon (UDP 57130), encoded from the declared descriptions.
%%
%% The descriptions are `Wires.Daemons` (binnacle/wires), written once with
%% Hawser, and the declarations and vectors generated from them are in
%% binnacle/conformance (DIAPHUS-INBOUND.md, ES9-OSC.md). Nothing here lays
%% out bytes: each function builds the message's record and hands it to the
%% description's encoder. `test/rig_wire_tests.erl` holds the result, byte
%% for byte, to the vectors the two daemons read.
%%
%% A value that breaks a declared rule (a channel of 0, a bus of 16, a
%% negative length) is NOT sent. It is counted, and the first of each kind
%% is logged with its address and the rule's tag. Each function returns
%% `{ok, Packet}` or `{refused, Tag}`; `send/4` does the send or the count.
-module(rig_wire).
-export([note_at/6, on_at/5, off_at/4, cc_at/5, set_tempo/1]).
-export([cv/2, cv_slew/3, cv_trig/3, cv_trig_at/4, esx/2, esx5_gate/2]).
-export([gate/2, gate_trig/2, tidal_cv/2, tidal_cv_slew/3]).
-export([send/4, send_once/3, refused/0]).

%% ── To Diaphus ────────────────────────────────────────────────────────────

note_at(Port, Channel, Note, Velocity, DurationMs, UnixMicros) ->
    encode(noteAt, #{port => text(Port), channel => round(Channel), note => round(Note),
                     velocity => round(Velocity), durationMs => round(DurationMs),
                     unixMicros => micros(UnixMicros)}).

on_at(Port, Channel, Note, Velocity, UnixMicros) ->
    encode(noteOnAt, #{port => text(Port), channel => round(Channel), note => round(Note),
                       velocity => round(Velocity), unixMicros => micros(UnixMicros)}).

off_at(Port, Channel, Note, UnixMicros) ->
    encode(noteOffAt, #{port => text(Port), channel => round(Channel), note => round(Note),
                        unixMicros => micros(UnixMicros)}).

cc_at(Port, Channel, Controller, Value, UnixMicros) ->
    encode(controlAt, #{port => text(Port), channel => round(Channel),
                        controller => round(Controller), value => round(Value),
                        unixMicros => micros(UnixMicros)}).

set_tempo(Bpm) ->
    encode(setTempo, #{bpm => float(Bpm)}).

%% ── To es9-daemon ─────────────────────────────────────────────────────────

cv(Bus, Value) ->
    encode(cv, #{bus => round(Bus), value => float(Value)}).

cv_slew(Bus, Value, LagSeconds) ->
    encode(cvSlew, #{bus => round(Bus), value => float(Value), lagSeconds => float(LagSeconds)}).

cv_trig(Bus, Value, DurationMs) ->
    encode(cvTrig, #{bus => round(Bus), value => float(Value), durationMs => float(DurationMs)}).

cv_trig_at(Bus, Value, DurationMs, DelayMs) ->
    encode(cvTrigAt, #{bus => round(Bus), value => float(Value),
                       durationMs => float(DurationMs), delayMs => float(DelayMs)}).

esx(Slot, Value) ->
    encode(esx, #{slot => round(Slot), value => float(Value)}).

esx5_gate(Bit, State) ->
    encode(esx5Gate, #{bit => round(Bit), state => round(State)}).

gate(Channel, State) ->
    encode(tidalGate, #{channel => round(Channel), state => round(State)}).

gate_trig(Channel, DurationMs) ->
    encode(tidalGateTrig, #{channel => round(Channel), durationMs => float(DurationMs)}).

tidal_cv(Channel, Value) ->
    encode(tidalCv, #{channel => round(Channel), value => float(Value)}).

tidal_cv_slew(Channel, Value, LagSeconds) ->
    encode(tidalCvSlew, #{channel => round(Channel), value => float(Value),
                          lagSeconds => float(LagSeconds)}).

%% ── Sending ───────────────────────────────────────────────────────────────

%% Send an encoded message over an open socket. A refused one is counted and
%% not sent. Returns what gen_udp:send returns, or `{refused, Tag}`.
send(Socket, Host, Port, {ok, Packet}) ->
    gen_udp:send(Socket, Host, Port, Packet);
send(_Socket, _Host, _Port, {refused, _} = Refused) ->
    Refused.

%% Open a socket, send, close. For the delayed sends, which never reuse a
%% long-lived socket: one has been seen to die silently across an es9-daemon
%% restart.
send_once(Host, Port, {ok, Packet}) ->
    case gen_udp:open(0, [binary]) of
        {ok, Socket} ->
            Result = gen_udp:send(Socket, Host, Port, Packet),
            gen_udp:close(Socket),
            Result;
        Error ->
            Error
    end;
send_once(_Host, _Port, {refused, _} = Refused) ->
    Refused.

%% How many messages this node declined to send since it started.
refused() ->
    counters:get(counter(), 1).

%% ── The encoder ───────────────────────────────────────────────────────────

%% `Name` is the description's name in Wires.Daemons. Building a description
%% costs about 55 microseconds and encoding with it under 10, so each is
%% built once and kept.
encode(Name, Record) ->
    case hawser_osc@ps:encode(description(Name), Record) of
        {right, Bytes} ->
            {ok, list_to_binary(array:to_list(Bytes))};
        {left, Tag} ->
            count_refusal(Name, Tag),
            {refused, Tag}
    end.

description(Name) ->
    Key = {?MODULE, description, Name},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Description = wires_daemons@ps:Name(),
            persistent_term:put(Key, Description),
            Description;
        Description ->
            Description
    end.

counter() ->
    Key = {?MODULE, refused},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Counter = counters:new(1, [atomics]),
            persistent_term:put(Key, Counter),
            Counter;
        Counter ->
            Counter
    end.

%% Every refusal is counted. The first of each (message, rule) is logged.
count_refusal(Name, Tag) ->
    counters:add(counter(), 1, 1),
    Said = {?MODULE, said, Name, Tag},
    case persistent_term:get(Said, false) of
        false ->
            persistent_term:put(Said, true),
            tidal_log:err("rig_wire: not sending a ~s that breaks its declared "
                          "rule (~s); further ones are counted "
                          "(rig_wire:refused/0)~n", [Name, Tag]);
        true ->
            ok
    end.

text(Binary) when is_binary(Binary) -> Binary;
text(List) when is_list(List) -> unicode:characters_to_binary(List).

%% A moment goes on the wire as an int64 and is held by the description as
%% a Number, exact below 2^53 (the year 2255 in microseconds).
micros(UnixMicros) -> float(round(UnixMicros)).
