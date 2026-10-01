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
%%   • → odo voices sound nothing: Odonus follows Vetula through its harmony pattern
%%     (Reef.Vetula.Harmony, set by the frontend as SetHarmony; reef_voice samples it).
%%     The FollowChord pre-send that lived here retired 2026-10-01.
%%
%% The scheduler is a PURE FUNCTION OF THE ABSOLUTE PULSE (the same Link 1/16 index
%% reef_voice / reef_balistes_voice ride), so there is no seed and no accumulating
%% state: push the performance once and both runtimes agree. A second push swaps it in
%% place (live edit).
-module(reef_vetula_voice).
-export([start_perf_json/2, stop/0, loop/1]).

%% Scheduler poll interval (ms).
-define(POLL_MS, 25).
%% Schedule this far ahead so link-spike has lead time (mirrors the other voices).
-define(LOOKAHEAD_MS, 450.0).
%% Model step length in beats. 0.25 = a 1/16 note (Vetula's pulse = the shared grid).
-define(STEP_BEATS, 0.25).
%% Treat the Link source as offline past this age (mirrors tidal_link_anchor).
-define(STALE_ANCHOR_US, 2000000).
%% Re-snap if the next step is more than this many steps ahead (backward Link jump).
-define(SNAP_AHEAD, 8).

%% The MIDI channel for a → midi voice ordinal. Channels now come from the browser's
%% pushed Perf (Reef.Vetula.Perf:midiChannels, in the same order renderMidiAt assigns
%% voiceOrd), so both runtimes honour ONE routing map instead of a rig-local list —
%% Vetula's default is channel 5, named voices climb from there (see
%% Triggerfish.Midi.Routing). Falls back to 5 if the pushed list is somehow empty.
ord_ch(Ord, Chs) ->
    case Chs of
        [] -> 5;
        _  -> lists:nth((Ord rem length(Chs)) + 1, Chs)
    end.

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
                                last_step => -1 })
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
            %% continues on the same Link pulse.
            loop(St#{perf => Perf});
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

%% Walk each pulse within the horizon, emitting every → midi voice's notes at the
%% pulse's wall time.
drain(St, Step, Horizon, AnchorUs, BeatAtAnchor, Tempo) ->
    StepBeats = maps:get(step_beats, St),
    StepBeat = Step * StepBeats,
    case StepBeat =< Horizon of
        false ->
            St;
        true ->
            Perf = maps:get(perf, St),
            %% → odo voices sound nothing here: Odonus follows Vetula through its
            %% harmony pattern (SetHarmony, from the frontend; sampled by reef_voice).
            %% The FollowChord conduct that lived here retired 2026-10-01.
            %% (2) → midi emit. Invert the affine Link map for this pulse's wall time,
            %% then schedule each rendered note (gated) on its rig channel.
            WallUs = round(AnchorUs + (StepBeat - BeatAtAnchor) * 60000000.0 / Tempo),
            StepMs = StepBeats * 60000.0 / Tempo,
            Sock = maps:get(socket, St),
            %% The pushed → midi channels, indexed by voiceOrd (one routing map,
            %% both runtimes) — see ord_ch/2.
            Chs = array:to_list('reef_vetula_perf@ps':midiChannels(Perf)),
            Evs = array:to_list('reef_vetula_perf@ps':renderMidiAt(Perf, Step)),
            lists:foreach(fun(E) -> emit_midi(Sock, E, WallUs, StepMs, Chs) end, Evs),
            drain(St#{last_step => Step}, Step + 1, Horizon,
                  AnchorUs, BeatAtAnchor, Tempo)
    end.

%% One rendered → midi note → scheduled MIDI. `durPulses` is the gate in pulses (1
%% pulse = one 1/16 step), so DurMs = durPulses × the step's ms. Channel comes from the
%% pushed routing map, indexed by the voice's ordinal (ord_ch/2).
emit_midi(Sock, E, WallUs, StepMs, Chs) ->
    Ord   = maps:get(voiceOrd, E),
    Note  = maps:get(note, E),
    Vel   = maps:get(velocity, E),
    DurMs = maps:get(durPulses, E) * StepMs,
    Ch    = ord_ch(Ord, Chs),
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, Ch, Note, Vel, DurMs, WallUs),
    Thunk().
