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
-export([start/0, start/2, start_json/3, start_sim_json/3, start_sim_at_json/4,
         stop/0, ping/0, loop/1]).

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
%% Default base channel: heads emit on BASE_CHANNEL + headIdx → 12/13/14/15, one
%% MIDI channel per head so they're separable in Ableton (per-voice recording,
%% frontend-vs-backend comparison, golden capture).
-define(BASE_CHANNEL, 12).

%% FIRST-LIGHT CV out (task #190, 2026-07-11): in addition to the MIDI emit,
%% fork each fired head to an ES-9 CV bus — headIdx K → bus ?CV_BASE_BUS + K —
%% with that voice's Saïch calibration table (from Amphora) applied by the
%% es9_cv realiser, so an intended note lands in tune on the analog VCO. This is
%% the BEAM half of "calibrate the output, not the module" (CALIBRATION.md).
%% `true` also drives the modular; flip to `false` for MIDI-only. Heads 0-3 map
%% to buses 8-11 and to the four Saïch voices (labels saich-1..4).
-define(ODONUS_CV_FIRST_LIGHT, true).
-define(CV_BASE_BUS, 8).
-define(CV_LABELS, [<<"saich-1">>, <<"saich-2">>, <<"saich-3">>, <<"saich-4">>]).

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
             seed => 'reef_marbles@ps':seedFrom(1) },
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

%% Load the per-head Saïch calibration tables from Amphora once at voice start
%% (never on the hot path). Returns `undefined` when CV-out is off or the fetch
%% fails — the voice then runs MIDI-only, so a down Amphora never silences the
%% rig. See es9_cv + CALIBRATION.md.
init_cv() ->
    case ?ODONUS_CV_FIRST_LIGHT of
        false -> undefined;
        true ->
            case es9_cv:fetch_tables(?CV_LABELS) of
                {ok, Tables} ->
                    Have = length([T || T <- Tables, T =/= undefined]),
                    tidal_log:info(
                      "reef_voice CV-out ON: base bus ~B, ~B/~B tables from Amphora~n",
                      [?CV_BASE_BUS, Have, length(?CV_LABELS)]),
                    #{base_bus => ?CV_BASE_BUS, tables => Tables};
                {error, Why} ->
                    tidal_log:err(
                      "reef_voice CV-out OFF (Amphora fetch failed: ~p) — MIDI only~n",
                      [Why]),
                    undefined
            end
    end.

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
            drain(St#{sim => Sim1, last_step => Step, pending => Keep},
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
    %% CV fork (task #190): schedule this head's pitch CV to land at the step
    %% onset. Independent of MIDI (Saïch has no MIDI in); the note still goes out
    %% for browser/Ableton comparison.
    maybe_schedule_cv(Cv, HeadIdx, Note, WallUs),
    %% renderHits is a 3-arg PS function → purs-backend-erl emits it uncurried as
    %% renderHits/3 (there is no renderHits/1), so call it directly, not curried.
    Hits = array:to_list('reef_render@ps':renderHits(Odo, StepMs, F)),
    lists:foreach(
      fun(Hit) ->
          AtUs  = round(WallUs + maps:get(offsetMs, Hit) * 1000.0),
          DurMs = maps:get(durMs, Hit),
          Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
                    Sock, <<"IAC Driver Tidal">>, Ch, Note, Vel, DurMs, AtUs),
          Thunk()
      end, Hits).

%% One CV send per fired head: realise the note through this head's calibration
%% table (headIdx K → table K, bus ?CV_BASE_BUS + K), then defer the send to the
%% step's wall time so it's on-beat. No table for this head (or CV off) → no-op.
maybe_schedule_cv(undefined, _HeadIdx, _Note, _WallUs) -> ok;
maybe_schedule_cv(#{base_bus := BaseBus, tables := Tables}, HeadIdx, Note, WallUs) ->
    case nth0(HeadIdx, Tables) of
        undefined -> ok;
        Points ->
            Hz    = es9_cv:note_to_hz(Note),
            Volts = es9_cv:realise(Points, Hz),
            Value = Volts / 10.0,
            DelayMs = max(0, (WallUs - erlang:system_time(microsecond)) div 1000),
            erlang:send_after(DelayMs, self(), {emit_cv, BaseBus + HeadIdx, Value}),
            ok
    end.

%% 0-indexed list access with an `undefined` default for out-of-range.
nth0(I, L) when is_integer(I), I >= 0, I < length(L) -> lists:nth(I + 1, L);
nth0(_, _) -> undefined.
