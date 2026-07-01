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
-export([start/0, start/2, start_json/3, start_sim_json/3, stop/0, ping/0, loop/1]).

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

%% Single-note smoke test: fire middle C (60) on ch 16, +200ms.
ping() ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, 16, 60, 100, 500,
              erlang:system_time(microsecond) + ?LEAD_US),
    R = Thunk(),
    gen_udp:close(Sock),
    R.

%% Channel 16 by default so it's trivially isolable in Ableton.
start() -> start(16, ?STEP_BEATS).

%% Channel (1..16), StepBeats (model step length in beats). Hardcoded defaultOdonus.
start(Channel, StepBeats) ->
    do_start('reef_odonus@ps':defaultOdonus(), Channel, StepBeats).

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
        {right, Sim}  -> do_start_sim(Sim, Channel, StepBeats);
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
    do_start_sim(Sim, Channel, StepBeats).

%% Replace any running voice, then spawn a fresh clock-locked one from a full
%% SimState. The UDP socket is opened INSIDE the spawned loop so it's owned by
%% (and lives as long as) the loop.
do_start_sim(Sim, Channel, StepBeats) ->
    stop(),
    Pid = spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary]),
        erlang:send_after(?POLL_MS, self(), poll),
        loop(#{ socket => Sock, channel => Channel, step_beats => StepBeats,
                sim => Sim, last_step => -1 })
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
%% the socket. (P4c will add an {apply_input, Tick, Input} clause here.)
loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(socket, St));
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
            Next = if Next0 < NowStep -> NowStep; true -> Next0 end,
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
            %% (P4c: apply any inputs tick-tagged for `Step` before stepping.)
            Res = 'reef_engine@ps':stepTick(maps:get(sim, St)),
            Sim1 = maps:get(sim, Res),
            Fired = array:to_list(maps:get(fired, Res)),
            %% Invert the affine map: the wall time at which beat StepBeat occurs.
            WallUs = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
            StepMs = StepBeats * 60000.0 / Tempo,
            Ch = maps:get(channel, St),
            Sock = maps:get(socket, St),
            lists:foreach(fun(F) -> emit(Sock, Ch, F, WallUs, StepMs) end, Fired),
            drain(St#{sim => Sim1, last_step => Step},
                  Step + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo)
    end.

emit(Sock, Ch, F, WallUs, StepMs) ->
    Note  = maps:get(pitch, F),
    Vel   = maps:get(vel, F),
    DurMs = maps:get(dur, F) * StepMs,
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, Ch, Note, Vel, DurMs, WallUs),
    Thunk().
