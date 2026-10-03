%% @doc reef_voice — an Odonus voice on the BEAM, driven by the shared reef
%% engine and LOCKED to the Ableton Link clock (lockstep co-simulation, P4b).
%%
%% Each poll it reads the current absolute Link beat from tidal_link_anchor and
%% walks a lookahead beat-grid — a direct port of Binnacle.Scheduler (the
%% frontend's grid): step S lands on beat `S * StepBeats`, and its tick index is
%% `floor(beat / StepBeats)`. Because the frontend derives ITS tick index the
%% same way from the SAME anchor (Scheduler.purs: `beat / stepBeats`, and the
%% clock's beat IS the rig's absolute Link beat when locked), the two runtimes
%% agree on "tick N" for free — no shared start-epoch needed. That shared tick
%% identity is what P4c's tick-tagged inputs will key on.
%%
%% Each step advances `reef_engine@ps:stepTick` (the ONE shared per-tick
%% composite: runGen -> tickChord -> stepEmit) and emits the fired notes to IAC
%% via link-spike's MIDI dispatcher, scheduled at the step's anchor-derived wall
%% time. For now the SimState runs with NO gen sources (gen = []) and a fixed
%% seed — generation + seed arrive with the handoff (P4d) and inputs (P4c); this
%% phase is purely: clock-lock the pushed Odonus record and step it in time.
%%
%% Still started from the WS `reef-odonus <json>` verb (start_json/3). Idles when
%% no fresh Link anchor is present (standalone has no rig to sync with anyway).
-module(reef_voice).
-export([set_routing_json/1, routing/0,
         start/0, start/2, start_json/3, start_sim_json/3, start_sim_at_json/4,
         stop/0, ping/0, loop/1]).
%% what a loop on the rig (rig_loops) plays a note through
-export([route_note/7, maybe_schedule_cv/5, init_cv/0]).

%% Lead time (us) for the smoke test — schedule far enough ahead that link-spike
%% can receive + schedule (a 5ms lead gets dropped as already-past).
-define(LEAD_US, 200000).

%% Scheduler poll interval (ms) — how often we walk the grid. Note timing is
%% absolute (WallUs from the anchor), so poll jitter only affects lookahead slack.
-define(POLL_MS, 25).
%% Schedule this far ahead so link-spike has lead time (mirrors the frontend's
%% lookaheadMs and the old fixed LEAD_US).
-define(LOOKAHEAD_MS, 200.0).
%% Model step length in beats. 0.25 = a 1/16 note (the frontend's stepDiv=1).
%% Must match the frontend's model-step length for the tick indices to align;
%% carried as a voice field so a future handoff can set it per-instrument.
-define(STEP_BEATS, 0.25).
%% Treat the Link source as offline past this age (mirrors tidal_link_anchor).
-define(STALE_ANCHOR_US, 2000000).
%% If the next step to emit is more than this many steps AHEAD of the currently
%% sounding step, the Link beat must have jumped BACKWARD (transport restart / Link
%% re-sync) — re-snap to now rather than waiting out the gap in silence. Normal
%% lead is only the lookahead (~2-3 steps), so this is comfortably clear of it.
-define(SNAP_AHEAD, 8).
%% How far past the last computed step a move is tagged (see the {move, _}
%% clause): Triggerfish tags its own gestures inputBufferSteps (2) ahead.
-define(MOVE_LEAD_STEPS, 2).
%% Default base channel: heads emit on BASE_CHANNEL + headIdx → 12/13/14/15, one
%% MIDI channel per head so they're separable in Ableton (per-voice recording,
%% frontend-vs-backend comparison, golden capture).
-define(BASE_CHANNEL, 12).

%% The heads' routing (Reef.Routing.VoiceRouting), pushed by the Odonus page
%% (`odonus-routing <json>`) from the routing table: each head's live legs,
%% resolved to whole port names. Kept outside any one voice, and on the stage
%% (odonus/routing) across restarts. Until one arrives the heads play as they
%% always have, on IAC Driver Tidal ch BASE_CHANNEL + head (12-15).
-define(ROUTING_KEY, {?MODULE, routing}).

set_routing_json(Json) ->
    case 'reef_routing@ps':decodeVoiceRouting(if is_binary(Json) -> Json; true -> list_to_binary(Json) end) of
        {right, Routing} -> persistent_term:put(?ROUTING_KEY, Routing), ok;
        {left, Errs} -> {error, {decode, Errs}}
    end.

routing() -> persistent_term:get(?ROUTING_KEY, none).

%% CV out (task #190/#192): in addition to the MIDI emit, fork fired heads to the
%% ES-9 as analog CV. Each ROUTE binds one head to an ES-9 pitch bus + calibration
%% table (from Amphora), applied by the es9_cv realiser so an intended note lands
%% in tune on the VCO; a route may also carry a `trig_bus` for a note-gate/trigger
%% pulse (the modular-voice facet, Triggerfish #240). The BEAM half of "calibrate
%% the output, not the module" (CALIBRATION.md). head→bus→table is a fact about the
%% RIG PATCH, not the music, so it's read from the `odonus_cv` app env (see
%% purerl_tidal.app.src) rather than the pushed pattern; this compiled fallback is
%% used only when that env isn't set.
%%
%% Route keys: head (0-3), pitch_bus, label (Amphora calibration label), and
%% optionally trig_bus (+ trig_v volts / trig_ms width) and pitch_lead_ms (how far
%% ahead of the strike to land the pitch DC so the VCO is settled). No trig_bus =>
%% pitch only (the Saïch shape). The default below is today's CIP single-voice
%% patch: head 0 → CIP pitch on bus 8, trigger on bus 9.
-define(DEFAULT_ODONUS_CV,
        #{enabled => true,
          routes  =>
            [#{head => 0, pitch_bus => 8, trig_bus => 9,
               label => <<"cursus-iteritas-percido">>,
               trig_v => 5.0, trig_ms => 10.0, pitch_lead_ms => 5}]}).

%% Single-note smoke test: fire middle C (60) on ch 16, +200ms.
ping() ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, 16, 60, 100, 500,
              erlang:system_time(microsecond) + ?LEAD_US),
    R = Thunk(),
    gen_udp:close(Sock),
    R.

%% Base channel 12 by default → the four heads land on ch 12/13/14/15, each on its
%% own MIDI channel (see emit/5) so they're separable in Ableton Session view for
%% eyeballing + frontend-vs-backend comparison.
start() -> start(?BASE_CHANNEL, ?STEP_BEATS).

%% BaseChannel (heads on BaseChannel+headIdx, so keep it ≤ 13 for four heads),
%% StepBeats (model step length in beats). Hardcoded defaultOdonus.
start(BaseChannel, StepBeats) ->
    do_start('reef_odonus@ps':defaultOdonus(), BaseChannel, StepBeats).

%% Start a voice from a JSON-encoded Odonus record — the reef wire format
%% (Reef.Protocol). Decoding goes through the SAME codec the frontend encodes
%% with (reef_protocol@ps:decodeOdonus). This is the WS `reef-odonus <json>`
%% entry point. StepBeats is the model step length in beats (0.25 = 1/16).
start_json(Json, Channel, StepBeats) ->
    case 'reef_protocol@ps':decodeOdonus(ensure_bin(Json)) of
        {right, Odo}  -> do_start(Odo, Channel, StepBeats);
        {left, Errs}  -> {error, {decode, Errs}}
    end.

%% Start a voice from a JSON-encoded WHOLE SimState — the lockstep HANDOFF (P4d).
%% decodeSim rebuilds {odo, gen, spread, bias, seed} exactly as the frontend
%% encoded it (proven byte-identical, Reef.Conformance.simRun), so the rig picks
%% up the frontend's full state — gen config AND seed — and co-simulates in step.
%% This is the WS `reef-sim <json>` entry point.
start_sim_json(Json, Channel, StepBeats) ->
    case 'reef_protocol@ps':decodeSim(ensure_bin(Json)) of
        {right, Sim}  -> do_start_sim(Sim, Channel, StepBeats, -1);
        {left, Errs}  -> {error, {decode, Errs}}
    end.

%% Phase-aligned handoff (P5): like start_sim_json, but the pushed state is held
%% until absolute model step N (the frontend's nextModelStep — the step it will
%% next emit from exactly this state). We seed last_step = N-1 so the voice's first
%% emitted step is N, playing the pushed state on the SAME absolute step the
%% frontend does. That removes the old handoff flam, where the voice snapped to ITS
%% current step (up to a model-step / a beat off the frontend's). The WS
%% `reef-sim-at <step> <json>` entry point.
start_sim_at_json(Json, Channel, StepBeats, N) ->
    case 'reef_protocol@ps':decodeSim(ensure_bin(Json)) of
        {right, Sim}  -> do_start_sim(Sim, Channel, StepBeats, N - 1);
        {left, Errs}  -> {error, {decode, Errs}}
    end.

%% Odonus-only start (the `reef-odonus` verb): wrap the record in a SimState with
%% NO gen sources (gen = [] → runGen is a no-op) and a fixed seed. Correct for the
%% static-lockstep case (generation off); the handoff path above carries real gen.
do_start(Odo, Channel, StepBeats) ->
    Sim = #{ gen => array:from_list([]),
             spread => 0.5,
             bias => 0.5,
             odo => Odo,
             seed => 'reef_marbles@ps':seedFrom(1),
             %% Reef.Gen's SimState gained `frozen` (de207e8, 2026-07-09); without
             %% it stepTick's clause never matched and this path crashed on step 1.
             frozen => false },
    do_start_sim(Sim, Channel, StepBeats, -1).

%% Replace any running voice, then spawn a fresh clock-locked one from a full
%% SimState. The UDP socket is opened INSIDE the spawned loop so it's owned by
%% (and lives as long as) the loop. LastStep seeds `last_step`: -1 snaps to the
%% current clock step on the first poll (the reef-odonus / reef-sim path); N-1
%% holds the state for absolute step N (the phase-aligned reef-sim-at path).
do_start_sim(Sim, Channel, StepBeats, LastStep) ->
    stop(),
    Cv = init_cv(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary]),
        erlang:send_after(?POLL_MS, self(), poll),
        loop(#{ socket => Sock, channel => Channel, step_beats => StepBeats,
                sim => Sim, last_step => LastStep, pending => [], swing => 0.0,
                cv => Cv })
    end),
    catch register(reef_voice, Pid),
    {ok, Pid}.

%% Load each route's calibration table from Amphora once at voice start (never on
%% the hot path) and return a `head => route-with-table` map. Returns `undefined`
%% when CV-out is off, no route's table loads, or the fetch fails — the voice then
%% runs MIDI-only, so a down Amphora never silences the rig. See es9_cv +
%% CALIBRATION.md.
init_cv() ->
    case application:get_env(purerl_tidal, odonus_cv, ?DEFAULT_ODONUS_CV) of
        #{enabled := true, routes := Routes} when is_list(Routes) ->
            Labels = [maps:get(label, R) || R <- Routes],
            case es9_cv:fetch_tables(Labels) of
                {ok, Tables} ->
                    ByHead = build_routes(Routes, Tables),
                    tidal_log:info(
                      "reef_voice CV-out ON: ~B/~B route(s) have tables (heads ~p)~n",
                      [maps:size(ByHead), length(Routes), lists:sort(maps:keys(ByHead))]),
                    case maps:size(ByHead) of
                        0 -> undefined;
                        _ -> ByHead
                    end;
                {error, Why} ->
                    tidal_log:err(
                      "reef_voice CV-out OFF (Amphora fetch failed: ~p) — MIDI only~n",
                      [Why]),
                    undefined
            end;
        _ ->
            undefined
    end.

%% Zip routes with their fetched tables (same order, one per label) into a
%% head => route#{points => Table} map, dropping any route whose table didn't
%% load (missing label in Amphora).
build_routes(Routes, Tables) ->
    lists:foldl(
      fun({_Route, undefined}, Acc) -> Acc;
         ({Route, Points}, Acc) ->
              Acc#{maps:get(head, Route) => Route#{points => Points}}
      end, #{}, lists:zip(Routes, Tables)).

stop() ->
    case whereis(reef_voice) of
        undefined -> ok;
        Pid ->
            Pid ! stop,
            catch unregister(reef_voice),
            ok
    end.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L).

%% The clock-locked loop: `poll` self-messages drive the grid walk (scheduled
%% via send_after so an incoming message can't reset the timer). `stop` closes
%% the socket. `{apply_input, Tick, Input}` (lockstep, P4c) buffers a tick-tagged
%% input broadcast from the frontend; `drain` applies it before stepping the
%% matching model step, so both runtimes evolve identically through the edit.
%% `Input` is an opaque reef_input@ps term (a decoded Reef.Input.Input) — we never
%% inspect it, only hand it to reef_input@ps:applyInput when its step arrives.
loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(socket, St));
        {apply_input, Tick, Input} ->
            Pending = maps:get(pending, St),
            loop(St#{pending => Pending ++ [{Tick, Input}]});
        {move, Move} ->
            %% A move (Reef.Move, from an `odonus` line): its gestures land together
            %% on the next step to be computed, and a `for n` restores the settings it
            %% changed n bars later. Scheduled against the current state, so the
            %% restore puts back what was there before the move.
            %% Tagged two steps past this voice's lookahead, as the frontend tags
            %% its own gestures, so a following page receives each one before
            %% it is due and applies it on the same step (lockstep: mutation
            %% threads a shared seed, so a step's difference would diverge).
            Sched = 'reef_move@ps':schedule(Move, maps:get(sim, St)),
            T = maps:get(last_step, St) + ?MOVE_LEAD_STEPS,
            StepsPerBar = round(4 / maps:get(step_beats, St)),
            Now = [{T, I} || I <- array:to_list(maps:get(now, Sched))],
            Later = [{T + Bars * StepsPerBar, I}
                     || #{bars := Bars, inputs := Is} <- array:to_list(maps:get(later, Sched)),
                        I <- array:to_list(Is)],
            lists:foreach(fun({Tick, I}) ->
                              Json = 'reef_protocol@ps':encodeTagged(#{tick => Tick, input => I}),
                              tidal_link_anchor:sync_broadcast(<<"reef-input ", Json/binary>>)
                          end, Now ++ Later),
            Pending = maps:get(pending, St),
            loop(St#{pending => Pending ++ Now ++ Later});
        {set_step_beats, B} when is_number(B), B > 0 ->
            %% STEP LENGTH sync (lockstep P4c): the frontend's STEP LENGTH divides
            %% the 1/16 grid; match it so we step at the same rate and share the same
            %% model-step numbering. Reset last_step so we re-snap to the current step
            %% in the new grid rather than replaying/skipping under the old numbering.
            loop(St#{step_beats => B, last_step => -1});
        {set_swing, S} when is_number(S) ->
            %% SWING sync (lockstep P4f render stage 2): the fraction of a step by which
            %% odd model steps lag the audible onset. Timing expression only (never
            %% touches the model), so it just updates the field — no last_step reset.
            loop(St#{swing => S});
        {emit_cv, Bus, Value} ->
            %% Scheduled pitch-CV send (task #190): emit/7 defers each head's
            %% `/cv` to its step onset via send_after so the analog VCO's pitch
            %% lands ON the beat, not up to a lookahead early. Fire-and-continue.
            es9_cv:send_cv(maps:get(socket, St), Bus, Value),
            loop(St);
        poll ->
            St2 = tick(St),
            erlang:send_after(?POLL_MS, self(), poll),
            loop(St2)
    end.

%% One poll: read the live Link beat, then emit every model step from the last
%% one up to the lookahead horizon. Idle if there's no fresh anchor (the rig
%% clock is the sync source; without it there is nothing to co-simulate with).
tick(St) ->
    NowUs = erlang:system_time(microsecond),
    case tidal_link_anchor:info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, _Quantum, LastRecvUs}
                when (NowUs - LastRecvUs) =< ?STALE_ANCHOR_US, Tempo > 0 ->
            StepBeats = maps:get(step_beats, St),
            BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
            %% The step currently sounding; never replay history (the clock jumps
            %% forward on free-run -> Link-lock — mirror Scheduler.purs's snap).
            NowStep = trunc(BeatNow / StepBeats),
            Next0 = maps:get(last_step, St) + 1,
            %% Re-snap on ANY clock discontinuity, not just forward. Behind
            %% (free-run -> Link-lock) we caught already; more than ?SNAP_AHEAD
            %% steps ahead means the beat jumped BACKWARD (transport restart /
            %% re-sync) and the voice would otherwise strand itself in silence
            %% waiting for a far-future step. Either way, snap to the current step.
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

%% Emit each step whose beat is within the horizon, advancing the shared engine
%% and scheduling its notes at the step's anchor-derived wall time.
drain(St, Step, Horizon, AnchorUs, BeatAtAnchor, Tempo) ->
    StepBeats = maps:get(step_beats, St),
    StepBeat = Step * StepBeats,
    case StepBeat =< Horizon of
        false ->
            St;
        true ->
            %% LOCKSTEP (P4c): apply any tick-tagged inputs whose step has arrived
            %% BEFORE stepping — the same order the frontend's Step loop uses, so a
            %% deferred gesture lands on the same model step on both runtimes. `=<`
            %% (not `==`) self-heals: an input buffered while no anchor was fresh
            %% applies on the first step that runs; applied entries drop from Keep.
            Pending = maps:get(pending, St),
            {Due, Keep} = lists:partition(fun({T, _I}) -> T =< Step end, Pending),
            Sim0 = lists:foldl(
                     fun({_T, I}, S) -> ('reef_input@ps':applyInput(I))(S) end,
                     maps:get(sim, St), Due),
            %% HARMONY and SCALE patterns: the rig is the only reader of Tidal
            %% (docs/kb/plans/gpl-boundary-review.md). Sample both for the step a
            %% move would land on (the same lead), as the patterns will stand
            %% then (pending inputs due by that step folded in), and when the
            %% sample changes, queue it as a SetSampled for that step here and
            %% broadcast it tick-tagged, so the page applies it on the same step.
            %% Four beats to the cycle: step N is cycle N * quarters / 16.
            Quarters = round(StepBeats * 4),
            LeadStep = Step + ?MOVE_LEAD_STEPS,
            AheadSim = lists:foldl(
                         fun({_, I}, S) -> ('reef_input@ps':applyInput(I))(S) end,
                         Sim0, [E || {Tk, _} = E <- Keep, Tk =< LeadStep]),
            HSample = fun(Txt) -> 'tidal_harmony@ps':harmonySampler(LeadStep * Quarters, 16, Txt) end,
            SSample = fun(Txt) -> 'tidal_scales@ps':scaleSampler(LeadStep * Quarters, 16, Txt) end,
            Sampled = 'reef_engine@ps':sampleInput(HSample, SSample, AheadSim),
            SampledJson = 'reef_protocol@ps':encodeInput(Sampled),
            Keep1 = case SampledJson =:= maps:get(last_sample, St, none) of
                        true -> Keep;
                        false ->
                            TaggedJson = 'reef_protocol@ps':encodeTagged(#{tick => LeadStep, input => Sampled}),
                            tidal_link_anchor:sync_broadcast(<<"reef-input ", TaggedJson/binary>>),
                            Keep ++ [{LeadStep, Sampled}]
                    end,
            Res = 'reef_engine@ps':stepTick(Sim0),
            Sim1 = maps:get(sim, Res),
            Odo1 = maps:get(odo, Sim1),
            Fired = array:to_list(maps:get(fired, Res)),
            %% Invert the affine map: the wall time at which beat StepBeat occurs.
            WallUs0 = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
            StepMs = StepBeats * 60000.0 / Tempo,
            %% SWING (lockstep P4f render stage 2): lag the odd model steps by
            %% `swing × stepMs` on the audible onset — the SAME shift, on the same
            %% absolute-step parity, the frontend applies (Grid.purs: swingMs on
            %% modelStep rem 2 == 1). Shifts the whole step's onset together, so the
            %% shared renderHits offsets ride along unchanged.
            SwingUs = case Step rem 2 of
                          1 -> round(maps:get(swing, St) * StepMs * 1000.0);
                          _ -> 0
                      end,
            WallUs = WallUs0 + SwingUs,
            Ch = maps:get(channel, St),
            Sock = maps:get(socket, St),
            Cv = maps:get(cv, St, undefined),
            lists:foreach(fun(F) -> emit(Sock, Ch, Cv, Odo1, F, WallUs, StepMs) end, Fired),
            drain(St#{sim => Sim1, last_step => Step, pending => Keep1, last_sample => SampledJson},
                  Step + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

%% Each head emits on its OWN channel = BaseCh + headIdx (12/13/14/15 by default),
%% mirroring the frontend's per-head channels (heads I-IV on ch 1-4) so every voice
%% is separable in Ableton for comparison + golden capture. Note LENGTH and RATCHET
%% retriggers come from the SHARED renderer (reef_render@ps:renderHits) — the same
%% code the frontend uses — so gate/ratchet render identically on both runtimes
%% (lockstep P4f stage 1). Each hit is scheduled at the step onset + its offsetMs.
emit(Sock, BaseCh, Cv, Odo, F, WallUs, StepMs) ->
    Note    = maps:get(pitch, F),
    Vel     = maps:get(vel, F),
    HeadIdx = maps:get(headIdx, F),
    Ch      = BaseCh + HeadIdx,
    %% CV fork (task #190/#192): schedule this head's pitch CV (and gate, if the
    %% route has one) to land at the step onset. Independent of MIDI (the VCO has
    %% no MIDI in); the note still goes out for browser/Ableton comparison.
    maybe_schedule_cv(Sock, Cv, HeadIdx, Note, WallUs),
    %% renderHits is a 3-arg PS function → purs-backend-erl emits it uncurried as
    %% renderHits/3 (there is no renderHits/1), so call it directly, not curried.
    Hits = array:to_list('reef_render@ps':renderHits(Odo, StepMs, F)),
    Sent = [begin
                AtUs  = round(WallUs + maps:get(offsetMs, Hit) * 1000.0),
                DurMs = maps:get(durMs, Hit),
                route_note(Sock, HeadIdx, Note, Vel, DurMs, StepMs, AtUs, Ch),
                {AtUs, Note, Vel, DurMs, HeadIdx}
            end || Hit <- Hits],
    %% the record buffer keeps what Odonus played (docs/kb/plans/the-deck.md)
    catch rig_loops:record(<<"odonus">>, Sent).

%% One note of head HeadIdx: where the routing table sends it (Reef.Routing,
%% the same function the page's own emit calls), or before a table arrives,
%% the head's own channel of the IAC bus.
route_note(Sock, HeadIdx, Note, Vel, DurMs, StepMs, AtUs) ->
    route_note(Sock, HeadIdx, Note, Vel, DurMs, StepMs, AtUs, ?BASE_CHANNEL + HeadIdx).

route_note(Sock, HeadIdx, Note, Vel, DurMs, StepMs, AtUs, Ch) ->
    case routing() of
        none ->
            Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
                      Sock, <<"IAC Driver Tidal">>, Ch, Note, Vel, DurMs, AtUs),
            Thunk();
        Routing ->
            Sends = 'reef_routing@ps':voiceRoutingSends(Routing, HeadIdx,
                      #{note => Note, velocity => Vel, atMs => 0.0,
                        durMs => float(DurMs), stepMs => float(StepMs)}),
            lists:foreach(fun(S) -> routing_out:send(Sock, S, AtUs) end, array:to_list(Sends))
    end.

%% Route this fired head's note to its ES-9 CV bus(es). Looks up the head's route
%% (from init_cv's head => route map); no route for this head (or CV off) → no-op.
%%   PITCH: realise the note through the route's calibration table, then defer the
%%     `/cv` DC send via send_after so it lands `pitch_lead_ms` BEFORE the strike —
%%     the VCO is settled when the envelope fires. (There's no scheduled `/cv/at`.)
%%   GATE (optional): a sample-accurate `/cv/trig/at` sent NOW, carrying the full
%%     time-to-beat as delay_ms; the daemon fires the pulse on the exact frame.
maybe_schedule_cv(_Sock, undefined, _HeadIdx, _Note, _WallUs) -> ok;
maybe_schedule_cv(Sock, ByHead, HeadIdx, Note, WallUs) when is_map(ByHead) ->
    case maps:get(HeadIdx, ByHead, undefined) of
        undefined -> ok;
        Route ->
            Points   = maps:get(points, Route),
            PitchBus = maps:get(pitch_bus, Route),
            Hz       = es9_cv:note_to_hz(Note),
            Volts    = es9_cv:realise(Points, Hz),
            Value    = Volts / 10.0,
            DelayMs  = max(0, (WallUs - erlang:system_time(microsecond)) div 1000),
            LeadMs   = maps:get(pitch_lead_ms, Route, 5),
            erlang:send_after(max(0, DelayMs - LeadMs), self(),
                              {emit_cv, PitchBus, Value}),
            maybe_send_trig(Sock, Route, DelayMs),
            ok
    end.

%% Fire the gate for a route that has a trig_bus (+5 V / 10 ms defaults). Sent
%% immediately with the time-to-beat as delay_ms so the daemon schedules it
%% sample-accurately. No trig_bus → pitch-only route (the Saïch shape) → no-op.
maybe_send_trig(Sock, #{trig_bus := TrigBus} = Route, DelayMs) ->
    TrigV  = maps:get(trig_v, Route, 5.0),
    TrigMs = maps:get(trig_ms, Route, 10.0),
    es9_cv:send_trig_at(Sock, TrigBus, TrigV / 10.0, TrigMs, DelayMs);
maybe_send_trig(_Sock, _Route, _DelayMs) -> ok.
