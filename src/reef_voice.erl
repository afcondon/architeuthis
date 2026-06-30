%% @doc reef_voice — the smallest honest "Odonus on the BEAM via reef" proof.
%%
%% A free-running Odonus voice driven by the shared reef engine: each tick it
%% calls reef_odonus@ps:stepEmit/1 and emits the fired notes to IAC (via
%% link-spike's MIDI dispatcher on :57122, same path the rig uses). Hardcoded to
%% defaultOdonus — you should hear the conformance golden's scale walk
%% (p62 p62 p63 p65 ...). For the Triggerfish-direct vs BEAM-via-reef A/B.
%%
%% Deliberately NOT Link-synced and NOT integrated with the pull-clock
%% (compute_until) or the Twister control bus — that's the later parity work on
%% the real odonus_voice. This is just: reef record -> stepEmit -> MIDI.
%%
%% Runs fine in a standalone node (erl -pa ebin), independent of the live rig,
%% because emitting is just a UDP send to link-spike.
-module(reef_voice).
-export([start/0, start/2, stop/0, loop/4, ping/0]).

%% Lead time (us) — schedule notes this far in the future so link-spike has
%% time to receive + schedule them (a 5ms lead gets dropped as already-past).
-define(LEAD_US, 200000).

%% Single-note smoke test: fire middle C (60) on ch 16, +200ms. Returns the
%% effect result (`unit` = the OSC send to link-spike was issued).
ping() ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, 16, 60, 100, 500,
              os:system_time(microsecond) + ?LEAD_US),
    R = Thunk(),
    gen_udp:close(Sock),
    R.

%% Channel 16 by default so it's trivially isolable in Ableton.
start() -> start(16, 150).

%% Channel (1..16), StepMs (ms per step). The UDP socket is opened INSIDE the
%% spawned loop process so it's owned by (and lives as long as) the loop — if
%% the caller (e.g. a transient shell evaluator) opened it, it would close when
%% the caller exited and every send would silently fail with {error, closed}.
start(Channel, StepMs) ->
    Odo = 'reef_odonus@ps':defaultOdonus(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary]),
        loop(Sock, Channel, StepMs, Odo)
    end),
    catch register(reef_voice, Pid),
    {ok, Pid}.

stop() ->
    case whereis(reef_voice) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

loop(Sock, Ch, StepMs, Odo) ->
    receive
        stop -> gen_udp:close(Sock)
    after StepMs ->
        Res   = 'reef_odonus@ps':stepEmit(Odo),
        Odo2  = maps:get(odo, Res),
        %% `fired` is a purerl Array (Erlang `array`), not a list — convert.
        Fired = array:to_list(maps:get(fired, Res)),
        WallUs = os:system_time(microsecond) + ?LEAD_US,
        lists:foreach(fun(F) -> emit(Sock, Ch, F, WallUs, StepMs) end, Fired),
        loop(Sock, Ch, StepMs, Odo2)
    end.

emit(Sock, Ch, F, WallUs, StepMs) ->
    Note  = maps:get(pitch, F),
    Vel   = maps:get(vel, F),
    DurMs = maps:get(dur, F) * StepMs,
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, Ch, Note, Vel, DurMs, WallUs),
    Thunk().
