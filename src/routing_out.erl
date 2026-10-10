%% @doc Sending what `Reef.Routing` and `Reef.Articulation` decided: one
%% `Send` (a MIDI note, a held note's on or off, a control change, a
%% `/dirt/play`, or an ES-9 bus set, slewed or pulsed), timed from a wall time
%% in Unix microseconds plus the send's own `atMs`. Shared by the voices the
%% routing table drives: the drums (reef_balistes_voice) and the melodic
%% voices (reef_voice, vetula_cards). The rig is the only sender to hardware
%% (docs/kb/plans/hardware-through-the-rig.md).
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
send(Sock, {noteOn, M}, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteOnAt(
              Sock, maps:get(port, M), maps:get(channel, M), maps:get(note, M),
              maps:get(velocity, M), at(M, AtUs)),
    Thunk();
send(Sock, {noteOff, M}, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteOffAt(
              Sock, maps:get(port, M), maps:get(channel, M), maps:get(note, M), at(M, AtUs)),
    Thunk();
%% es9-daemon times a pulse to the sample itself, from its delay; a set or a
%% slew has no timed form, so the BEAM holds it until its moment.
send(Sock, {cvPulse, M}, AtUs) ->
    es9_cv:send_trig_at(Sock, maps:get(bus, M), maps:get(value, M), maps:get(durMs, M),
                        delay_ms(at(M, AtUs)));
send(Sock, {cvSet, M}, AtUs) ->
    later(at(M, AtUs), es9_cv, send_cv, [Sock, maps:get(bus, M), maps:get(value, M)]);
send(Sock, {cvSlew, M}, AtUs) ->
    later(at(M, AtUs), es9_cv, send_slew,
          [Sock, maps:get(bus, M), maps:get(value, M), maps:get(lagSec, M)]);
send(Sock, {control, M}, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleCCAt(
              Sock, maps:get(port, M), maps:get(channel, M), maps:get(controller, M),
              maps:get(value, M), AtUs + round(maps:get(atMs, M) * 1000.0)),
    Thunk().

at(M, AtUs) -> AtUs + round(maps:get(atMs, M) * 1000.0).

delay_ms(WallUs) -> max(0.0, (WallUs - erlang:system_time(microsecond)) / 1000.0).

%% Run `M:F(Args)` at wall time `WallUs`: now if that has passed.
later(WallUs, M, F, Args) ->
    case round(delay_ms(WallUs)) of
        0 -> apply(M, F, Args);
        Ms -> {ok, _} = timer:apply_after(Ms, M, F, Args), ok
    end.
