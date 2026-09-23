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

%% `encode_dirt_play/3` is exported for inspection, not for callers. What goes
%% on the wire for a given grain is now conditional — thirteen effects that are
%% each present or absent — and a rule about ABSENCE cannot be checked by
%% listening. This makes the bytes readable from a shell.
-export([start_json/1, stop/0, loop/1, audition/3, encode_dirt_play/3]).

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
    Fx = maps:get(fx, Ev),
    Ch = maps:get(chain, Ev),
    Args = [ <<"s">>, Name
           , <<"orbit">>, maps:get(orbit, Ch)
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
    encode_msg(<<"/dirt/play">>, Args ++ chain_args(Ch) ++ fx_args(Fx)).

%% =========================================================================
%% Effects
%% =========================================================================

%% The per-orbit chain, sent with EVERY grain — and that is not the waste it
%% looks like.
%%
%% `GlobalDirtEffect:set/1` diffs each parameter against its own state and only
%% sends OSC to the running synth when a value actually changed, so a steady
%% chain costs one comparison per grain and no traffic at all. What it buys is
%% the ability to turn an effect OFF: that class only ever resumes, never
%% pauses, so a reverb once told `room 0.6` keeps reverberating for the life of
%% the orbit. Ceasing to send `room` does not stop it; sending `room 0` does.
%% Omitting these when they are zero would therefore make "dry" unreachable
%% from the moment anything had been wet — a bug audible only as "the reverb
%% won't go away", which is exactly the kind nobody attributes to the encoder.
chain_args(Ch) ->
    [ <<"room">>,          float(maps:get(room, Ch))
    , <<"size">>,          float(maps:get(size, Ch))
    , <<"dry">>,           float(maps:get(dry, Ch))
    , <<"delay">>,         float(maps:get(delay, Ch))
    , <<"delaytime">>,     float(maps:get(delaytime, Ch))
    , <<"delayfeedback">>, float(maps:get(delayfeedback, Ch))
    , <<"lock">>,          float(maps:get(lock, Ch))
    , <<"leslie">>,        float(maps:get(leslie, Ch))
    , <<"lrate">>,         float(maps:get(lrate, Ch))
    , <<"lsize">>,         float(maps:get(lsize, Ch))
      %% The global resonator (dirt_rsn_global, ours). Sent like the rest of
      %% the chain rather than gated, for the same reason: a GlobalDirtEffect
      %% only ever resumes, so `grsn 0` is how it is silenced.
    , <<"grsn">>,          float(maps:get(grsn, Ch))
    , <<"grsnpitch">>,     float(maps:get(grsnpitch, Ch))
    , <<"grsndecay">>,     float(maps:get(grsndecay, Ch))
    , <<"grsnbright">>,    float(maps:get(grsnbright, Ch))
    ].

%% The per-event effects — sent ONLY when engaged, which is the opposite rule
%% to the chain above and for a reason that comes straight from SuperDirt.
%%
%% Every per-event module in `core-modules.scd` is gated on its parameter being
%% PRESENT in the event rather than on its value: `{ ~cutoff.notNil }`,
%% `{ ~crush.notNil }`, and so on. There is no neutral number to send — an
%% `lpf` of 0 is a filter at 0 Hz, which is silence, not "no filter". So the
%% only way to say "no filter" is to leave the key out, and `Reef.Conspicillum.
%% Cloud`'s zero-is-off convention is what tells us when to.
%%
%% This is also what keeps the cost honest. A grain no effect rule selected
%% encodes exactly the thirteen parameters it always did, and instantiates no
%% synth on scsynth — so the 12,800 grains/sec measured in C1 is still the
%% ceiling for a dry cloud.
fx_args(Fx) ->
    G = fun(K) -> maps:get(K, Fx, 0.0) end,
    Res = G(res),
    lists:append(
      [ on(G(shape) > 0.0,    [<<"shape">>, float(G(shape))])
        %% The module itself ignores coarse =< 1 ("full rate"), so the gate
        %% here matches rather than merely being > 0.
      , on(G(coarse) > 1.0,   [<<"coarse">>, float(G(coarse))])
      , on(G(crush) > 0.0,    [<<"crush">>, float(G(crush))])
      , on(G(lpf) > 0.0,      [<<"cutoff">>, float(G(lpf))])
      , on(G(hpf) > 0.0,      [<<"hcutoff">>, float(G(hpf))])
      , on(G(bpf) > 0.0,      [<<"bandf">>, float(G(bpf))])
        %% One `res` knob reaching two SuperDirt keys. `resonance` is read by
        %% the lpf AND vowel modules, `hresonance` by hpf; sending both when
        %% neither module runs is inert, because a parameter alone instantiates
        %% nothing.
      , on(Res > 0.0,         [<<"resonance">>, float(Res),
                               <<"hresonance">>, float(Res)])
      , on(vowel_of(G(vowel)) =/= none,
                              [<<"vowel">>, vowel_of(G(vowel))])
        %% A pitch RATIO, and the reason this one is worth having: it moves the
        %% grain in pitch without moving it in time, which `speed` cannot do.
      , on(G(pshift) > 0.0,   [<<"psrate">>, float(G(pshift))])
      , on(G(tremolo) > 0.0,  [<<"tremolorate">>, float(G(tremolo)),
                               <<"tremolodepth">>, float(G(tremdepth))])
      , on(G(phaser) > 0.0,   [<<"phaserrate">>, float(G(phaser)),
                               <<"phaserdepth">>, float(G(phdepth))])
        %% The grain's own amplitude envelope, which is not its window: the
        %% window says WHICH audio, the envelope says how it arrives and
        %% leaves. `grenvelo` is gated on `tilt`, and tilt 0 is a perfectly
        %% good value (peak at the very start), so zero-is-off cannot live on
        %% the shape here — `genv` is the switch and tilt/plat the shape, the
        %% same amount-gates-shape split the chain uses.
      , on(G(genv) > 0.0,     [<<"tilt">>, float(G(gtilt)),
                               <<"plat">>, float(G(gplat))])
      , on(G(atk) > 0.0 orelse G(rel) > 0.0,
                              [<<"attack">>, float(G(atk)),
                               <<"hold">>, float(G(hold)),
                               <<"release">>, float(G(rel))])
        %% `curve` is read by BOTH envelope modules and 0 means linear, so it
        %% cannot gate on its own value — it rides whenever either runs.
      , on(G(genv) > 0.0 orelse G(atk) > 0.0 orelse G(rel) > 0.0,
                              [<<"curve">>, float(G(curve))])
        %% The resonator, which is ours (superdirt-daemon.scd). rsnpitch is a
        %% MIDI note, so 0 is 8.2 Hz and unusable, and zero-is-off holds.
      , on(G(rsnpitch) > 0.0, [<<"rsnpitch">>, float(G(rsnpitch)),
                               <<"rsndecay">>, float(G(rsndecay)),
                               <<"rsnbright">>, float(G(rsnbright)),
                               <<"rsnmix">>, float(G(rsnmix)),
                               <<"rsnmodel">>, float(G(rsnmodel))])
      ]).

on(true, Args) -> Args;
on(false, _)   -> [].

%% An index rather than a string, so a rule's payload stays one Number. The
%% order is SuperDirt's own (`initVowels`, [a e i o u]); 0 is off.
%%
%% sclang decodes OSC string arguments as SYMBOLS, which is what makes this
%% work at all: `~dirt.vowels` is keyed by symbols and an actual String would
%% miss every one of them and silently do nothing.
vowel_of(X) when X >= 0.5, X < 1.5 -> <<"a">>;
vowel_of(X) when X >= 1.5, X < 2.5 -> <<"e">>;
vowel_of(X) when X >= 2.5, X < 3.5 -> <<"i">>;
vowel_of(X) when X >= 3.5, X < 4.5 -> <<"o">>;
vowel_of(X) when X >= 4.5, X < 5.5 -> <<"u">>;
vowel_of(_) -> none.

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
