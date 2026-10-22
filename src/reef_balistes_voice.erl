%% @doc reef_balistes_voice — a Balistes (Grids) drum voice on the BEAM, driven by
%% the shared reef engine and LOCKED to the Ableton Link clock. The Balistes
%% analogue of reef_voice: same clock-locked beat-grid walk (a port of
%% Binnacle.Scheduler), but it runs the shared `reef_balistes_sim@ps` — stepBal
%% (the Grids engine tick) then renderStep (the open-hat / note / Dilla-push /
%% ratchet / accent decision) — the EXACT code the Triggerfish frontend runs, so
%% the browser (ch 10) and the rig co-simulate byte-for-byte.
%%
%% Each poll reads the current absolute Link beat from tidal_link_anchor and walks
%% a lookahead grid: step S lands on beat `S * StepBeats`, tick index
%% `trunc(beat / StepBeats)`. The frontend derives ITS tick index the same way from
%% the same anchor, so both agree on "step N" for free. The handoff is
%% phase-aligned (start_sim_at_json holds the pushed state until absolute step N),
%% removing the ~1-beat flam #57 fixed for Odonus.
%%
%% Unlike reef_voice there is no gen/seed/tickChord — the Grids engine is a pure
%% per-step function of the pushed BalSim (x/y/densities/randomness + the RNG state
%% that reseeds perturbations at each 32-step pattern start). Emit is on ONE channel
%% (drums), with ratchet subdivision + per-lane Dilla push applied per event exactly
%% as the frontend's emitHit does.
-module(reef_balistes_voice).
-export([start/0, start/2, start_sim_json/3, start_sim_at_json/4,
         start_fixed_json/3, start_named/1, stop/0, loop/1,
         set_routing_json/1, routing/0, play_hit/6, set_mutes/1, set_fill/1, set_fill_pattern/1]).

%% Scheduler poll interval (ms). Timing is absolute (WallUs from the anchor), so
%% poll jitter only affects lookahead slack.
-define(POLL_MS, 25).
%% Schedule this far ahead so link-spike has lead time (mirrors the frontend).
-define(LOOKAHEAD_MS, 200.0).
%% Model step length in beats. 0.25 = a 1/16 note (the Balistes grid is fixed 1/16).
-define(STEP_BEATS, 0.25).
%% Treat the Link source as offline past this age (mirrors tidal_link_anchor).
-define(STALE_ANCHOR_US, 2000000).
%% Re-snap if the next step is more than this many steps ahead (a backward Link
%% jump — transport restart / re-sync — would otherwise strand us in silence).
-define(SNAP_AHEAD, 8).
%% Balistes emits on ONE channel. Drums-always-ch-10 convention (2026-07-12):
%% frontend and rig both play ch 10, matching Triggerfish.Midi.Routing drumsChannel.
-define(DEFAULT_CHANNEL, 10).
%% Where the routing table is kept: outside any one voice, so every start,
%% of any engine, plays through the table last pushed.
-define(ROUTING_KEY, {?MODULE, routing}).
-define(MUTES_KEY, {?MODULE, mutes}).
-define(FILL_KEY, {?MODULE, fill}).
-define(FILL_PAT_KEY, {?MODULE, fill_pattern}).

start() -> start(?DEFAULT_CHANNEL, ?STEP_BEATS).

%% The drum routing table, pushed by the browser (`balistes-routing <json>`,
%% Reef.Routing's wire form): per canonKit lane, the legs to send each hit
%% down. Until one arrives the voice is silent; after, it plays what the
%% browser's table says, through the same Reef.Routing.drumSends the browser
%% calls. The stage keeps the last one (balistes/routing) across restarts.
set_routing_json(Json) ->
    case 'reef_routing@ps':decodeDrumRouting(ensure_bin(Json)) of
        {right, Routing} ->
            persistent_term:put(?ROUTING_KEY, Routing),
            ok;
        {left, Errs} ->
            {error, {decode, Errs}}
    end.

routing() -> persistent_term:get(?ROUTING_KEY, none).

%% The lanes Balistes has muted (`balistes-mute <mask>`, one bit a lane;
%% Reef.Balistes.Kit). Kept beside the routing, so it holds across a voice
%% restart; every mode's hits pass through it in emit/4, a lane's audition
%% (play_hit/6) does not.
set_mutes(Mask) when is_integer(Mask), Mask >= 0 ->
    persistent_term:put(?MUTES_KEY, Mask),
    ok.

mutes() -> persistent_term:get(?MUTES_KEY, 0).

%% Balistes's FILL (`balistes-fill 0|1`): while on, a rhythm's FILL hits play
%% and its NOT FILL hits rest (Reef.Balistes.Fixed.renderFixedFill), in fixed
%% and named mode alike. Performance state, beside the mutes.
set_fill(On) when is_boolean(On) ->
    persistent_term:put(?FILL_KEY, On),
    ok.

fill() -> persistent_term:get(?FILL_KEY, false).

%% FILL as a Tidal pattern (`balistes $ fill "<f!7 t>"`, Tidal.Named
%% fillSampler): a sampler from the sixteenth to on/off, or none. Beside the
%% FILL switch, not instead of it: a step fills when either says so, so
%% Balistes's F still fills by hand while a pattern runs.
set_fill_pattern(Sampler) when Sampler =:= none; is_function(Sampler, 1) ->
    persistent_term:put(?FILL_PAT_KEY, Sampler),
    ok.

fill_pattern() -> persistent_term:get(?FILL_PAT_KEY, none).

%% Whether sixteenth Step plays its rhythm's FILL.
fill_at(Step) ->
    fill() orelse case fill_pattern() of
                      none -> false;
                      Sampler -> Sampler(Step) =:= true
                  end.

%% Tell open Balistes pages what the pattern makes of FILL, as it changes,
%% ahead of the step (the drain's lookahead), so the page's FILL follows the
%% sound: `balistes-fill-at <step> 1|0`, or `- ` when the pattern is taken
%% off and FILL is the page's own again (Triggerfish.Balistes.Follow).
fill_shown(Step, St) ->
    Now = case fill_pattern() of
              none -> none;
              Sampler -> Sampler(Step) =:= true
          end,
    case maps:get(fill_shown, St, none) of
        Now -> St;
        _ ->
            Word = case Now of true -> <<"1">>; false -> <<"0">>; none -> <<"-">> end,
            catch tidal_link_anchor:sync_broadcast(
                    <<"balistes-fill-at ", (integer_to_binary(Step))/binary, " ", Word/binary>>),
            St#{fill_shown => Now}
    end.

%% Hardcoded defaultBalSim (the neutral Grids start), for a standalone smoke test.
start(Channel, StepBeats) ->
    do_start('reef_balistes_sim@ps':defaultBalSim(), Channel, StepBeats).

%% Start from a JSON-encoded BalSim — the Balistes handoff (Reef.Balistes.Protocol).
%% Snaps to the current clock step (legacy / non-aligned). The WS `balistes-sim` verb.
start_sim_json(Json, Channel, StepBeats) ->
    case 'reef_balistes_protocol@ps':decodeBalSim(ensure_bin(Json)) of
        {right, Bal}  -> do_start(Bal, Channel, StepBeats);
        {left, Errs}  -> {error, {decode, Errs}}
    end.

%% Phase-aligned handoff (bakes in the Odonus #57 fix from the start): hold the
%% pushed BalSim until absolute model step N (the frontend's nextModelStep — the step
%% it will next play from exactly this state). Seed last_step = N-1 so the voice's
%% first emitted step is N, on the SAME absolute step the frontend plays it. The WS
%% `balistes-sim-at <step> <beats> <json>` verb.
start_sim_at_json(Json, Channel, StepBeats, N) ->
    case 'reef_balistes_protocol@ps':decodeBalSim(ensure_bin(Json)) of
        {right, Bal}  -> do_start_at(Bal, Channel, StepBeats, N - 1);
        {left, Errs}  -> {error, {decode, Errs}}
    end.

do_start(Bal, Channel, StepBeats) -> do_start_at(Bal, Channel, StepBeats, -1).

%% Replace any running voice, then spawn a fresh clock-locked one. The UDP socket is
%% opened INSIDE the spawned loop so it's owned by (and lives as long as) the loop.
%% LastStep seeds last_step: -1 snaps to the current clock step on the first poll;
%% N-1 holds the state for absolute step N (the phase-aligned path).
do_start_at(Bal, Channel, StepBeats, LastStep) ->
    stop(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary]),
        erlang:send_after(?POLL_MS, self(), poll),
        loop(#{ socket => Sock, channel => Channel, step_beats => StepBeats,
                mode => grids, bal => Bal, last_step => LastStep, pending => [] })
    end),
    catch register(reef_balistes_voice, Pid),
    {ok, Pid}.

%% Start from a JSON-encoded FixedPattern — the fixed-rhythm handoff (AFixed mode).
%% A fixed rhythm is a pure function of the absolute step (no state, no seed), so it
%% snaps to the current clock step and needs no phase-hold: both runtimes read the
%% same Link step and agree. The WS `balistes-fixed <json>` verb.
start_fixed_json(Json, Channel, StepBeats) ->
    case 'reef_balistes_protocol@ps':decodeFixed(ensure_bin(Json)) of
        {right, Pat} ->
            case whereis(reef_balistes_voice) of
                Pid when is_pid(Pid) ->
                    %% A voice is already running (fixed OR grids): swap the pattern in
                    %% place — cheap, seamless, and this is the live-edit path (every
                    %% cell/velocity/condition edit re-pushes).
                    Pid ! {set_pattern, Pat},
                    {ok, Pid};
                _ ->
                    NewPid = spawn(fun() ->
                        {ok, Sock} = gen_udp:open(0, [binary]),
                        erlang:send_after(?POLL_MS, self(), poll),
                        loop(#{ socket => Sock, channel => Channel, step_beats => StepBeats,
                                                mode => fixed, pattern => Pat, last_step => -1, pending => [] })
                    end),
                    catch register(reef_balistes_voice, NewPid),
                    {ok, NewPid}
            end;
        {left, Errs} -> {error, {decode, Errs}}
    end.

%% `balistes $ "<a b>"` (Tidal.Named): play the rhythms a pattern of their
%% names gives, each from its top when its event begins (a cycle a bar). The
%% rhythms are read off the stage (balistes/rhythm/<word>) at the step they
%% play, so a rhythm edited in Balistes is heard from the next step. A running
%% voice of any mode switches in place, as a pushed fixed rhythm does.
start_named(Src) ->
    case 'tidal_named@ps':wordSampler(ensure_bin(Src)) of
        {left, Why} -> {error, Why};
        {right, Sampler} ->
            case whereis(reef_balistes_voice) of
                Pid when is_pid(Pid) ->
                    Pid ! {set_named, Sampler},
                    {ok, Pid};
                _ ->
                    NewPid = spawn(fun() ->
                        {ok, Sock} = gen_udp:open(0, [binary]),
                        erlang:send_after(?POLL_MS, self(), poll),
                        loop(#{ socket => Sock, channel => ?DEFAULT_CHANNEL, step_beats => ?STEP_BEATS,
                                mode => named, sampler => Sampler, rhythms => #{},
                                shown => none, last_step => -1, pending => [] })
                    end),
                    catch register(reef_balistes_voice, NewPid),
                    {ok, NewPid}
            end
    end.

stop() ->
    case whereis(reef_balistes_voice) of
        undefined -> ok;
        Pid ->
            Pid ! stop,
            catch unregister(reef_balistes_voice),
            ok
    end.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L).

%% The clock-locked loop. `poll` self-messages drive the grid walk (via send_after
%% so an incoming message can't reset the timer); `stop` closes the socket.
loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(socket, St));
        {apply_input, Tick, Input} ->
            %% Lockstep live edit: buffer a tick-tagged BInput broadcast from the
            %% frontend; drain applies it before stepping the matching model step, so
            %% both runtimes evolve identically through the edit. `Input` is an opaque
            %% reef_balistes_input@ps term — we never inspect it, only apply it.
            Pending = maps:get(pending, St),
            loop(St#{pending => Pending ++ [{Tick, Input}]});
        {set_named, Sampler} ->
            %% A new `balistes $` line: the pattern of names swapped in place,
            %% the rhythms already read kept.
            loop(St#{mode => named, sampler => Sampler, rhythms => maps:get(rhythms, St, #{}),
                     shown => none});
        {set_pattern, Pat} ->
            %% Live fixed-rhythm edit: swap the pattern IN PLACE (keeping the socket +
            %% last_step, so no restart / audio gap). Also switches a running Grids
            %% voice to fixed mode — a fixed rhythm is a pure function of the absolute
            %% step, so it picks up seamlessly on the next step.
            loop(St#{mode => fixed, pattern => Pat});
        poll ->
            St2 = tick(St),
            erlang:send_after(?POLL_MS, self(), poll),
            loop(St2)
    end.

%% One poll: read the live Link beat, emit every model step from the last up to the
%% lookahead horizon. Idle without a fresh anchor (nothing to co-simulate with).
tick(St) ->
    NowUs = erlang:system_time(microsecond),
    case tidal_link_anchor:info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, _Quantum, LastRecvUs}
                when (NowUs - LastRecvUs) =< ?STALE_ANCHOR_US, Tempo > 0 ->
            StepBeats = maps:get(step_beats, St),
            BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
            NowStep = trunc(BeatNow / StepBeats),
            Next0 = maps:get(last_step, St) + 1,
            %% Re-snap on any clock discontinuity (behind = free-run->lock; too far
            %% ahead = backward jump), else continue from the last emitted step.
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

%% Emit each step within the horizon, advancing the shared Grids engine and
%% scheduling its notes at the step's anchor-derived wall time.
drain(St, Step, Horizon, AnchorUs, BeatAtAnchor, Tempo) ->
    StepBeats = maps:get(step_beats, St),
    StepBeat = Step * StepBeats,
    case StepBeat =< Horizon of
        false ->
            St;
        true ->
            %% Invert the affine map: the wall time at which beat StepBeat occurs.
            WallUs = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
            StepMs = StepBeats * 60000.0 / Tempo,
            Sock = maps:get(socket, St),
            St2 = case maps:get(mode, St) of
                fixed ->
                    %% Fixed rhythm: a pure function of the ABSOLUTE Step (no state, no
                    %% inputs, no seed) — the shared renderFixed decides every hit, so
                    %% both runtimes reading the same Link step agree with no handoff.
                    FEvents = array:to_list(
                                'reef_balistes_fixed@ps':renderFixedFill(fill_at(Step), maps:get(pattern, St), Step)),
                    lists:foreach(fun(E) -> emit(Sock, E, WallUs, StepMs) end, FEvents),
                    (fill_shown(Step, St))#{last_step => Step};
                named ->
                    {NEvents, Rhythms, Shown} = named_step(Step, maps:get(sampler, St),
                                                           maps:get(rhythms, St), maps:get(shown, St, none)),
                    lists:foreach(fun(E) -> emit(Sock, E, WallUs, StepMs) end, NEvents),
                    (fill_shown(Step, St))#{rhythms => Rhythms, shown => Shown, last_step => Step};
                _ ->
                    %% Grids: apply any tick-tagged inputs whose step has arrived BEFORE
                    %% stepping — the same order the frontend applies them, so a deferred
                    %% edit lands on the same model step on both runtimes. `=<` self-heals
                    %% inputs buffered while no anchor was fresh. applyBInput is arity-2.
                    Pending = maps:get(pending, St),
                    {Due, Keep} = lists:partition(fun({T, _I}) -> T =< Step end, Pending),
                    Bal0 = lists:foldl(
                             fun({_T, I}, B) -> 'reef_balistes_input@ps':applyBInput(I, B) end,
                             maps:get(bal, St), Due),
                    %% renderStep reads the PRE-step state; stepBal then advances (incl.
                    %% the 32-step perturbation resample via reef_bits xorshift32).
                    PlayedStep = maps:get(step, Bal0),
                    Res = 'reef_balistes_sim@ps':stepBal(Bal0),
                    Bal1 = maps:get(bal, Res),
                    Fired = maps:get(fired, Res),
                    GEvents = array:to_list(
                                'reef_balistes_sim@ps':renderStep(Bal0, PlayedStep, Fired)),
                    lists:foreach(fun(E) -> emit(Sock, E, WallUs, StepMs) end, GEvents),
                    St#{bal => Bal1, last_step => Step, pending => Keep}
            end,
            drain(St2, Step + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

%% A `balistes $` line's step: the word its pattern gives at sixteenth Step,
%% and that word's beat. A Rytm rhythm plays from where the word's event
%% began; a Grids beat steps its own engine once, carrying on from where it
%% last left off, so it keeps evolving each time its word comes round. Nothing
%% for a rest, or a word with nothing on the stage.
%%
%% Each event, and each rest, is announced to open pages as it begins (ahead
%% of its step, by the drain's lookahead), so Balistes can show what is
%% playing: `balistes-now <step> <word>`, with the engine state a Grids beat
%% plays on from, or `balistes-now <step> ~` (Triggerfish.Balistes.Follow).
named_step(Step, Sampler, Rhythms, Shown) ->
    case Sampler(Step) of
        {just, #{word := Word, start := Start}} ->
            Event = {Word, Start},
            case stage_beat(Word, Rhythms) of
                {{fixed, Pat}, R1} ->
                    announce(Step, Event, Shown, <<>>),
                    {array:to_list('reef_balistes_fixed@ps':renderFixedFill(fill_at(Step), Pat, Step - Start)), R1, Event};
                {{grids, Bal0}, R1} ->
                    announce(Step, Event, Shown,
                             <<" ", ('reef_balistes_protocol@ps':encodeBalSim(Bal0))/binary>>),
                    Res = 'reef_balistes_sim@ps':stepBal(Bal0),
                    Events = array:to_list('reef_balistes_sim@ps':renderStep(
                                 Bal0, maps:get(step, Bal0), maps:get(fired, Res))),
                    {Text, _} = maps:get(Word, R1),
                    {Events, R1#{Word => {Text, {grids, maps:get(bal, Res)}}}, Event};
                {none, R1} ->
                    announce(Step, Event, Shown, <<>>),
                    {[], R1, Event}
            end;
        _ ->
            announce(Step, rest, Shown, <<>>),
            {[], Rhythms, rest}
    end.

announce(_Step, Shown, Shown, _State) -> ok;
announce(Step, Event, _Shown, State) ->
    Word = case Event of {W, _} -> W; rest -> <<"~">> end,
    catch tidal_link_anchor:sync_broadcast(
            <<"balistes-now ", (integer_to_binary(Step))/binary, " ", Word/binary, State/binary>>),
    ok.

%% A word's beat, read off the stage and parsed again only when its text has
%% changed since the last step that played it (so a Grids beat's running
%% engine survives until Balistes saves a different one under that word).
stage_beat(Word, Rhythms) ->
    case tidal_stage:get_text(<<"balistes/rhythm/", Word/binary>>) of
        Text when is_binary(Text) ->
            case maps:find(Word, Rhythms) of
                {ok, {Text, Beat}} -> {Beat, Rhythms};
                _ ->
                    Beat = parse_beat(Text),
                    {Beat, Rhythms#{Word => {Text, Beat}}}
            end;
        _ -> {none, Rhythms}
    end.

parse_beat(Text) ->
    case 'tidal_named@ps':stageGrids(Text) of
        {just, Bal} -> {grids, Bal};
        {nothing} ->
            case 'tidal_named@ps':stageRhythm(Text) of
                {just, Pat} -> {fixed, Pat};
                {nothing} -> none
            end
    end.

%% One rendered event → scheduled MIDI. Mirrors the frontend's emitHit: the signed
%% Dilla push (pushMs) offsets the onset; a ratchet count > 1 subdivides the step
%% into N retriggers of ~90% gate each. Single channel (drums).
emit(Sock, E, WallUs, StepMs) ->
    case 'reef_balistes_kit@ps':audible(mutes(), maps:get(note, E)) of
        true -> emit_audible(Sock, E, WallUs, StepMs);
        false -> ok
    end.

emit_audible(Sock, E, WallUs, StepMs) ->
    Note   = maps:get(note, E),
    Vel    = maps:get(velocity, E),
    PushMs = maps:get(pushMs, E),
    DurMs  = maps:get(durMs, E),
    N      = maps:get(ratchet, E),
    Onset  = WallUs + round(PushMs * 1000.0),
    case N =< 1 of
        true ->
            fire(Sock, Note, Vel, DurMs, StepMs, Onset);
        false ->
            Sub = StepMs / N,
            lists:foreach(
              fun(K) ->
                  AtUs = Onset + round(K * Sub * 1000.0),
                  fire(Sock, Note, Vel, Sub * 0.9, Sub, AtUs)
              end, lists:seq(0, N - 1))
    end.

%% One drum hit from outside the voice (the Tidal `drums` stream): sent where
%% the routing table says, as the voice's own hits are. `SpanMs` is what a
%% chopped sample voice spreads its slices across.
play_hit(Sock, Note, Vel, DurMs, SpanMs, AtUs) ->
    fire(Sock, Note, Vel, DurMs, SpanMs, AtUs).

%% One hit, sent where the routing table says. With no table, nothing: until
%% 2026-10-10 every hit went to the FH-2 on channel 10, a sound no route named
%% (docs/kb/plans/hardware-through-the-rig.md). `StepMs` is the span a chopped
%% sample voice spreads its slices across: the step, or one ratchet's share.
fire(Sock, Note, Vel, DurMs, StepMs, AtUs) ->
    case routing() of
        none ->
            ok;
        Routing ->
            Hit = #{note => Note, velocity => Vel, atMs => 0.0, durMs => float(DurMs),
                    stepMs => float(StepMs)},
            lists:foreach(fun(Send) -> routing_out:send(Sock, Send, AtUs) end,
                          array:to_list('reef_routing@ps':drumSends(Routing, Hit)))
    end.
