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
%% composite: runGen -> tickChord -> stepEmit) and plays the fired notes where
%% the routing table says (Reef.Articulation: MIDI lines with their legato,
%% triggers, a Rample, ES-9 lines with their slides), scheduled at the step's
%% anchor-derived wall time. The rig is the only sender to hardware
%% (docs/kb/plans/hardware-through-the-rig.md): no table, no sound. For now the SimState runs with NO gen sources (gen = []) and a fixed
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
-export([route_note/7]).

%% Lead time (us) for the smoke test — schedule far enough ahead that link-spike
%% can receive + schedule (a 5ms lead gets dropped as already-past).
-define(LEAD_US, 200000).

%% Scheduler poll interval (ms) — how often we walk the grid. Note timing is
%% absolute (WallUs from the anchor), so poll jitter only affects lookahead slack.
-define(POLL_MS, 25).
%% Schedule this far ahead so link-spike has lead time (mirrors the frontend's
%% lookaheadMs and the old fixed LEAD_US).
-define(LOOKAHEAD_MS, 200.0).
%% Model step length in beats: 0.25, a 16th note, as on the page. Odonus's
%% clock and each head's ratio of it live in the model (Reef.Odonus), so the
%% step never changes; it is still carried as a voice field (`reef-steplen`).
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
%% The channel a bare start/0 records in its state. Where the heads play is
%% the routing table's to say (route_note, play), never a default channel.
-define(BASE_CHANNEL, 12).

%% The heads' routing (Reef.Routing.VoiceRouting), pushed by the Odonus page
%% (`odonus-routing <json>`) from the routing table: each head's live legs,
%% resolved to whole port names. Kept outside any one voice, and on the stage
%% (odonus/routing) across restarts. Until one arrives the heads are silent:
%% a default destination is a sound no route names.
-define(ROUTING_KEY, {?MODULE, routing}).

set_routing_json(Json) ->
    case 'reef_routing@ps':decodeVoiceRouting(if is_binary(Json) -> Json; true -> list_to_binary(Json) end) of
        {right, Routing} -> persistent_term:put(?ROUTING_KEY, Routing), ok;
        {left, Errs} -> {error, {decode, Errs}}
    end.

routing() -> persistent_term:get(?ROUTING_KEY, none).

%% Single-note smoke test: fire middle C (60) on ch 16, +200ms.
ping() ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, 16, 60, 100, 500,
              erlang:system_time(microsecond) + ?LEAD_US),
    R = Thunk(),
    gen_udp:close(Sock),
    R.

%% defaultOdonus, for a shell: it sounds wherever the routing table on the stage
%% sends Odonus's heads, and nowhere if there is none.
start() -> start(?BASE_CHANNEL, ?STEP_BEATS).

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
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary]),
        erlang:send_after(?POLL_MS, self(), poll),
        loop(#{ socket => Sock, channel => Channel, step_beats => StepBeats,
                sim => Sim, last_step => LastStep, pending => [], swing => 0.0,
                held => array:from_list([{nothing}, {nothing}, {nothing}, {nothing}]),
                polys => array:from_list([]) })
    end),
    catch register(reef_voice, Pid),
    {ok, Pid}.

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
            %% let go of every held note and open gate, then close
            Sock = maps:get(socket, St),
            case routing() of
                none -> ok;
                Routing ->
                    Releases = 'reef_articulation@ps':releaseAll(Routing, maps:get(held, St),
                                                                 maps:get(polys, St)),
                    Now = erlang:system_time(microsecond),
                    lists:foreach(fun(S) -> routing_out:send(Sock, S, Now) end, array:to_list(Releases))
            end,
            gen_udp:close(Sock);
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
            %% chords as voiced, octaves kept (docs/kb/plans/harmony-routes-coherent.md)
            HSample = fun(Txt) -> 'tidal_harmony@ps':voicingSampler(LeadStep * Quarters, 16, Txt) end,
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
            Fired = maps:get(fired, Res),
            %% Invert the affine map: the wall time at which beat StepBeat occurs.
            WallUs0 = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
            StepMs = StepBeats * 60000.0 / Tempo,
            %% SWING (lockstep P4f render stage 2): lag the odd model steps by
            %% `swing × stepMs` on the audible onset — the SAME shift, on the same
            %% absolute-step parity, the frontend applies (Grid.purs: swingMs on
            %% modelStep rem 2 == 1). Shifts the whole step's onset together, so the
            %% articulation's offsets ride along unchanged.
            SwingUs = case Step rem 2 of
                          1 -> round(maps:get(swing, St) * StepMs * 1000.0);
                          _ -> 0
                      end,
            WallUs = WallUs0 + SwingUs,
            Sock = maps:get(socket, St),
            %% Heads muted since the last step let go of what they hold first.
            Muted = 'reef_articulation@ps':newlyMuted(maps:get(odo, maps:get(sim, St)), Odo1),
            {Held, Polys} = play(Sock, Odo1, Fired, Muted, maps:get(held, St), maps:get(polys, St),
                                 WallUs, StepMs),
            record(Odo1, Fired, WallUs, StepMs),
            drain(St#{sim => Sim1, last_step => Step, pending => Keep1, last_sample => SampledJson,
                      held => Held, polys => Polys},
                  Step + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

%% Play one step down the routing table: Reef.Articulation decides every send
%% (legato, slides, triggers, ES-9 lines, and the instruments that allocate
%% across voices) from the fired notes, what each head was holding and each
%% allocator's state, and returns both as they stand now. The allocators keep
%% time in the step's wall milliseconds. No table, no sound.
play(Sock, Odo, Fired, Muted, Held, Polys, WallUs, StepMs) ->
    case routing() of
        none -> {Held, Polys};
        Routing ->
            Notes = array:from_list([#{fired => F, velocity => maps:get(vel, F)}
                                     || F <- array:to_list(Fired)]),
            Played = 'reef_articulation@ps':playStep(Routing,
                       #{odo => Odo, stepMs => float(StepMs), nowMs => WallUs / 1000.0,
                         polys => Polys, held => Held, newlyMuted => Muted, notes => Notes}),
            lists:foreach(fun(S) -> routing_out:send(Sock, S, WallUs) end,
                          array:to_list(maps:get(sends, Played))),
            {maps:get(held, Played), maps:get(polys, Played)}
    end.

%% The record buffer keeps what Odonus played (docs/kb/plans/the-deck.md): each
%% fired note at its own time in the step, for its gate.
record(Odo, Fired, WallUs, StepMs) ->
    Sent = [{WallUs + round('reef_render@ps':subOffsetMs(float(StepMs), F) * 1000.0),
             maps:get(pitch, F), maps:get(vel, F),
             'reef_render@ps':gateMs(Odo, float(StepMs), F), maps:get(headIdx, F)}
            || F <- array:to_list(Fired)],
    catch rig_loops:record(<<"odonus">>, Sent).

%% One recorded note of head HeadIdx, as a loop on the rig replays it: down the
%% same legs and ES-9 lines as live, as a plain note (a loop keeps the notes,
%% not their slides). No table, no sound.
route_note(Sock, HeadIdx, Note, Vel, DurMs, _StepMs, AtUs) ->
    case routing() of
        none -> ok;
        Routing ->
            Sends = 'reef_articulation@ps':plainSends(Routing, HeadIdx,
                      #{pitch => Note, velocity => Vel, gateMs => float(DurMs), atMs => 0.0}),
            lists:foreach(fun(S) -> routing_out:send(Sock, S, AtUs) end, array:to_list(Sends))
    end.
