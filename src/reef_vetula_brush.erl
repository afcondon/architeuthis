%% @doc reef_vetula_brush — plays a Vetula progression as a real Tidal Pattern (the
%% "brush"), LOCKED to the Ableton Link clock. Option B of the palette→brush design:
%% the browser Vetula (palette) pushes its hand-picked voicings; this voice holds the
%% resulting `Pattern PitchedNote12` (built by `Tidal.Vetula.Bridge.buildVoicingsPattern`)
%% and, each Link pulse, queries the pattern's arc and schedules the note-onsets at
%% their TRUE fractional wall-times.
%%
%% Self-contained reef-family voice on Odonus's 1/16 grid — no Calypso, no dispatcher,
%% no bindings. It reads the Link anchor directly (like reef_voice / reef_vetula_voice)
%% and owns its MIDI channel. Because each event is placed at its real cycle position,
%% arps/triplets finer than a 1/16 still land at their true time — the 1/16 pulse is
%% only the poll cadence, not a placement grid.
%%
%% B-1 (this file): MIDI only, one channel, one chord per cycle. Odonus follows the
%% same progression through its harmony pattern, not through this voice. Still to
%% come: multiple voices, and bars-per-chord dwell via mininotation. This
%% is ADDITIVE — reef_vetula_voice (the Perf scheduler + vetula-perf) is untouched and
%% will be retired only once this path is proven on the rig.
-module(reef_vetula_brush).
-export([start_json/3, stop/0, loop/1]).

%% Scheduler poll interval (ms).
-define(POLL_MS, 25).
%% Schedule this far ahead so link-spike has lead time, matching reef_vetula_voice.
-define(LOOKAHEAD_MS, 450.0).
%% Model step length in beats. 0.25 = a 1/16 note (the shared grid). The Bridge query
%% assumes this step when it builds the per-pulse cycle arc (cyclesPerStep = 1/(4·Q)).
-define(STEP_BEATS, 0.25).
%% Treat the Link source as offline past this age (mirrors tidal_link_anchor).
-define(STALE_ANCHOR_US, 2000000).
%% Re-snap if the next step is more than this many steps ahead (backward Link jump).
-define(SNAP_AHEAD, 8).
%% Fixed velocity for B-1 (per-event velocity from the pattern is a later refinement).
-define(VELOCITY, 82).

%% Start (or live-swap) from a channel + renderer + JSON voicings. Builds the Pattern
%% once (Bridge) and holds it; a second push swaps it in place (live re-voice, phase
%% preserved because the voice is a pure function of the absolute pulse).
start_json(Ch, Renderer, Json) ->
    JsonB = ensure_bin(Json),
    Pat = 'tidal_vetula_bridge@ps':buildVoicingsPattern(ensure_bin(Renderer), JsonB),
    Pcs = 'tidal_vetula_bridge@ps':chordPcs(JsonB),
    NChords = array:size(Pcs),
    case whereis(reef_vetula_brush) of
        Pid when is_pid(Pid) ->
            Pid ! {set_pattern, Ch, Pat, Pcs, NChords},
            {ok, Pid};
        _ ->
            NewPid = spawn(fun() ->
                {ok, Sock} = gen_udp:open(0, [binary]),
                erlang:send_after(?POLL_MS, self(), poll),
                loop(#{ socket => Sock, pattern => Pat, channel => Ch,
                        pcs => Pcs, nchords => NChords, last_step => -1 })
            end),
            catch register(reef_vetula_brush, NewPid),
            {ok, NewPid}
    end.

stop() ->
    case whereis(reef_vetula_brush) of
        undefined -> ok;
        Pid ->
            Pid ! stop,
            catch unregister(reef_vetula_brush),
            ok
    end.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L).

%% Clock-locked loop. `poll` drives the walk; `set_pattern` swaps the pattern/channel
%% in place (live edit); `stop` closes the socket.
loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(socket, St));
        {set_pattern, Ch, Pat, Pcs, NChords} ->
            %% Live re-voice: swap the pattern in place.
            loop(St#{pattern => Pat, channel => Ch, pcs => Pcs, nchords => NChords});
        poll ->
            St2 = tick(St),
            erlang:send_after(?POLL_MS, self(), poll),
            loop(St2)
    end.

%% One poll: read the live Link beat, walk every model step from the last up to the
%% lookahead horizon. Idle without a fresh anchor.
tick(St) ->
    NowUs = erlang:system_time(microsecond),
    case tidal_link_anchor:info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, Quantum, LastRecvUs}
                when (NowUs - LastRecvUs) =< ?STALE_ANCHOR_US, Tempo > 0, Quantum > 0 ->
            BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
            NowStep = trunc(BeatNow / ?STEP_BEATS),
            Next0 = maps:get(last_step, St) + 1,
            Next = if (Next0 < NowStep) orelse (Next0 > NowStep + ?SNAP_AHEAD) ->
                          NowStep;
                      true -> Next0
                   end,
            LookaheadBeats = ?LOOKAHEAD_MS / 1000.0 * Tempo / 60.0,
            Horizon = BeatNow + LookaheadBeats,
            drain(St, Next, Horizon, AnchorUs, BeatAtAnchor, Tempo, Quantum);
        _ ->
            St
    end.

%% Walk each pulse within the horizon: query the pattern for that pulse's note-onsets
%% and schedule each at its true fractional wall time.
drain(St, Step, Horizon, AnchorUs, BeatAtAnchor, Tempo, Quantum) ->
    StepBeat = Step * ?STEP_BEATS,
    case StepBeat =< Horizon of
        false ->
            St;
        true ->
            Pat = maps:get(pattern, St),
            Ch = maps:get(channel, St),
            Sock = maps:get(socket, St),
            CycleDurMs = 60000.0 * Quantum / Tempo,
            %% Quantum arrives from the Link anchor as a float (e.g. 4.0), but
            %% queryNotes builds an EXACT rational arc from it (denom = 4·quantum),
            %% which needs an Erlang integer — a float there makes Data.Rational
            %% reduce a non-integer via gcd/rem and crash. Round to the integer
            %% beats-per-cycle it always is.
            QInt = round(Quantum),
            %% Odonus follows Vetula through its harmony pattern (SetHarmony, set by
            %% the frontend and sampled by reef_voice), not through this voice; the
            %% FollowChord conduct that lived here retired 2026-10-01.
            Notes = array:to_list('tidal_vetula_bridge@ps':queryNotes(Pat, Step, QInt)),
            lists:foreach(
              fun(N) -> emit(Sock, Ch, N, AnchorUs, BeatAtAnchor, Tempo, Quantum, CycleDurMs) end,
              Notes),
            drain(St#{last_step => Step}, Step + 1, Horizon,
                  AnchorUs, BeatAtAnchor, Tempo, Quantum)
    end.

%% One WireNote → scheduled MIDI. `startCycle`/`stopCycle` are fractional cycle
%% positions: cycle → beat = cycle × Quantum, so the onset's wall time is the same Link
%% affine map the other voices use, and the gate is (stop − start) cycles in ms.
emit(Sock, Ch, N, AnchorUs, BeatAtAnchor, Tempo, Quantum, CycleDurMs) ->
    Note       = maps:get(note, N),
    StartCycle = maps:get(startCycle, N),
    StopCycle  = maps:get(stopCycle, N),
    EvBeat = StartCycle * Quantum,
    WallUs = round(AnchorUs + (EvBeat - BeatAtAnchor) * 60000000.0 / Tempo),
    DurMs  = (StopCycle - StartCycle) * CycleDurMs,
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
              Sock, <<"IAC Driver Tidal">>, Ch, Note, ?VELOCITY, DurMs, WallUs),
    Thunk().
