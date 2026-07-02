%% @doc reef_vetula_voice — the Vetula "Performance" scheduler on the BEAM, LOCKED to
%% the Ableton Link clock. Runs the shared `reef_vetula_perf@ps` scheduler — a saved
%% chord progression fanned to voices, each reading the same chords on its own per-chord
%% dwell schedule (bars-per-chord, 0 = skip) + phase offset — and does two jobs per
%% pulse:
%%
%%   • → midi voices (V2): render the voice (block / arp — gated notes via the shared
%%     `renderMidiAt`) and schedule the notes on the rig's own Vetula channels. This is
%%     the self-contained MIDI leg — no Odonus, so it validates the scheduler's MIDI
%%     sync against the browser in isolation.
%%   • → odo voices (V1, deferred-but-live): conduct reef_voice's chord overlay by
%%     pre-sending a tick-tagged FollowChord on each chord change. Dormant unless a → odo
%%     voice exists AND reef_voice is running.
%%
%% The scheduler is a PURE FUNCTION OF THE ABSOLUTE PULSE (the same Link 1/16 index
%% reef_voice / reef_balistes_voice ride), so there is no seed and no accumulating
%% state: push the performance once and both runtimes agree. A second push swaps it in
%% place (live edit).
-module(reef_vetula_voice).
-export([start_perf_json/2, stop/0, loop/1]).

%% Scheduler poll interval (ms).
-define(POLL_MS, 25).
%% Schedule this far ahead so link-spike has lead time (mirrors the other voices). Also
%% covers the → odo pre-send margin (FollowChord must reach reef_voice's `pending`
%% before reef_voice — 200ms lookahead — consumes that pulse).
-define(LOOKAHEAD_MS, 450.0).
%% Model step length in beats. 0.25 = a 1/16 note (Vetula's pulse = the shared grid).
-define(STEP_BEATS, 0.25).
%% Treat the Link source as offline past this age (mirrors tidal_link_anchor).
-define(STALE_ANCHOR_US, 2000000).
%% Re-snap if the next step is more than this many steps ahead (backward Link jump).
-define(SNAP_AHEAD, 8).

%% The rig's Vetula MIDI channels, assigned to → midi voices in performance order (the
%% i-th → midi voice sounds on the i-th channel here). Kept OFF the channels the other
%% instruments use — Odonus (1..4, 12..15) and Balistes (10,11) — so the rig's Vetula
%% (8,9,16) A/Bs alongside the browser's (5,6,7) with no collisions. Edit here to
%% re-map; per-instrument channel config is a later cleanup.
rig_channels() -> [8, 9, 16].

rig_ch(Ord) ->
    Chs = rig_channels(),
    lists:nth((Ord rem length(Chs)) + 1, Chs).

%% Start (or live-swap) from a JSON-encoded Perf — the Vetula handoff
%% (Reef.Vetula.Protocol). Snaps to the current clock (a pure function of the pulse, so
%% no phase-hold). A second push swaps the Perf in place. The WS `vetula-perf <json>`.
start_perf_json(Json, StepBeats) ->
    case 'reef_vetula_protocol@ps':decodePerf(ensure_bin(Json)) of
        {right, Perf} ->
            case whereis(reef_vetula_voice) of
                Pid when is_pid(Pid) ->
                    Pid ! {set_perf, Perf},
                    {ok, Pid};
                _ ->
                    NewPid = spawn(fun() ->
                        {ok, Sock} = gen_udp:open(0, [binary]),
                        erlang:send_after(?POLL_MS, self(), poll),
                        loop(#{ socket => Sock, step_beats => StepBeats, perf => Perf,
                                last_step => -1, cursor => -1 })
                    end),
                    catch register(reef_vetula_voice, NewPid),
                    {ok, NewPid}
            end;
        {left, Errs} -> {error, {decode, Errs}}
    end.

stop() ->
    case whereis(reef_vetula_voice) of
        undefined -> ok;
        Pid ->
            Pid ! stop,
            catch unregister(reef_vetula_voice),
            ok
    end.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L).

%% The clock-locked loop. `poll` self-messages drive the walk; `set_perf` swaps the
%% performance in place (live edit); `stop` closes the socket.
loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(socket, St));
        {set_perf, Perf} ->
            %% Live re-push: swap the performance, keep last_step so the read-head
            %% continues on the same Link pulse. Reset cursor to -1 so the next drained
            %% pulse ALWAYS re-conducts the → odo overlay (a swap to a different
            %% progression while the read-head sits on the same cursor INDEX would
            %% otherwise leave the rig on the stale chord until the next boundary).
            loop(St#{perf => Perf, cursor => -1});
        poll ->
            St2 = tick(St),
            erlang:send_after(?POLL_MS, self(), poll),
            loop(St2)
    end.

%% One poll: read the live Link beat, walk every model step from the last up to the
%% lookahead horizon. Idle without a fresh anchor (nothing to play/conduct against).
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

%% Walk each pulse within the horizon: (1) conduct any → odo voice (FollowChord on a
%% chord change) and (2) emit every → midi voice's notes at the pulse's wall time.
drain(St, Step, Horizon, AnchorUs, BeatAtAnchor, Tempo) ->
    StepBeats = maps:get(step_beats, St),
    StepBeat = Step * StepBeats,
    case StepBeat =< Horizon of
        false ->
            St;
        true ->
            Perf = maps:get(perf, St),
            %% (1) → odo conducting. odoCursorAt holds the previous cursor across rests;
            %% a change means the → odo voice moved to a new chord, so pre-send
            %% reef_voice a tick-tagged FollowChord (it applies it on the tagged pulse).
            Prev = maps:get(cursor, St),
            Cur = 'reef_vetula_perf@ps':odoCursorAt(Perf, Step, Prev),
            case (Cur =/= Prev) andalso is_pid(whereis(reef_voice)) of
                true ->
                    Pcs = 'reef_vetula_perf@ps':odoPcsAt(Perf, Cur),
                    Input = 'reef_input@ps':mkFollowChord(Pcs),
                    reef_voice ! {apply_input, Step, Input};
                false -> ok
            end,
            %% (2) → midi emit. Invert the affine Link map for this pulse's wall time,
            %% then schedule each rendered note (gated) on its rig channel.
            WallUs = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
            StepMs = StepBeats * 60000.0 / Tempo,
            Sock = maps:get(socket, St),
            Evs = array:to_list('reef_vetula_perf@ps':renderMidiAt(Perf, Step)),
            lists:foreach(fun(E) -> emit_midi(Sock, E, WallUs, StepMs) end, Evs),
            drain(St#{cursor => Cur, last_step => Step}, Step + 1, Horizon,
                  AnchorUs, BeatAtAnchor, Tempo)
    end.

%% One rendered → midi note → scheduled MIDI. `durPulses` is the gate in pulses (1
%% pulse = one 1/16 step), so DurMs = durPulses × the step's ms. Channel comes from the
%% voice's ordinal via the rig channel list.
emit_midi(Sock, E, WallUs, StepMs) ->
    Ord   = maps:get(voiceOrd, E),
    Note  = maps:get(note, E),
    Vel   = maps:get(velocity, E),
    DurMs = maps:get(durPulses, E) * StepMs,
    Ch    = rig_ch(Ord),
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, Ch, Note, Vel, DurMs, WallUs),
    Thunk().
