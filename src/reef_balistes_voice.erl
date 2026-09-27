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
         start_fixed_json/3, start_trig_json/3, stop/0, loop/1,
         set_routing_json/1, routing/0]).

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
%% The CoreMIDI port drums go to. <<"FH-2">> fans the note-filtered trigger MCVs
%% out to the FHX-8GT → QuadDrum; <<"IAC Driver Tidal">> sends drums to Ableton.
%% Un-hardcoded from fire/N (2026-07-12, #198): every start seeds this into St, so
%% it's one place to change and structurally ready for a per-voice runtime setter.
-define(DEFAULT_PORT, <<"FH-2">>).
%% POLYTRIG grid resolution: one Tidal cycle == this many steps. MUST match the
%% frontend's Triggerfish.Balistes.Component cycleSteps (16) so both slice the
%% resolved onsets into the same windows.
-define(CYCLE_STEPS, 16).

%% Where the routing table is kept: outside any one voice, so every start,
%% of any engine, plays through the table last pushed.
-define(ROUTING_KEY, {?MODULE, routing}).

start() -> start(?DEFAULT_CHANNEL, ?STEP_BEATS).

%% The drum routing table, pushed by the browser (`balistes-routing <json>`,
%% Reef.Routing's wire form): per canonKit lane, the legs to send each hit
%% down. Until one arrives the voice plays as it always has, every hit to the
%% FH-2 on channel 10; after, it plays what the browser's table says, through
%% the same Reef.Routing.drumSends the browser calls.
set_routing_json(Json) ->
    case 'reef_routing@ps':decodeDrumRouting(ensure_bin(Json)) of
        {right, Routing} ->
            persistent_term:put(?ROUTING_KEY, Routing),
            ok;
        {left, Errs} ->
            {error, {decode, Errs}}
    end.

routing() -> persistent_term:get(?ROUTING_KEY, none).

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
                port => ?DEFAULT_PORT,
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
                                port => ?DEFAULT_PORT,
                                mode => fixed, pattern => Pat, last_step => -1, pending => [] })
                    end),
                    catch register(reef_balistes_voice, NewPid),
                    {ok, NewPid}
            end;
        {left, Errs} -> {error, {decode, Errs}}
    end.

%% Start from a JSON-encoded TrigKit — the POLYTRIG handoff (ASelene mode). Like a
%% fixed rhythm, a resolved rack is a pure function of the absolute step (the onsets
%% are cycle-0 fractions), so it snaps to the current clock step with no phase-hold.
%% If a voice is already running (any mode), swap the kit IN PLACE — the live-edit
%% path (every jack/route edit re-pushes). The WS `balistes-trig <json>` verb.
start_trig_json(Json, Channel, StepBeats) ->
    case 'reef_balistes_protocol@ps':decodeTrigKit(ensure_bin(Json)) of
        {right, Kit} ->
            case whereis(reef_balistes_voice) of
                Pid when is_pid(Pid) ->
                    Pid ! {set_kit, Kit},
                    {ok, Pid};
                _ ->
                    NewPid = spawn(fun() ->
                        {ok, Sock} = gen_udp:open(0, [binary]),
                        erlang:send_after(?POLL_MS, self(), poll),
                        loop(#{ socket => Sock, channel => Channel, step_beats => StepBeats,
                                port => ?DEFAULT_PORT,
                                mode => trig, kit => Kit, last_step => -1, pending => [] })
                    end),
                    catch register(reef_balistes_voice, NewPid),
                    {ok, NewPid}
            end;
        {left, Errs} -> {error, {decode, Errs}}
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
        {set_pattern, Pat} ->
            %% Live fixed-rhythm edit: swap the pattern IN PLACE (keeping the socket +
            %% last_step, so no restart / audio gap). Also switches a running Grids
            %% voice to fixed mode — a fixed rhythm is a pure function of the absolute
            %% step, so it picks up seamlessly on the next step.
            loop(St#{mode => fixed, pattern => Pat});
        {set_kit, Kit} ->
            %% Live POLYTRIG edit: swap the resolved kit IN PLACE (same discipline as
            %% set_pattern). Also switches a running Grids/fixed voice to trig mode —
            %% a rack is a pure function of the absolute step, seamless on the next.
            loop(St#{mode => trig, kit => Kit});
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
            Ch = maps:get(channel, St),
            Sock = maps:get(socket, St),
            Port = maps:get(port, St),
            St2 = case maps:get(mode, St) of
                fixed ->
                    %% Fixed rhythm: a pure function of the ABSOLUTE Step (no state, no
                    %% inputs, no seed) — the shared renderFixed decides every hit, so
                    %% both runtimes reading the same Link step agree with no handoff.
                    FEvents = array:to_list(
                                'reef_balistes_fixed@ps':renderFixed(maps:get(pattern, St), Step)),
                    lists:foreach(fun(E) -> emit(Sock, Ch, Port, E, WallUs, StepMs) end, FEvents),
                    St#{last_step => Step};
                trig ->
                    %% POLYTRIG rack: like a fixed rhythm, a pure function of the ABSOLUTE
                    %% Step off the resolved kit. The shared renderTrigStep slices the
                    %% cycle-0 onsets into this step's window; each fires at its fractional
                    %% sub-step time (Frac * StepMs), the same slice the frontend plays.
                    Fires = array:to_list(
                              'reef_balistes_trig@ps':renderTrigStep(maps:get(kit, St), Step, ?CYCLE_STEPS)),
                    Vel = 'reef_balistes_trig@ps':trigVelocity(),
                    Gate = 'reef_balistes_trig@ps':trigGateMs(),
                    lists:foreach(
                      fun(F) ->
                          AtUs = WallUs + round(maps:get(frac, F) * StepMs * 1000.0),
                          fire(Sock, Ch, Port, maps:get(note, F), Vel, Gate, AtUs)
                      end, Fires),
                    St#{last_step => Step};
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
                    lists:foreach(fun(E) -> emit(Sock, Ch, Port, E, WallUs, StepMs) end, GEvents),
                    St#{bal => Bal1, last_step => Step, pending => Keep}
            end,
            drain(St2, Step + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

%% One rendered event → scheduled MIDI. Mirrors the frontend's emitHit: the signed
%% Dilla push (pushMs) offsets the onset; a ratchet count > 1 subdivides the step
%% into N retriggers of ~90% gate each. Single channel (drums).
emit(Sock, Ch, Port, E, WallUs, StepMs) ->
    Note   = maps:get(note, E),
    Vel    = maps:get(velocity, E),
    PushMs = maps:get(pushMs, E),
    DurMs  = maps:get(durMs, E),
    N      = maps:get(ratchet, E),
    Onset  = WallUs + round(PushMs * 1000.0),
    case N =< 1 of
        true ->
            fire(Sock, Ch, Port, Note, Vel, DurMs, Onset);
        false ->
            Sub = StepMs / N,
            lists:foreach(
              fun(K) ->
                  AtUs = Onset + round(K * Sub * 1000.0),
                  fire(Sock, Ch, Port, Note, Vel, Sub * 0.9, AtUs)
              end, lists:seq(0, N - 1))
    end.

%% One hit, sent where the routing table says; with no table yet, the old
%% single destination (Ch on Port).
fire(Sock, Ch, Port, Note, Vel, DurMs, AtUs) ->
    case routing() of
        none ->
            fire_one(Sock, Ch, Port, Note, Vel, DurMs, AtUs);
        Routing ->
            Hit = #{note => Note, velocity => Vel, atMs => 0.0, durMs => float(DurMs)},
            lists:foreach(fun(Send) -> send(Sock, Send, AtUs) end,
                          array:to_list('reef_routing@ps':drumSends(Routing, Hit)))
    end.

%% One Reef.Routing.Send, its atMs relative to the hit's wall time.
send(Sock, {note, M}, AtUs) ->
    fire_one(Sock, maps:get(channel, M), maps:get(port, M), maps:get(note, M),
             maps:get(velocity, M), maps:get(durMs, M), AtUs + round(maps:get(atMs, M) * 1000.0));
send(Sock, {control, M}, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleCCAt(
              Sock, maps:get(port, M), maps:get(channel, M), maps:get(controller, M),
              maps:get(value, M), AtUs + round(maps:get(atMs, M) * 1000.0)),
    Thunk().

%% Schedule one note to a CoreMIDI Port (by default ?DEFAULT_PORT).
%% QuadDrum routing (2026-07-12, #197/#198): the default <<"FH-2">> fans the FH-2's
%% note-filtered trigger MCVs (set-drum-trig, ch 10) out to FHX-8GT gate jacks → the
%% vpme.de QuadDrum. <<"IAC Driver Tidal">> would send drums to Ableton instead.
fire_one(Sock, Ch, Port, Note, Vel, DurMs, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, Port, Ch, Note, Vel, DurMs, AtUs),
    Thunk().
