%% Conspicillum — the grain cloud, sounded.
%%
%% BEAM-authoritative and LOCKED to the Ableton Link clock, like
%% `reef_stellatus_voice`: the browser pushes one scene and becomes a pure
%% visualizer, and this process runs the shared `reef_conspicillum_cloud@ps`
%% and emits `/dirt/play` to SuperDirt.
%%
%% THE UNIT HERE IS A CYCLE, NOT A STEP, and that is the whole structural
%% difference from Stellatus. Stellatus precomputes a finite walk and indexes it
%% by step. A cloud is CYCLE-ADDRESSED: `cycleOf` is a pure function of the
%% scene and the cycle number, so this process computes a whole cycle's grains
%% at once, the moment that cycle enters the lookahead horizon, and schedules
%% each grain at its own fraction of the cycle.
%%
%% That is not just tidier. It is what lets the browser draw cycle 400 without
%% having simulated the 399 before it — which it must, because it recomputes
%% what we are sounding rather than being told.
%%
%% ONE BUNDLE PER GRAIN, TIMETAGGED, DOWN ONE SOCKET. Measured on this rig
%% (see triggerfish/docs/CONSPICILLUM-DESIGN.md, C1): SuperDirt takes 12,800
%% grains a second cleanly by this route and gives out around 25,600 on scsynth
%% DSP CPU — not on node count, and not on sclang. A musically extreme cloud is
%% 100-200 a second, so density is not a constraint here. The path that WOULD
%% be a constraint is `Tidal/OSC.erl`'s `sendDirtAfter`, which spawns a process
%% and opens a fresh UDP socket per event; a cloud must never use it.
-module(reef_conspicillum_voice).

-export([start_json/1, stop/0, loop/1, audition/3]).

%% Scheduler poll interval (ms).
-define(POLL_MS, 25).
%% Schedule this far ahead so each grain's bundle reaches SuperDirt with lead.
-define(LOOKAHEAD_MS, 300.0).
%% Beats per cycle. 4 matches the cps SuperDirt is told (Tempo/240).
-define(BEATS_PER_CYCLE, 4.0).
%% Treat the Link source as offline past this age (mirrors tidal_link_anchor).
-define(STALE_ANCHOR_US, 2000000).
%% Re-snap if the next cycle is more than this many cycles ahead (Link jump).
-define(SNAP_AHEAD, 4).

-define(SUPERDIRT_HOST, "127.0.0.1").
-define(SUPERDIRT_PORT, 57120).

%% Start (or live-swap) from a JSON-encoded Scene (Reef.Conspicillum.Protocol).
%% A second push swaps the scene in place, and the NEXT cycle is computed from
%% it — a cloud edit lands on a cycle boundary rather than mid-cycle, which is
%% what makes an edit sound deliberate instead of like a glitch.
start_json(Json) ->
    case 'reef_conspicillum_protocol@ps':decodeScene(ensure_bin(Json)) of
        {right, Scene} ->
            case whereis(reef_conspicillum_voice) of
                Pid when is_pid(Pid) ->
                    Pid ! {set_scene, Scene},
                    {ok, Pid};
                _ ->
                    NewPid = spawn(fun() ->
                        {ok, Sock} = gen_udp:open(0, [binary]),
                        erlang:send_after(?POLL_MS, self(), poll),
                        loop(#{ socket => Sock, scene => Scene, last_cycle => -1 })
                    end),
                    register(reef_conspicillum_voice, NewPid),
                    {ok, NewPid}
            end;
        {left, Errs} ->
            {error, {decode, Errs}}
    end.

%% Sound N cycles starting now, at a given tempo, WITHOUT the Link clock.
%%
%% Not test scaffolding — this is how you audition a cloud when no session is
%% running, which on this rig is most of the time: Link needs a peer, and the
%% peer is a laptop or an iPad that is only on when the gear is. Without this
%% the only way to hear a scene is to set up a whole session first, which is a
%% high price for "does this corpus sound like anything".
%%
%% It uses the same cycleOf -> bundle path as `drain`, so what you hear is what
%% the clock-locked voice will play; only the clock differs.
audition(Json, Cycles, Bpm) ->
    case 'reef_conspicillum_protocol@ps':decodeScene(ensure_bin(Json)) of
        {right, Scene} ->
            {ok, Sock} = gen_udp:open(0, [binary]),
            Name = maps:get(name, maps:get(corpus, Scene)),
            Cps = Bpm / 240.0,
            CycleDurUs = ?BEATS_PER_CYCLE * 60000000.0 / Bpm,
            Start = erlang:system_time(microsecond) + round(?LOOKAHEAD_MS * 1000),
            Total = lists:foldl(fun(C, Acc) ->
                Emits = array:to_list('reef_conspicillum_cloud@ps':cycleOf(
                            maps:get(corpus, Scene), maps:get(query, Scene),
                            maps:get(spec, Scene), maps:get(seed, Scene), C)),
                CycleUs = Start + C * CycleDurUs,
                lists:foreach(fun(Ev) ->
                    WallUs = round(CycleUs + maps:get(at, Ev) * CycleDurUs),
                    Msg = encode_dirt_play(Name, Ev, Cps),
                    gen_udp:send(Sock, ?SUPERDIRT_HOST, ?SUPERDIRT_PORT,
                                 osc_bundle(WallUs, Msg))
                end, Emits),
                Acc + length(Emits)
            end, 0, lists:seq(0, Cycles - 1)),
            %% Leave the socket open until the last grain has been scheduled,
            %% then close: the bundles are already sent, but closing under a
            %% still-draining send would be a race worth not having.
            timer:sleep(round(Cycles * CycleDurUs / 1000) + 400),
            gen_udp:close(Sock),
            {ok, Total};
        {left, Errs} ->
            {error, {decode, Errs}}
    end.

stop() ->
    case whereis(reef_conspicillum_voice) of
        Pid when is_pid(Pid) -> Pid ! stop, unregister(reef_conspicillum_voice), ok;
        _ -> ok
    end.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L).

loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(socket, St));
        {set_scene, Scene} ->
            loop(St#{scene => Scene});
        poll ->
            St2 = tick(St),
            erlang:send_after(?POLL_MS, self(), poll),
            loop(St2)
    end.

%% One poll: read the live Link beat and emit every cycle from the last up to
%% the lookahead horizon. Idle without a fresh anchor — there is nothing to
%% play against, and guessing a tempo would put grains in the wrong place
%% silently.
tick(St) ->
    NowUs = erlang:system_time(microsecond),
    case tidal_link_anchor:info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, _Quantum, LastRecvUs}
                when (NowUs - LastRecvUs) =< ?STALE_ANCHOR_US, Tempo > 0 ->
            BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
            NowCycle = trunc(BeatNow / ?BEATS_PER_CYCLE),
            Next0 = maps:get(last_cycle, St) + 1,
            Next = if (Next0 < NowCycle) orelse (Next0 > NowCycle + ?SNAP_AHEAD) ->
                          NowCycle;
                      true -> Next0
                   end,
            LookaheadBeats = ?LOOKAHEAD_MS / 1000.0 * Tempo / 60.0,
            Horizon = BeatNow + LookaheadBeats,
            drain(St, Next, Horizon, AnchorUs, BeatAtAnchor, Tempo);
        _ ->
            St
    end.

%% Compute and schedule each cycle that has entered the horizon.
drain(St, Cycle, Horizon, AnchorUs, BeatAtAnchor, Tempo) ->
    CycleBeat = Cycle * ?BEATS_PER_CYCLE,
    case CycleBeat =< Horizon of
        false ->
            St;
        true ->
            Scene = maps:get(scene, St),
            %% ONE call per cycle, not per grain: cycleOf is a pure function of
            %% the scene and the cycle number, so the whole cloud for this bar
            %% arrives together and each grain is then placed by its own `at`.
            Emits = array:to_list('reef_conspicillum_cloud@ps':cycleOf(
                        maps:get(corpus, Scene),
                        maps:get(query, Scene),
                        maps:get(spec, Scene),
                        maps:get(seed, Scene),
                        Cycle)),
            Name = maps:get(name, maps:get(corpus, Scene)),
            Cps = Tempo / 240.0,
            CycleUs = AnchorUs + (CycleBeat - BeatAtAnchor) * 60000000.0 / Tempo,
            CycleDurUs = ?BEATS_PER_CYCLE * 60000000.0 / Tempo,
            Sock = maps:get(socket, St),
            lists:foreach(fun(Ev) ->
                WallUs = round(CycleUs + maps:get(at, Ev) * CycleDurUs),
                Msg = encode_dirt_play(Name, Ev, Cps),
                gen_udp:send(Sock, ?SUPERDIRT_HOST, ?SUPERDIRT_PORT,
                             osc_bundle(WallUs, Msg))
            end, Emits),
            drain(St#{last_cycle => Cycle}, Cycle + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

%% =========================================================================
%% OSC /dirt/play encoding
%% =========================================================================

%% A grain as SuperDirt's flat [key, val, …] bag.
%%
%% `s` is the SET NAME and `n` the index within it, because a Quadrat set's
%% directory IS a SuperDirt bank — zero-padded files that sort, loaded by
%% `superdirt-daemon.scd` at boot. Nothing had to be built for that.
%%
%% `sustain` is sent explicitly rather than left to SuperDirt's delta-derived
%% default: a grain is short whatever the rate grains arrive at, and the
%% default would make a dense cloud's grains shorter than a sparse one's.
encode_dirt_play(Name, Ev, Cps) ->
    Args = [ <<"s">>, Name
           , <<"orbit">>, 0
           , <<"cps">>, float(Cps)
           , <<"cycle">>, float(0.0)
           , <<"delta">>, float(maps:get(sustain, Ev))
           , <<"n">>, float(maps:get(n, Ev))
           , <<"begin">>, float(maps:get(begin_, Ev, maps:get('begin', Ev, 0.0)))
           , <<"end">>, float(maps:get('end', Ev))
           , <<"sustain">>, float(maps:get(sustain, Ev))
           , <<"speed">>, float(maps:get(speed, Ev))
           , <<"gain">>, float(maps:get(gain, Ev))
           , <<"pan">>, float(maps:get(pan, Ev))
           , <<"accelerate">>, float(maps:get(accelerate, Ev))
           ],
    encode_msg(<<"/dirt/play">>, Args).

encode_msg(Addr, Args) ->
    AddrBin = pad_string(Addr),
    {Tags, Body} = lists:foldl(fun(A, {T, B}) ->
        case A of
            Bin when is_binary(Bin) -> {[$s | T], <<B/binary, (pad_string(Bin))/binary>>};
            F when is_float(F) -> {[$f | T], <<B/binary, F:32/float>>};
            I when is_integer(I) -> {[$i | T], <<B/binary, I:32/big-signed-integer>>}
        end
    end, {[], <<>>}, Args),
    TagBin = pad_string(list_to_binary([$, | lists:reverse(Tags)])),
    <<AddrBin/binary, TagBin/binary, Body/binary>>.

pad_string(B) ->
    Pad = 4 - (byte_size(B) rem 4),
    <<B/binary, 0:(Pad * 8)>>.

-define(NTP_EPOCH_OFFSET, 2208988800).

%% Wrap one message in a bundle timetagged at `WhenUnixUs`. SuperDirt schedules
%% the sound at the timetag, so sending ahead lands it sample-accurately rather
%% than late-on-receipt. Same arithmetic as reef_stellatus_voice.
osc_bundle(WhenUnixUs, Msg) ->
    Secs = (WhenUnixUs div 1000000) + ?NTP_EPOCH_OFFSET,
    FracUs = WhenUnixUs rem 1000000,
    Frac = (FracUs * 4294967296) div 1000000,
    Timetag = <<Secs:32/big-unsigned-integer, Frac:32/big-unsigned-integer>>,
    Element = <<(byte_size(Msg)):32/big-signed-integer, Msg/binary>>,
    <<"#bundle", 0, Timetag/binary, Element/binary>>.
