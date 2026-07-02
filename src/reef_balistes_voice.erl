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
         stop/0, loop/1]).

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
%% Balistes emits on ONE channel. Default 11: the frontend Balistes plays ch 10, so
%% the rig on ch 11 sits alongside it for A/B in Ableton (per-channel config later).
-define(DEFAULT_CHANNEL, 11).

start() -> start(?DEFAULT_CHANNEL, ?STEP_BEATS).

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
                bal => Bal, last_step => LastStep })
    end),
    catch register(reef_balistes_voice, Pid),
    {ok, Pid}.

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
            Bal0 = maps:get(bal, St),
            %% renderStep reads the PRE-step state (x/y/open/notes/push/ratchet) at the
            %% step being played, exactly as the frontend Component does (renderStep
            %% bal0 playedStep r.fired). stepBal then advances (incl. the 32-step
            %% perturbation resample via reef_bits xorshift32).
            PlayedStep = maps:get(step, Bal0),
            Res = 'reef_balistes_sim@ps':stepBal(Bal0),
            Bal1 = maps:get(bal, Res),
            Fired = maps:get(fired, Res),
            %% renderStep/3 is uncurried (3-arg PS fn → arity-3 erl); call directly.
            Events = array:to_list(
                       'reef_balistes_sim@ps':renderStep(Bal0, PlayedStep, Fired)),
            %% Invert the affine map: the wall time at which beat StepBeat occurs.
            WallUs = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
            StepMs = StepBeats * 60000.0 / Tempo,
            Ch = maps:get(channel, St),
            Sock = maps:get(socket, St),
            lists:foreach(fun(E) -> emit(Sock, Ch, E, WallUs, StepMs) end, Events),
            drain(St#{bal => Bal1, last_step => Step},
                  Step + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

%% One rendered event → scheduled MIDI. Mirrors the frontend's emitHit: the signed
%% Dilla push (pushMs) offsets the onset; a ratchet count > 1 subdivides the step
%% into N retriggers of ~90% gate each. Single channel (drums).
emit(Sock, Ch, E, WallUs, StepMs) ->
    Note   = maps:get(note, E),
    Vel    = maps:get(velocity, E),
    PushMs = maps:get(pushMs, E),
    DurMs  = maps:get(durMs, E),
    N      = maps:get(ratchet, E),
    Onset  = WallUs + round(PushMs * 1000.0),
    case N =< 1 of
        true ->
            fire(Sock, Ch, Note, Vel, DurMs, Onset);
        false ->
            Sub = StepMs / N,
            lists:foreach(
              fun(K) ->
                  AtUs = Onset + round(K * Sub * 1000.0),
                  fire(Sock, Ch, Note, Vel, Sub * 0.9, AtUs)
              end, lists:seq(0, N - 1))
    end.

fire(Sock, Ch, Note, Vel, DurMs, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, Ch, Note, Vel, DurMs, AtUs),
    Thunk().
