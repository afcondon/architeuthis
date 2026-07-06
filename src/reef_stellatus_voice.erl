%% @doc reef_stellatus_voice — the Stellatus circular sample re-sequencer on the
%% BEAM, LOCKED to the Ableton Link clock. Runs the shared `reef_stellatus_engine@ps`
%% walk (grid-locked arc-advance + weighted jumps + glitch-folded speed) and emits
%% one SuperDirt `/dirt/play` per model step to SuperDirt on UDP 127.0.0.1:57120.
%%
%% Unlike the other reef voices, Stellatus is a SAMPLE voice: its output is an OSC
%% `/dirt/play` param bag (s/n/begin/end/speed/gain/orbit/cps), NOT MIDI — so this
%% module carries its own small OSC encoder rather than routing through
%% tidal_mIDIBridge (which speaks link-spike's MIDI dialect).
%%
%% The walk is a PURE FUNCTION of the pushed scene (a fixed-length loop the shared
%% engine precomputes; see Reef.Stellatus.Engine), byte-identical to the browser
%% visualizer (proven by Reef.Conformance.stellatusRun). So we compute the loop of
%% `/dirt/play` events ONCE on the push and index it by `Step rem Len` per Link
%% 1/16 — no per-tick generation, no seed threading, no drift. A second push swaps
%% the loop in place (live edit). This is the shipping BEAM-authoritative path: the
%% browser sends no audio OSC, so backgrounding it has no effect on the sound.
-module(reef_stellatus_voice).
-export([start_json/2, stop/0, loop/1]).

%% Scheduler poll interval (ms).
-define(POLL_MS, 25).
%% Schedule this far ahead so the per-step wall-time timers have lead time.
-define(LOOKAHEAD_MS, 300.0).
%% Model step length in beats. 0.25 = a 1/16 note (one ring slot per 1/16).
-define(STEP_BEATS, 0.25).
%% Treat the Link source as offline past this age (mirrors tidal_link_anchor).
-define(STALE_ANCHOR_US, 2000000).
%% Re-snap if the next step is more than this many steps ahead (backward Link jump).
-define(SNAP_AHEAD, 8).

%% SuperDirt's OSC intake (the conventional Dirt port; es9-daemon moved to 57130
%% to free it — see the atlantis compose fixture).
-define(SUPERDIRT_HOST, "127.0.0.1").
-define(SUPERDIRT_PORT, 57120).

%% Start (or live-swap) from a JSON-encoded Scene — the Stellatus handoff
%% (Reef.Stellatus.Protocol). Precomputes the `/dirt/play` loop once (the engine's
%% `events`), stores it as a 1-indexed tuple, and snaps to the current clock. A
%% second push swaps the loop in place. The WS `stellatus-scene <json>`.
start_json(Json, StepBeats) ->
    case 'reef_stellatus_protocol@ps':decodeScene(ensure_bin(Json)) of
        {right, Scene} ->
            Evs = array:to_list('reef_stellatus_engine@ps':events(Scene)),
            EvTup = list_to_tuple(Evs),
            Len = tuple_size(EvTup),
            case Len of
                0 -> {error, empty_scene};
                _ ->
                    case whereis(reef_stellatus_voice) of
                        Pid when is_pid(Pid) ->
                            Pid ! {set_scene, EvTup, Len},
                            {ok, Pid};
                        _ ->
                            NewPid = spawn(fun() ->
                                {ok, Sock} = gen_udp:open(0, [binary]),
                                erlang:send_after(?POLL_MS, self(), poll),
                                loop(#{ socket => Sock, step_beats => StepBeats,
                                        evs => EvTup, len => Len, last_step => -1 })
                            end),
                            catch register(reef_stellatus_voice, NewPid),
                            {ok, NewPid}
                    end
            end;
        {left, Errs} -> {error, {decode, Errs}}
    end.

stop() ->
    case whereis(reef_stellatus_voice) of
        undefined -> ok;
        Pid ->
            Pid ! stop,
            catch unregister(reef_stellatus_voice),
            ok
    end.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L).

%% The clock-locked loop. `poll` self-messages drive the walk (which sends OSC
%% ahead of time, timetagged); `set_scene` swaps the loop in place (live edit);
%% `stop` closes the socket.
loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(socket, St));
        {set_scene, EvTup, Len} ->
            loop(St#{evs => EvTup, len => Len});
        poll ->
            St2 = tick(St),
            erlang:send_after(?POLL_MS, self(), poll),
            loop(St2)
    end.

%% One poll: read the live Link beat, schedule every model step from the last up to
%% the lookahead horizon. Idle without a fresh anchor (nothing to play against).
tick(St) ->
    NowUs = erlang:system_time(microsecond),
    case tidal_link_anchor:info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, _Quantum, LastRecvUs}
                when (NowUs - LastRecvUs) =< ?STALE_ANCHOR_US, Tempo > 0 ->
            StepBeats = maps:get(step_beats, St),
            BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
            NowStep = trunc(BeatNow / StepBeats),
            Next0 = maps:get(last_step, St) + 1,
            Next = if (Next0 < NowStep) orelse (Next0 > NowStep + ?SNAP_AHEAD) ->
                          NowStep;
                      true -> Next0
                   end,
            LookaheadBeats = ?LOOKAHEAD_MS / 1000.0 * Tempo / 60.0,
            Horizon = BeatNow + LookaheadBeats,
            drain(St, Next, Horizon, AnchorUs, BeatAtAnchor, Tempo);
        _ ->
            St
    end.

%% Schedule each step within the horizon: index the precomputed loop by
%% `Step rem Len`, encode its `/dirt/play`, and send it NOW wrapped in an OSC
%% bundle timetagged at the step's wall time. Because drain reaches a step ~one
%% lookahead early, SuperDirt receives it with lead and plays it sample-accurately
%% at the timetag (vs. a plain message, which plays late on receipt).
drain(St, Step, Horizon, AnchorUs, BeatAtAnchor, Tempo) ->
    StepBeats = maps:get(step_beats, St),
    StepBeat = Step * StepBeats,
    case StepBeat =< Horizon of
        false ->
            St;
        true ->
            Len = maps:get(len, St),
            Evs = maps:get(evs, St),
            Ev = element((Step rem Len) + 1, Evs),
            case maps:get(s, Ev) of
                <<>> -> ok;  %% empty slot — skip
                _ ->
                    %% cps: cycles/sec at 4 beats-per-cycle (metadata for SuperDirt).
                    Cps = Tempo / 240.0,
                    Msg = encode_dirt_play(Ev, Cps),
                    WallUs = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
                    Packet = osc_bundle(WallUs, Msg),
                    gen_udp:send(maps:get(socket, St), ?SUPERDIRT_HOST, ?SUPERDIRT_PORT, Packet)
            end,
            drain(St#{last_step => Step}, Step + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

%% =========================================================================
%% OSC /dirt/play encoding
%% =========================================================================
%%
%% SuperDirt's /dirt/play takes a flat [key1, val1, key2, val2, …] arg list: each
%% key is a string, each value typed (s/f). We send the same bag the dev bridge
%% did (s n begin end speed gain orbit cps) — proven audible.

encode_dirt_play(Ev, Cps) ->
    Args =
        [ {<<"s">>, {s, maps:get(s, Ev)}}
        , {<<"n">>, {f, num(maps:get(n, Ev))}}
        , {<<"begin">>, {f, num(maps:get('begin', Ev))}}
        , {<<"end">>, {f, num(maps:get('end', Ev))}}
        , {<<"speed">>, {f, num(maps:get(speed, Ev))}}
        , {<<"gain">>, {f, num(maps:get(gain, Ev))}}
        , {<<"orbit">>, {f, 0.0}}
        , {<<"cps">>, {f, num(Cps)}}
        ],
    encode_msg(<<"/dirt/play">>, Args).

%% Build an OSC message: padded address, a ",…" type-tag string (an "s" for each
%% key plus each value's tag), then the concatenated key+value bytes.
encode_msg(Addr, Args) ->
    {Tags, Body} =
        lists:foldl(
          fun({K, {T, V}}, {Ts, Bs}) ->
              KeyBin = pad_string(K),
              {ValTag, ValBin} =
                  case T of
                      s -> {"s", pad_string(ensure_bin(V))};
                      f -> {"f", <<V:32/float-big>>}
                  end,
              {Ts ++ "s" ++ ValTag, <<Bs/binary, KeyBin/binary, ValBin/binary>>}
          end,
          {",", <<>>},
          Args),
    AddrBin = pad_string(Addr),
    TagBin = pad_string(list_to_binary(Tags)),
    <<AddrBin/binary, TagBin/binary, Body/binary>>.

%% Seconds between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).
-define(NTP_EPOCH_OFFSET, 2208988800).

%% Wrap one OSC message in a bundle timetagged at `WhenUnixUs` (NTP format: 32-bit
%% seconds + 32-bit binary fraction). SuperDirt schedules the sound at the timetag,
%% so sending ahead of time lands it sample-accurately instead of late-on-receipt.
osc_bundle(WhenUnixUs, Msg) ->
    Secs = (WhenUnixUs div 1000000) + ?NTP_EPOCH_OFFSET,
    FracUs = WhenUnixUs rem 1000000,
    Frac = (FracUs * 4294967296) div 1000000,  %% fraction of a second × 2^32
    Timetag = <<Secs:32/big-unsigned-integer, Frac:32/big-unsigned-integer>>,
    Element = <<(byte_size(Msg)):32/big-signed-integer, Msg/binary>>,
    <<"#bundle", 0, Timetag/binary, Element/binary>>.

%% Coerce any number to a float (OSC "f").
num(V) when is_float(V) -> V;
num(V) when is_integer(V) -> float(V).

%% Pad a string to a 4-byte boundary with at least one trailing null.
pad_string(Bin) when is_binary(Bin) ->
    Len = byte_size(Bin) + 1,
    Padding = (4 - (Len rem 4)) rem 4,
    <<Bin/binary, 0:8, 0:(Padding*8)>>.
