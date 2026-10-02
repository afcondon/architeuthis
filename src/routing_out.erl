%% @doc Sending what `Reef.Routing` decided: one `Send` (a MIDI note, a
%% control change, or a `/dirt/play`), timed from a wall time in Unix
%% microseconds plus the send's own `atMs`. Shared by the voices the routing
%% table drives: the drums (reef_balistes_voice) and Odonus's heads
%% (reef_voice).
-module(routing_out).
-export([send/3]).

send(Sock, {note, M}, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, maps:get(port, M), maps:get(channel, M), maps:get(note, M),
              maps:get(velocity, M), maps:get(durMs, M), AtUs + round(maps:get(atMs, M) * 1000.0)),
    Thunk();
send(Sock, {play, M}, AtUs) ->
    %% A sample voice: one /dirt/play, timetagged. `n` goes as a float, as
    %% SuperDirt reads it; no sustain, so the window plays to its end.
    Msg = dirt_osc:encode_msg(<<"/dirt/play">>,
            [ <<"s">>, maps:get(s, M)
            , <<"n">>, float(maps:get(n, M))
            , <<"orbit">>, maps:get(orbit, M)
            , <<"begin">>, float(maps:get('begin', M))
            , <<"end">>, float(maps:get('end', M))
            , <<"speed">>, float(maps:get(speed, M))
            , <<"gain">>, float(maps:get(gain, M))
            , <<"amp">>, float(maps:get(amp, M))
            ]),
    dirt_osc:send_at(Sock, AtUs + round(maps:get(atMs, M) * 1000.0), Msg);
send(Sock, {control, M}, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleCCAt(
              Sock, maps:get(port, M), maps:get(channel, M), maps:get(controller, M),
              maps:get(value, M), AtUs + round(maps:get(atMs, M) * 1000.0)),
    Thunk().
