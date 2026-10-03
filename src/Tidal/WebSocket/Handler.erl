-define(BUILD_TEST, <<"BUILD_MARKER_1767904118">>).
-module(tidal_webSocket_handler@foreign).
-export([binaryToString/1]).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

%% Sets directory relative to working directory
-define(SETUP_DIR, "setup").

%% Convert binary to string (UTF-8)
binaryToString(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(Bin, utf8);
binaryToString(Other) ->
    %% Already a string or other type
    Other.

%% Cowboy callbacks - delegate to PureScript
init(Req, _Config) ->
    %% After PR1.7d the WS handler no longer holds a scheduler pid;
    %% all dispatch goes through registered names (tidal_dispatcher,
    %% tidal_voice_sup, tidal_clock). State just tracks connection
    %% liveness for hypothetical disconnect cleanup.
    State = #{connected => true},
    io:format("WebSocket: New connection~n"),
    %% Default cowboy idle_timeout is 60_000ms — too aggressive for a
    %% live-coding session (the user routinely sits looking at the
    %% modular for >1 minute between commands). Bump to 30 minutes.
    Opts = #{idle_timeout => 1800000},
    {cowboy_websocket, Req, State, Opts}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Text}, State) ->
    tidal_log:debug("WebSocket: Received message: ~s~n", [Text]),
    handle_pattern_message(Text, State);
websocket_handle({binary, Bin}, State) ->
    %% Treat binary as text
    websocket_handle({text, Bin}, State);
websocket_handle(_Frame, State) ->
    {ok, State}.

%% Try to parse one of the built-in verb prefixes.
%% Returns one of:
%%   {fh2_envelope, Voice, Output, Channel}    — register an FH-2 envelope voice
%%   {fh2_trigger, Voice, Pattern}             — pattern fires MIDI notes to FH-2 voice
%%   {fh2_shape, Voice, A, D, S, R}            — live ADSR via CCs 70/71/72/73
%%   {bind, Name, ActionSpec}                  — register a named binding
%%   {unbind, Name}                            — remove a named binding
%%   {hush}                                    — silence everything (Tidal-compat)
%%   {silence_one, Name}                       — clear one voice's pattern
%%   none                                      — try named-binding dispatch
%% `tidal <block>`: a block of Tidal as typed in Limulus (d1 $ ..., hush,
%% setcps), read by Tidal.Line. Its `hush` is Tidal's (the d1..d16 streams);
%% the bare `hush` below stays the whole rig's.
try_parse_prefixed(<<"tidal ", Rest/binary>>) -> {tidal_line, Rest};
%% odonus <move> — a move on the running Odonus (Reef.Move): several gestures
%% landing on one step, e.g. `odonus $ unison # phase 2`. Also reached as
%% `tidal odonus $ ...`, which is how Limulus sends a block.
try_parse_prefixed(<<"odonus ", _/binary>> = Line) -> {tidal_line, Line};
try_parse_prefixed(<<"drums ", _/binary>> = Line) -> {tidal_line, Line};
try_parse_prefixed(<<"hush">>) -> {hush};
try_parse_prefixed(<<"hush ", _/binary>>) -> {hush};
try_parse_prefixed(<<"silence">>) -> {hush};
try_parse_prefixed(<<"silence ", Rest/binary>>) ->
    case trim_binary(Rest) of
        <<>> -> {hush};
        Name -> {silence_one, Name}
    end;
try_parse_prefixed(<<"reef-odonus ", Rest/binary>>) ->
    %% reef-odonus <json> — a complete Odonus record in the Reef.Protocol wire
    %% format, to run on the BEAM via the shared reef engine. simple-json emits
    %% compact JSON (no spaces), so the payload runs to end of line.
    {reef_odonus, trim_binary(Rest)};
try_parse_prefixed(<<"reef-sim-at ", Rest/binary>>) ->
    %% reef-sim-at <step> <beats> <json> — the phase-aligned lockstep HANDOFF (P5).
    %% Same SimState payload as reef-sim, but stamped with the absolute model STEP
    %% the snapshot is the state for (the frontend's nextModelStep) AND the model-step
    %% LENGTH in beats (0.25 × stepDiv). The voice installs both and holds the state
    %% until that step, so both runtimes play it on the same absolute step in the same
    %% grid — no handoff flam, no follow-up reef-steplen. JSON is space-free
    %% (simple-json compact), so two splits separate step, beats, and payload.
    case binary:split(trim_binary(Rest), <<" ">>) of
        [StepBin, Rest2] when StepBin =/= <<>> ->
            case binary:split(Rest2, <<" ">>) of
                [BeatsBin, Json] when BeatsBin =/= <<>>, Json =/= <<>> ->
                    case {parse_number(StepBin), parse_number(BeatsBin)} of
                        {{ok, N}, {ok, Beats}} -> {reef_sim_at, trunc(N), Beats, Json};
                        _ -> none
                    end;
                _ -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"balistes-sim-at ", Rest/binary>>) ->
    %% balistes-sim-at <step> <beats> <json> — the Balistes phase-aligned lockstep
    %% HANDOFF: a whole BalSim (Reef.Balistes.Protocol) stamped with the absolute
    %% model step it's the state for and the model-step length in beats. Mirrors
    %% reef-sim-at; the voice holds the pushed state until step N so the browser
    %% and the rig play it on the same absolute step. Two splits
    %% separate step, beats, and the space-free JSON payload.
    case binary:split(trim_binary(Rest), <<" ">>) of
        [StepBin, Rest2] when StepBin =/= <<>> ->
            case binary:split(Rest2, <<" ">>) of
                [BeatsBin, Json] when BeatsBin =/= <<>>, Json =/= <<>> ->
                    case {parse_number(StepBin), parse_number(BeatsBin)} of
                        {{ok, N}, {ok, Beats}} -> {balistes_sim_at, trunc(N), Beats, Json};
                        _ -> none
                    end;
                _ -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"reef-sim ", Rest/binary>>) ->
    %% reef-sim <json> — the lockstep HANDOFF (P4d): a whole SimState (Odonus +
    %% gen config + Marbles pad + seed) in the Reef.Protocol wire format, so the
    %% BEAM voice co-simulates from the frontend's exact state, generation and all.
    %% Superseded by reef-sim-at (phase-aligned); kept for manual / legacy use.
    {reef_sim, trim_binary(Rest)};
try_parse_prefixed(<<"balistes-fixed ", Rest/binary>>) ->
    %% balistes-fixed <json> — the fixed-rhythm handoff: a whole FixedPattern
    %% (Reef.Balistes.Fixed, wire-flat) to play on the rig. Stateless (a pure
    %% function of the absolute step), so no step tag / phase-hold needed.
    {balistes_fixed, trim_binary(Rest)};
try_parse_prefixed(<<"dirt-play ", Rest/binary>>) ->
    %% dirt-play <json> — audition one sample now: {"s", "n", "begin", "end",
    %% "speed", "gain", "orbit"}, the fields of a Reef.Routing voice. For the
    %% routing table's sample destination, so a voice can be heard as it is
    %% chosen rather than only when a pattern reaches it.
    {dirt_play, trim_binary(Rest)};
try_parse_prefixed(<<"balistes-routing ", Rest/binary>>) ->
    %% balistes-routing <json> — the drum routing table (Reef.Routing's
    %% DrumRouting): per canonKit lane, the legs a hit is sent down. Kept for
    %% every later start of the voice, whichever engine.
    {balistes_routing, trim_binary(Rest)};
try_parse_prefixed(<<"odonus-routing ", Rest/binary>>) ->
    %% odonus-routing <json> — the heads' routing (Reef.Routing.VoiceRouting):
    %% each head's live legs, from the routing table. Kept across restarts.
    {odonus_routing, trim_binary(Rest)};
try_parse_prefixed(<<"balistes-input ", Rest/binary>>) ->
    %% balistes-input <json> — a tick-tagged Balistes gesture (live knob sync):
    %% {tick, input} in the Reef.Balistes.Protocol wire form, applied on the tagged
    %% model step so browser and rig evolve identically through the edit.
    {balistes_input, trim_binary(Rest)};
try_parse_prefixed(<<"vetula-perf ", Rest/binary>>) ->
    %% vetula-perf <json> — the Vetula "Performance" handoff: a whole Perf (a saved
    %% chord progression + voices, Reef.Vetula.Protocol wire form) to run on the rig.
    %% The scheduler is a pure function of the absolute pulse, so no step tag /
    %% phase-hold is needed; the → odo voice conducts reef_voice's chord overlay. A
    %% second push swaps the performance in place (live edit). Start Odonus first.
    {vetula_perf, trim_binary(Rest)};
try_parse_prefixed(<<"vetula-voicings ", Rest/binary>>) ->
    %% vetula-voicings <channel> <renderer> <json> — the palette→brush handoff
    %% (Option B). Plays a Vetula progression's HAND-PICKED voicings (JSON `Array
    %% (Array Int)`, each inner array one voiced chord's ascending MIDI) as a real
    %% Tidal Pattern via reef_vetula_brush — a self-contained reef-family voice on
    %% Odonus's Link 1/16 grid (no Calypso, no dispatcher). channel = 1..16 MIDI
    %% channel the frontend is claiming; renderer ∈ {block, arp, held}. One chord
    %% per cycle for now; dwell/skip → mininotation weighting later. A re-push live
    %% re-voices in place.
    case binary:split(trim_binary(Rest), <<" ">>) of
        [ChBin, Rest2] when ChBin =/= <<>> ->
            case binary:split(trim_binary(Rest2), <<" ">>) of
                [Renderer, Json] when Renderer =/= <<>>, Json =/= <<>> ->
                    try binary_to_integer(ChBin) of
                        Ch -> {vetula_voicings, Ch, Renderer, trim_binary(Json)}
                    catch _:_ -> none end;
                _ -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"conspicillum-scene ", Rest/binary>>) ->
    %% conspicillum-scene <json> — the Conspicillum handoff: a whole resolved
    %% Scene (corpus + query + cloud spec + seed, Reef.Conspicillum.Protocol wire
    %% form). reef_conspicillum_voice computes ONE CYCLE AT A TIME — a cloud is
    %% cycle-addressed rather than a precomputed loop, so any cycle is a pure
    %% function of the scene and its number — and emits one timetagged
    %% /dirt/play bundle per grain to SuperDirt (:57120). A second push swaps
    %% the scene in place and lands on the next cycle boundary.
    %%
    %% The JSON is either the Scene itself (the original form) or, for the
    %% stage, the envelope {"scene": <Scene>, "base", "edited", "page", "by"}:
    %% the voice plays `scene` and tidal_stage records the rest.
    {conspicillum_scene, trim_binary(Rest)};
try_parse_prefixed(<<"conspicillum-stop">>) -> {conspicillum_stop};
try_parse_prefixed(<<"conspicillum-stop ", _/binary>>) -> {conspicillum_stop};
try_parse_prefixed(<<"reef-input ", Rest/binary>>) ->
    %% reef-input <json> — a tick-tagged input (lockstep P4c): {tick, input} in the
    %% Reef.Protocol wire format. Forwarded to the running reef voice, which buffers
    %% it and applies it on the tagged model step so a live edit stays in lockstep.
    {reef_input, trim_binary(Rest)};
try_parse_prefixed(<<"reef-steplen ", Rest/binary>>) ->
    %% reef-steplen <beats> — the frontend's current model-step length in beats
    %% (STEP LENGTH × 1/16). Forwarded to the running reef voice so its grid tracks
    %% the frontend's; without it the BEAM stays at 1/16 and the two desync.
    case parse_number(trim_binary(Rest)) of
        {ok, Beats} when Beats > 0 -> {reef_steplen, Beats};
        _ -> none
    end;
try_parse_prefixed(<<"reef-swing ", Rest/binary>>) ->
    %% reef-swing <fraction> — the frontend's swing amount (0..0.6), the fraction of a
    %% step the odd model steps lag. Forwarded to the running reef voice so it renders
    %% the same groove. Timing expression, not model state (never a tick-tagged input).
    case parse_number(trim_binary(Rest)) of
        {ok, S} -> {reef_swing, S};
        _ -> none
    end;
try_parse_prefixed(<<"log-level ", Rest/binary>>) ->
    try
        N = binary_to_integer(string:trim(Rest, both, "\r \t")),
        case N >= 0 andalso N =< 2 of
            true -> {log_level, N};
            false -> none
        end
    catch error:badarg -> none
    end;
try_parse_prefixed(<<"midi-device ", Rest/binary>>) ->
    %% midi-device <alias> <device-name-with-spaces> [lat <ms>]
    %% The optional `lat <ms>` suffix is stripped first if present;
    %% remainder is the device name. Surrounding `"..."` quotes are
    %% stripped — without this, the shell-quoted format string later
    %% wraps the value in another pair of quotes, producing
    %% `dev ""AUDIO4c USB2""` which the shell tokenises as two unquoted
    %% words and sendmidi falls back to substring matching.
    case binary:split(Rest, <<" ">>) of
        [Alias, AfterAlias] when AfterAlias =/= <<>> ->
            {RawName, Latency} = split_lat_suffix(AfterAlias),
            DeviceName = strip_surrounding_quotes(RawName),
            {midi_device, Alias, DeviceName, Latency};
        _ -> none
    end;
try_parse_prefixed(<<"fh2-envelope ", Rest/binary>>) ->
    %% fh2-envelope <voice> <output> <channel>
    case binary:split(Rest, <<" ">>, [global]) of
        [VoiceBin, OutputBin, ChannelBin] ->
            try
                Voice = binary_to_integer(VoiceBin),
                Output = binary_to_integer(OutputBin),
                Channel = binary_to_integer(ChannelBin),
                {fh2_envelope, Voice, Output, Channel}
            catch
                error:badarg -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"fh2-gate ", Rest/binary>>) ->
    %% fh2-gate <voice> <output> <channel>
    %%   1-8     → FH-2 main jacks
    %%   9-64    → FHX-8CV expanders
    %%   65-128  → FHX-8GT expanders (separate routing — uses basegate field)
    case binary:split(Rest, <<" ">>, [global]) of
        [VoiceBin, OutputBin, ChannelBin] ->
            try
                Voice = binary_to_integer(VoiceBin),
                Output = binary_to_integer(OutputBin),
                Channel = binary_to_integer(ChannelBin),
                {fh2_gate, Voice, Output, Channel}
            catch
                error:badarg -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"fh2-trigger ", Rest/binary>>) ->
    try_parse_num_pattern(fh2_trigger, Rest);
try_parse_prefixed(<<"fh2-shape ", Rest/binary>>) ->
    %% fh2-shape <voice> <attack> <decay> <sustain> <release>
    case binary:split(Rest, <<" ">>, [global]) of
        [VoiceBin, ABin, DBin, SBin, RBin] ->
            try
                Voice = binary_to_integer(VoiceBin),
                A = binary_to_integer(ABin),
                D = binary_to_integer(DBin),
                S = binary_to_integer(SBin),
                R = binary_to_integer(RBin),
                {fh2_shape, Voice, A, D, S, R}
            catch
                error:badarg -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"bind ", Rest/binary>>) ->
    %% bind <name> <action-spec>; action-spec runs to end of line.
    case binary:split(Rest, <<" ">>) of
        [Name, ActionSpec] -> {bind, Name, ActionSpec};
        _ -> none
    end;
try_parse_prefixed(<<"unbind ", Rest/binary>>) ->
    %% unbind <name>
    Name = binary_part(Rest, 0, byte_size(Rest)),
    case binary:match(Name, <<" ">>) of
        nomatch -> {unbind, Name};
        _ -> none
    end;
try_parse_prefixed(<<"load ", Rest/binary>>) ->
    %% load <name>  — read setup/<name>.tidal and evaluate each line
    Name = binary_part(Rest, 0, byte_size(Rest)),
    case binary:match(Name, <<" ">>) of
        nomatch -> {load, Name};
        _ -> none
    end;
try_parse_prefixed(<<"state">>) ->
    %% state — read latest StateBus snapshot (ETS-backed) and reply.
    %% No args; trailing chars after `state` aren't accepted to keep
    %% the verb unambiguous.
    {state};
try_parse_prefixed(<<"bpm ", Rest/binary>>) ->
    %% Shortcut for `config bpm <n>` — bpm is the most-likely-to-change
    %% config dimension and warrants a one-word verb.  Same SetBpm
    %% scheduler path: sends /link/set-tempo to link-spike AND updates
    %% the local free-run fallback.
    case parse_number(trim_binary(Rest)) of
        {ok, N} -> {set_bpm, N};
        error -> none
    end;
try_parse_prefixed(<<"config bpm ", Rest/binary>>) ->
    case parse_number(trim_binary(Rest)) of
        {ok, N} -> {set_bpm, N};
        error -> none
    end;
try_parse_prefixed(<<"set-control ", Rest/binary>>) ->
    %% set-control <name> <value> — write a single named scalar to
    %% the live control bus (tidal_control_bus).  Cells reading
    %% via `Tidal.LiveControl.live "<name>"` see the new value
    %% from the next scheduler tick onward.  Used by Calypso UI
    %% knobs and (future) Midifighter Twister CCs.
    case binary:split(trim_binary(Rest), <<" ">>) of
        [NameBin, ValueBin] when NameBin =/= <<>>, ValueBin =/= <<>> ->
            case parse_number(trim_binary(ValueBin)) of
                {ok, V} -> {set_control, NameBin, V};
                error -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"set-scale ", Rest/binary>>) ->
    %% set-scale <name> — write the active scale to tidal_scale_bus.
    %% On the next tick, every voice's Window.activeScale carries the
    %% new value, and Degree pitches re-render against it — without
    %% recompile, without per-cue editing, without re-arm.  Names are
    %% kebab-case (`c-mixolydian`, `a-harmonic-minor`); see
    %% `Tidal.Substrate.Scales.namedScales` for the registry.
    case trim_binary(Rest) of
        <<>> -> none;
        Name -> {set_scale, Name}
    end;
try_parse_prefixed(<<"clear-scale">>) ->
    %% clear-scale — drop the active scale.  Degree patterns go silent
    %% until a new set-scale arrives.  Useful for "all chromatic"
    %% sections that should ignore key state.
    {clear_scale};
try_parse_prefixed(<<"clear-controls">>) ->
    %% clear-controls — empty the live-control bus, sending every
    %% knob's reading back to its declared default on the next tick.
    %% Heavy-reset use case from the L-mid Globals dashboard: improv
    %% on the Twister has wandered into chaos, this snaps everything
    %% home without re-loading the session.
    {clear_controls};
try_parse_prefixed(<<"clear-controls ", _/binary>>) ->
    {clear_controls};
try_parse_prefixed(<<"phase-resync">>) ->
    %% phase-resync — every Odonus voice's playheads back to cursor 0
    %% + accumulator 0 + pend_step +1.  Re-aligns all running playheads
    %% on the next master tick.  Bar-line emergency button: if cursors
    %% have drifted (manual poking, mute-then-unmute reveals offset,
    %% etc.) this snaps everyone home together.
    {phase_resync};
try_parse_prefixed(<<"phase-resync ", _/binary>>) ->
    {phase_resync};
try_parse_prefixed(<<"unhush">>) ->
    %% unhush — resume MIDI emission on every Odonus voice after a
    %% previous `hush`.  Complements the L-mid Globals panic button:
    %% hush silences, unhush brings everything back.  Engine state
    %% kept advancing in lockstep with the master clock during the
    %% hush, so playheads pick up at the position they would have
    %% been at had nothing happened.
    {unhush};
try_parse_prefixed(<<"unhush ", _/binary>>) ->
    {unhush};
try_parse_prefixed(<<"shred-mod ", Rest/binary>>) ->
    %% shred-mod <N> — Mimetic-Digitalis-style reroll of Odonus's modN
    %% (1..4) per-cell array.  Reads `odonus.shredRateN` from the control
    %% bus (0..1, default 1.0 = full reroll); for each cell index 0..15
    %% rolls a uniform random < rate; on success writes a fresh random
    %% 0..127 to `odonus.modN.<idx>` via tidal_control_bus:set.  Voices
    %% pick up the new values on the next compute tick.
    case parse_int(trim_binary(Rest)) of
        {ok, N} when N >= 1, N =< 4 -> {shred_mod, N};
        _ -> none
    end;
try_parse_prefixed(<<"set-nav-mode ", Rest/binary>>) ->
    %% set-nav-mode <cartesian|forward|reverse> — live-mutate the
    %% traversal mode on every Odonus voice.  Reuses the existing
    %% `{set_config, #{nav_mode => Atom}}` cast path, so the engine's
    %% validating setter (odonus_engine:set_field) accepts or rejects
    %% the atom.  Wired to L-mid Globals knob 4 (Row 1 col 0) as a
    %% 3-position stepped knob.
    case trim_binary(Rest) of
        <<"cartesian">> -> {set_nav_mode, cartesian};
        <<"forward">>   -> {set_nav_mode, forward};
        <<"reverse">>   -> {set_nav_mode, reverse};
        _               -> none
    end;
try_parse_prefixed(<<"reload-baseline">>) ->
    %% reload-baseline — code:load_file the typeful-cues baseline module
    %% (Calypso.Generated.Session). Used by Calypso's /session-source
    %% endpoint after writing + building a new typeful session. Voice
    %% gen_servers keep their currently-captured Pattern funs; calls
    %% inside those funs late-bind to the freshly-loaded Session, so
    %% currently-playing cues may pick up new bodies automatically. Re-
    %% arming guarantees a clean swap.
    {reload_baseline};
try_parse_prefixed(<<"reload-baseline ", _/binary>>) ->
    {reload_baseline};
try_parse_prefixed(<<"get-studio">>) ->
    %% get-studio — return a snapshot of the current Studio state
    %% (devices, instruments, drum kits, claim conflicts) as a
    %% tab-delimited multi-line payload.  Calypso's Studio pane
    %% consumes this after each successful reload-baseline.  See
    %% `tidal_session_walker:studio_lines/0` for the wire format.
    {get_studio};
try_parse_prefixed(<<"get-studio ", _/binary>>) ->
    {get_studio};
try_parse_prefixed(<<"dump-odonus-samples ", Rest/binary>>) ->
    %% dump-odonus-samples <voice-name> — return per-step timing
    %% samples collected by an instrumented odonus_voice gen_server.
    %% Used for the timing-jitter diagnostic
    %% ([[project_timing_jitter_investigation_queued]]).  Reply is
    %% CSV: one line per step with NowUs,TRecv,TEvalDone,TRefreshDone,
    %% TEmitDone,WallUs.
    case trim_binary(Rest) of
        <<>> -> none;
        Name -> {dump_odonus_samples, Name}
    end;
try_parse_prefixed(<<"clear-odonus-samples ", Rest/binary>>) ->
    %% clear-odonus-samples <voice-name> — wipe the timing-sample
    %% buffer so the next capture starts fresh.
    case trim_binary(Rest) of
        <<>> -> none;
        Name -> {clear_odonus_samples, Name}
    end;
try_parse_prefixed(<<"dump-anchor-log">>) ->
    %% dump-anchor-log — return the diagnostic event ring buffer
    %% (anchor receipts, clock transitions, voice dropouts) as CSV
    %% so we can forensic-trace clock weirdness next time it happens.
    {dump_anchor_log};
try_parse_prefixed(<<"clear-anchor-log">>) ->
    {clear_anchor_log};
try_parse_prefixed(<<"play-piece ", Rest/binary>>) ->
    %% play-piece <name> — install the named Section value (a top-level
    %% `Pattern AnyPart` declaration in Calypso.Generated.Session) into
    %% the conductor.  On each subsequent clock tick the conductor
    %% queries the section over the look-ahead window and fires arms
    %% for events that land in that window — same dispatch path as
    %% `play-armed`, but driven by the section's own time structure.
    case trim_binary(Rest) of
        <<>> -> none;
        Name -> {play_piece, Name}
    end;
try_parse_prefixed(<<"stop-piece">>) ->
    %% stop-piece — clear the conductor's current piece.  Voices keep
    %% their last-armed pattern (deliberate: stop halts arrangement,
    %% not the music).  Idempotent.
    {stop_piece};
try_parse_prefixed(<<"stop-piece ", _/binary>>) ->
    {stop_piece};
%% Per-voice stops for the reef family (Triggerfish ATLANTIS per-tab transport):
%% stop ONE reef voice, not the global hush.  Restart is the voice's own handoff
%% verb (reef-sim-at / balistes-sim-at / vetula-voicings).  Idempotent — stopping
%% an absent voice is a no-op (the :stop() call is wrapped in `catch`).
try_parse_prefixed(<<"reef-stop">>) -> {reef_stop};
try_parse_prefixed(<<"reef-stop ", _/binary>>) -> {reef_stop};
try_parse_prefixed(<<"balistes-stop">>) -> {balistes_stop};
try_parse_prefixed(<<"balistes-stop ", _/binary>>) -> {balistes_stop};
%% vetula-cards-play / vetula-cards-stop — Vetula's cards played by the rig
%% (vetula_cards, from the cards on the stage): the page sends play on entering
%% Rig and stop on leaving it.
try_parse_prefixed(<<"vetula-cards-play">>) -> {vetula_cards_play};
try_parse_prefixed(<<"vetula-cards-stop">>) -> {vetula_cards_stop};
try_parse_prefixed(<<"vetula-stop">>) -> {vetula_stop};
try_parse_prefixed(<<"vetula-stop ", _/binary>>) -> {vetula_stop};
try_parse_prefixed(<<"play-armed ", Rest/binary>>) ->
    %% play-armed <mvoiceName> <cueName> — install a typeful cue's body
    %% into the named voice.  Resolves the cue by calling
    %% calypso_generated_session@ps:<cueName>/0 and extracting the `body`
    %% field from the newtype-elided Cue record.  The mvoice name must
    %% already have a binding registered (via the Session walker after
    %% reload-baseline, or `bind <name> <spec>` directly).
    %%
    %% Pre-2026-05-16 form was `play-armed <mvoice> <bridgeModule>` —
    %% see git tag `interpreted-dsl-final-2026-05-16` for the bridge-
    %% module-per-arm pipeline that this verb replaced.
    case binary:split(trim_binary(Rest), <<" ">>) of
        [MvoiceName, CueName] when MvoiceName =/= <<>>, CueName =/= <<>> ->
            {play_armed, MvoiceName, CueName};
        _ -> none
    end;
%% --- Calypso composition-grammar verbs (routing-only) ---------------
%% See calypso/docs/composition-grammar.md for the spec.  Each verb
%% lowers into one of the existing tuple shapes (midi_device,
%% fh2_gate, fh2_envelope, bind) so the existing dispatch arms keep
%% working; device-only verbs (es9 / es5 / etc.) emit an
%% {alias_recorded, ...} tuple handled by a dedicated arm below.
%% A side-effect on tidal_alias_types (ETS) records the alias's type
%% so subsequent gate/cv bindings can route by alias-type.

try_parse_prefixed(<<"midi ", Rest/binary>>) ->
    parse_root_device_verb(midi, Rest);
try_parse_prefixed(<<"fh2 ", Rest/binary>>) ->
    parse_root_device_verb(fh2, Rest);
try_parse_prefixed(<<"release-claim ", Rest/binary>>) ->
    %% Release an owner's claims on the fh2-config daemon. Frees the
    %% gate/pitch slots so the same outputs can be re-claimed by a
    %% different macro cell without bouncing the daemon.
    %%
    %%   release-claim <kind> <name>
    %%
    %% kind is polysignal / tvoice / drumkit / yarns / chord. The
    %% daemon validates and returns OK or ERR. Optional cleanup of
    %% the dispatcher binding registry is deferred — stale bindings
    %% just fail to fire (their hardware is no longer configured).
    case binary:split(Rest, <<" ">>) of
        [Kind, Name] ->
            {release_claim, trim_binary(Kind), trim_binary(Name)};
        _ ->
            {routing_error, <<"release-claim">>,
             <<"expected `release-claim <kind> <name>` — "
               "e.g. `release-claim chord pad1`">>}
    end;
try_parse_prefixed(<<"yarns ", Rest/binary>>) ->
    %% Two distinct uses of `yarns `:
    %%
    %%   yarns synth1 [4] mode poly …    — macro polyvoice cell
    %%   yarns yarns "Yarns"             — device-alias registration
    %%
    %% Disambiguator: the macro form has `[N]` as its second token
    %% (after the voice name); the device-alias form doesn't.
    case looks_like_yarns_macro(Rest) of
        true  -> parse_yarns_cell(Rest);
        false -> parse_root_device_verb(yarns, Rest)
    end;
try_parse_prefixed(<<"es9 ", Rest/binary>>) ->
    parse_es9_verb(Rest);
try_parse_prefixed(<<"es5 ", Rest/binary>>) ->
    parse_expander_verb(es5, <<"es5">>, Rest);
try_parse_prefixed(<<"esx-8gt ", Rest/binary>>) ->
    parse_expander_verb(esx_8gt, <<"esx-8gt">>, Rest);
try_parse_prefixed(<<"esx-8cv ", Rest/binary>>) ->
    parse_expander_verb(esx_8cv, <<"esx-8cv">>, Rest);
try_parse_prefixed(<<"fhx-8gt ", Rest/binary>>) ->
    parse_expander_verb(fhx_8gt, <<"fhx-8gt">>, Rest);
try_parse_prefixed(<<"osc ", Rest/binary>>) ->
    parse_osc_verb(Rest);
try_parse_prefixed(<<"fh2-config ", Rest/binary>>) ->
    parse_fh2_config_verb(Rest);
try_parse_prefixed(<<"selene ", Rest/binary>>) ->
    %% Calypso ships polysignal cell blocks as a single line of the
    %% form `polysignal <json>`, where the JSON envelope is exactly
    %% what fh2-config's `--apply-polysignal` reads on stdin.
    {selene, Rest};
try_parse_prefixed(<<"selene-apply ", Rest/binary>>) ->
    %% Triggerfish's Selene rack (#142) pushes each CV/gate destination
    %% as `selene-apply <socket> <bank> <json>`: socket ∈ es9 | fh2 picks
    %% the daemon control.sock, bank is the target token (main/cv0/gt0/…),
    %% and json is the apply-polysignal envelope. socket+bank echo back in
    %% the reply so the browser can correlate the OK/ERR per destination.
    %% JSON is compact (space-free simple-json), so two splits separate
    %% socket, bank, and payload.
    case binary:split(trim_binary(Rest), <<" ">>) of
        [Socket, Rest2] when Socket =/= <<>> ->
            case binary:split(Rest2, <<" ">>) of
                [Bank, Json] when Bank =/= <<>>, Json =/= <<>> ->
                    {selene_apply, Socket, Bank, Json};
                _ -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"balistes ", Rest/binary>>) ->
    %% Calypso ships a balistes cell as a single line `balistes <json>`
    %% where the JSON envelope has alias / deviceName / channel +
    %% the seven scalar parameter values.  Same direct-wire pattern
    %% polysignal uses, but the target is balistes_voice_sup rather
    %% than fh2-daemon.
    {balistes, Rest};
try_parse_prefixed(<<"kit ", Rest/binary>>) ->
    %% Kit dispatch cell. One form:
    %%
    %%   kit <name> "<pattern>"   -- literal mini-notation
    %%
    %% Installs a voice `kit-<name>` whose binding is [KitDispatch].
    %% On each event the dispatcher looks up the event token in the
    %% binding registry and walks that binding's PrimActions. Pairs
    %% with the `drumkit` verb's per-voice bindings (bd / sn / hh / cp
    %% / …) so one cell carries the rhythmic figure for the whole kit:
    %%
    %%   kit kitA "bd sn bd cp"
    %%
    %% Per-voice cells still work alongside (`bd "x*16"` for a fill).
    %% Host-language combinators on the pattern (rev / every / etc.)
    %% live in cue cells now — wrap the body in a `cue` and dispatch
    %% via `play-armed kit-<name> <module>` instead of inlining `:expr`.
    case binary:split(Rest, <<" ">>) of
        [Name, Body0] ->
            Body = trim_binary(Body0),
            {kit, trim_binary(Name), strip_quotes(Body)};
        _ ->
            none
    end;
try_parse_prefixed(<<"chord ", Rest/binary>>) ->
    %% Chord cell: broadcast each event token as a chord root across
    %% N FH-2 voices with intervals from the named chord shape.
    %%
    %%   chord pad1 [4]
    %%     shape minor7
    %%     gates gt0
    %%     pitch main
    %%     ch 12
    %%
    %% Pattern firing: `pad1 "c4 g3 a3"` plays C-minor7, G-minor7,
    %% A-minor7 in turn — each root broadcasts to all 4 voice
    %% channels (12..15) with intervals [0,3,7,10] applied.
    %%
    %% Hardware claim path is shared with drumkit: synthesized voice
    %% names `<chordName>-1`..`<chordName>-N` go to fh2-config via
    %% the existing apply-drumkit envelope. Chord-specific behaviour
    %% (broadcast-with-intervals) is purely BEAM-side, installed as
    %% a single ChordDispatch binding under the chord's name.
    parse_chord_cell(Rest);
try_parse_prefixed(<<"drumkit ", Rest/binary>>) ->
    %% Drum-kit cell. The user-facing grammar is:
    %%
    %%   drumkit <name>
    %%     gates <bank> <lo>-<hi>
    %%     pitch <bank> <lo>-<hi>
    %%     ch <baseChannel>
    %%     <>
    %%     <voice>: <offset>
    %%     ...
    %%
    %% Calypso bundles the multi-line block (split on `<>`) into one
    %% WS frame, so by the time we see it, all of the header tokens
    %% and the voice list are space-separated on one logical line.
    %%
    %% We parse the cell text into the JSON envelope that the
    %% fh2-config daemon expects on its `apply-drumkit <json>` line
    %% (which matches FH2.DrumKit.parseDrumKitJson on the daemon
    %% side). Parsing in Erlang here avoids adding a JSON-parsing
    %% dependency and keeps Calypso free of FH-2-specific
    %% transformation rules.
    parse_drumkit_cell(Rest);
try_parse_prefixed(<<"midi-note ", Rest/binary>>) ->
    parse_binding_midi_note_verb(Rest);
try_parse_prefixed(<<"midi-cc-cont ", Rest/binary>>) ->
    parse_binding_midi_cc_verb(<<"midi-cc-cont">>, Rest);
try_parse_prefixed(<<"midi-cc ", Rest/binary>>) ->
    parse_binding_midi_cc_verb(<<"midi-cc">>, Rest);
try_parse_prefixed(<<"gate ", Rest/binary>>) ->
    parse_binding_gate_verb(Rest);
try_parse_prefixed(<<"cv-cont ", Rest/binary>>) ->
    parse_binding_cv_cont_verb(Rest);
try_parse_prefixed(<<"cv ", Rest/binary>>) ->
    parse_binding_cv_verb(Rest);

%% --- Atlantis Sync Protocol: clock subscription + direct es9 output ----
%% These verbs let a browser app (via Binnacle) drive the rig directly:
%% subscribe to the forwarded Link anchor, and schedule sample-accurate
%% gates / set CV on es9-daemon buses without going through the BEAM
%% pattern scheduler.  Opt-in: anchors are only pushed to clients that
%% send `clock-subscribe`, so Calypso (also on :3012) is unaffected.
try_parse_prefixed(<<"clock-subscribe">>) -> {clock_subscribe};
%% stage-subscribe — receive `stage <json>` for every slot now, then one
%% per change another page makes (tidal_stage, docs/kb/plans/the-stage.md).
try_parse_prefixed(<<"stage-subscribe">>) -> {stage_subscribe};
try_parse_prefixed(<<"stage-subscribe ", _/binary>>) -> {stage_subscribe};
%% stage-put <slot> <json> — a page records what its machine has loaded and
%% whether it is playing, for a machine whose sound is not one scene push
%% (Odonus, Vetula, Balistes, the Selene rack). The rig plays nothing new;
%% the stage records and announces it. Slots are a fixed set, so a page
%% cannot mint atoms.
try_parse_prefixed(<<"stage-put ", Rest/binary>>) ->
    case binary:split(trim_binary(Rest), <<" ">>) of
        [Slot, Json] -> {stage_put, Slot, Json};
        _ -> none
    end;
%% Text objects on the stage (docs/kb/plans/text-on-the-stage.md):
%%   stage-text-subscribe        → `stage-texts <json>`, every object now,
%%                                 then `stage-text <json>` per write elsewhere
%%   stage-text <key> <text>     write an object (a Vetula card's line)
%%   stage-text-del <key>        delete it
%%   stage-open <key>            ask an editor (Limulus) to show it
%%   stage-reject <key> <reason> the owner could not read a write
%% odonus-sample <json>: a page playing Odonus itself (Solo) asks the rig, the
%% only reader of Tidal, to sample its patterns for steps ahead; see
%% odonus_samples/1.
try_parse_prefixed(<<"odonus-sample ", Json/binary>>) -> {odonus_sample, Json};
try_parse_prefixed(<<"stage-text-subscribe">>) -> {stage_text_subscribe};
try_parse_prefixed(<<"stage-text-subscribe ", _/binary>>) -> {stage_text_subscribe};
try_parse_prefixed(<<"stage-text-del ", Key/binary>>) -> {stage_text, trim_binary(Key), null};
try_parse_prefixed(<<"stage-text ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Key, Text] -> {stage_text, Key, Text};
        _ -> none
    end;
try_parse_prefixed(<<"stage-open ", Key/binary>>) -> {stage_relay, <<"stage-open">>, trim_binary(Key), #{}};
%% stage-paste <key> <text>: hand Limulus a block of text to add to its
%% buffer (a mark, as code: docs/kb/plans/the-deck.md). The key says whose.
try_parse_prefixed(<<"stage-paste ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Key, Text] when Text =/= <<>> -> {stage_relay, <<"stage-paste">>, Key, #{text => Text}};
        _ -> none
    end;
try_parse_prefixed(<<"stage-reject ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Key, Reason] -> {stage_relay, <<"stage-reject">>, Key, #{reason => Reason}};
        _ -> none
    end;
try_parse_prefixed(<<"clock-subscribe ", _/binary>>) -> {clock_subscribe};
try_parse_prefixed(<<"fire-at ", Rest/binary>>) ->
    %% fire-at <bus> <val> <durMs> <delayMs> → /cv/trig/at (sample-accurate)
    case ws_tokens(Rest) of
        [B, V, D, Dl] ->
            case {parse_int(B), parse_number(V),
                  parse_number(D), parse_number(Dl)} of
                {{ok, Bus}, {ok, Val}, {ok, Dur}, {ok, Delay}} ->
                    {fire_at, Bus, Val, Dur, Delay};
                _ -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"cv-out ", Rest/binary>>) ->
    %% cv-out <bus> <val> → /cv (immediate CV set, e.g. pitch)
    case ws_tokens(Rest) of
        [B, V] ->
            case {parse_int(B), parse_number(V)} of
                {{ok, Bus}, {ok, Val}} -> {cv_out, Bus, Val};
                _ -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"cv-slew ", Rest/binary>>) ->
    %% cv-slew <bus> <val> <lagSec> → /cv/slew (glide)
    case ws_tokens(Rest) of
        [B, V, L] ->
            case {parse_int(B), parse_number(V), parse_number(L)} of
                {{ok, Bus}, {ok, Val}, {ok, Lag}} -> {cv_slew, Bus, Val, Lag};
                _ -> none
            end;
        _ -> none
    end;

try_parse_prefixed(_) ->
    none.

try_parse_num_pattern(Tag, Rest) ->
    case binary:split(Rest, <<" ">>) of
        [NumBin, Pattern] ->
            try
                Num = binary_to_integer(NumBin),
                {Tag, Num, strip_quotes(Pattern)}
            catch
                error:badarg -> none
            end;
        _ ->
            none
    end.

%% Parse a binary as a float, accepting either "1.5" or "1" (integer literal).
parse_number(Bin) ->
    try
        FloatVal = binary_to_float(Bin),
        {ok, FloatVal}
    catch
        error:badarg ->
            try
                IntVal = binary_to_integer(Bin),
                {ok, float(IntVal)}
            catch
                error:badarg -> error
            end
    end.

%% Split "<word> <rest>" into {Word, Rest}, or treat single-word input as
%% {Word, <<>>}. Used for named-binding dispatch fallback.
%% Strips surrounding double quotes from Rest so Tidal-style
%% `kick "bd*4"` works the same as our native `kick bd*4`.
split_first_word(Text) ->
    case binary:split(Text, <<" ">>) of
        [Word, Rest] -> {Word, strip_quotes(trim_binary(Rest))};
        [Word] -> {Word, <<>>}
    end.

%% Split a `#`-joined named-binding line into the structure pattern
%% plus a list of joined parameter specs.
%%
%%   `kick "x*4" # vel "100 64 80 50"`            →
%%       {<<"kick">>, <<"x*4">>, [#{name => <<"vel">>, pat => <<"100 64 80 50">>}]}
%%
%%   `kick "x*4" # vel "100" # cutoff "30 60"`    →
%%       {<<"kick">>, <<"x*4">>, [#{name => <<"vel">>, pat => <<"100">>},
%%                                #{name => <<"cutoff">>, pat => <<"30 60">>}]}
%%
%%   `kick "x*4"`                                 →
%%       {<<"kick">>, <<"x*4">>, []}
%%
%% Each segment uses split_first_word to peel off the leading word and
%% strip outer quotes from the body.  Pre-`#`-split avoids the
%% strip_quotes-on-mixed-content trap (where `kick "x*4" # vel "..."`
%% has its outer quotes mis-stripped if treated as a single word+rest).
parse_with_join(Text) ->
    case binary:split(Text, <<" # ">>, [global]) of
        [Single] ->
            %% No join — return the existing word+rest shape with empty params.
            {Word, Rest} = split_first_word(Single),
            {Word, Rest, []};
        [First | RestSegments] ->
            {Word, StructPat} = split_first_word(First),
            ParamSpecs = [parse_join_segment(S) || S <- RestSegments],
            %% Drop any segments that didn't yield a name+body shape.
            ValidSpecs = [P || P <- ParamSpecs, P =/= invalid],
            {Word, StructPat, ValidSpecs}
    end.

%% Parse one `<name> <body>` segment from after a `#`.  The body may
%% be quoted; strip_quotes handles the unquoted case idempotently.
%% Returns `invalid` rather than a partial spec if the segment doesn't
%% have at least name + body — the caller drops invalid specs.
parse_join_segment(Segment) ->
    case binary:split(string:trim(Segment), <<" ">>) of
        [Name, Body] when Body =/= <<>> ->
            #{name => Name, pat => strip_quotes(Body)};
        _ ->
            invalid
    end.

%% Common install path for verbs that parse to a discrete Pattern and
%% want to install it as a voice (fh2-trigger, kit, kit-expr). Wraps
%% the dispatcher set_binding + voice_sup set_voice_pat sequence and
%% the standard error formatting.
%%
%% ParserResult is the {right, Pat} | {left, ErrTerm} envelope from
%% the parser (parseMiniPattern or parseEvalPattern — same shape).
%% VerbLabel is used in both error replies: install failure becomes
%% "ERROR: <VerbLabel>: <err>", parse failure becomes
%% "ERROR: <VerbLabel> parse: <err>". OkBin is the full OK reply
%% binary (constructed at the call site since the verb-specific text
%% varies).
%%
%% Returns the cowboy_websocket {reply, ReplyTerm, State} triple.
%%
%% set_binding is called before set_voice_pat so the dispatcher can
%% never see a voice event for a name it hasn't yet recorded.
install_pattern_voice(ParserResult, VoiceName, Binding, VerbLabel,
                      OkBin, State) ->
    case ParserResult of
        {right, PatStr} ->
            %% Parser produces Pattern String; voice expects Pattern
            %% Sound (the unified typed carrier).  Classify per-event
            %% (note-shaped → Chromatic pitch, sample-shaped → source
            %% token) before installing.
            Pat = ('tidal_voice@ps':liftStringToSound())(PatStr),
            tidal_dispatcher:set_binding(VoiceName, Binding),
            case tidal_voice_sup:set_voice_pat(VoiceName, Binding, Pat) of
                ok ->
                    {reply, {text, OkBin}, State};
                {error, Err} ->
                    ErrBin = list_to_binary(io_lib:format("~p", [Err])),
                    {reply,
                     {text, <<"ERROR: ", VerbLabel/binary, ": ",
                              ErrBin/binary>>},
                     State}
            end;
        {left, ErrBin0} ->
            ErrBin = case ErrBin0 of
                B when is_binary(B) -> B;
                Other -> list_to_binary(io_lib:format("~p", [Other]))
            end,
            {reply,
             {text, <<"ERROR: ", VerbLabel/binary, " parse: ",
                      ErrBin/binary>>},
             State}
    end.

%% Strip a single pair of surrounding double quotes if present.
%% `<<"\"bd*4\"">>` → `<<"bd*4">>`. Idempotent on already-unquoted input.
strip_quotes(Bin) ->
    Sz = byte_size(Bin),
    case Sz >= 2 of
        true ->
            First = binary:part(Bin, 0, 1),
            Last = binary:part(Bin, Sz - 1, 1),
            case First =:= <<"\"">> andalso Last =:= <<"\"">> of
                true -> binary:part(Bin, 1, Sz - 2);
                false -> Bin
            end;
        false -> Bin
    end.

%% Trim leading/trailing whitespace from a binary.
trim_binary(Bin) ->
    list_to_binary(string:trim(binary_to_list(Bin))).

%% Strip a trailing " lat <ms>" suffix from a device-name binary.
%% Returns {DeviceName, Latency} where Latency is a float (default 0.0
%% if the suffix is absent or unparseable).
%%
%%   "FH-2"               → {<<"FH-2">>, 0.0}
%%   "AUDIO4c USB2 lat 12"→ {<<"AUDIO4c USB2">>, 12.0}
%%   "FH-2 lat 1.5"       → {<<"FH-2">>, 1.5}
strip_surrounding_quotes(<<"\"", Rest/binary>>) when byte_size(Rest) >= 1 ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> <<"\"", Rest/binary>>
    end;
strip_surrounding_quotes(B) -> B.

split_lat_suffix(Bin) ->
    %% Look for " lat " followed by a number to end of line.
    Parts = binary:split(Bin, <<" lat ">>, [global]),
    case Parts of
        [Single] ->
            {Single, 0.0};
        [Name | LatParts] ->
            %% The lat value is everything after the LAST " lat ".
            %% (Unlikely to be ambiguous since device names don't usually
            %% contain " lat " — but if they do, that's a self-inflicted
            %% wound and we still cope.)
            LatBin = lists:last(LatParts),
            case parse_number(trim_binary(LatBin)) of
                {ok, Lat} -> {Name, Lat};
                error -> {Bin, 0.0}  %% suffix didn't parse — treat whole thing as name
            end
    end.

%% Handle pattern messages. New path: recognise "gate <ch>" / "cv <bus>"
%% prefixes for per-track replacement (live-coding shape). Otherwise
%% fall through to the legacy single-pattern / multi-track JSON parser.
handle_pattern_message(Text, State) ->
    case try_parse_prefixed(Text) of
        {clock_subscribe} ->
            %% Register this WS handler with the anchor listener; it will
            %% start receiving {anchor_broadcast, Bin} info messages
            %% (handled in websocket_info/2). Idempotent + harmless if the
            %% anchor listener isn't running.
            case whereis(tidal_link_anchor) of
                undefined -> ok;
                _ -> tidal_link_anchor ! {subscribe, self()}
            end,
            {reply, {text, <<"OK: clock-subscribe">>}, State};
        {stage_subscribe} ->
            tidal_stage:subscribe(self()),
            {reply, {text, <<"OK: stage-subscribe">>}, State};
        {odonus_sample, Json} ->
            {reply, {text, odonus_samples(Json)}, State};
        {stage_text_subscribe} ->
            Table = tidal_stage:text_subscribe(self()),
            Json = iolist_to_binary(json:encode(Table)),
            {reply, {text, <<"stage-texts ", Json/binary>>}, State};
        {stage_text, <<"routing/harmony">>, Body} ->
            %% the router's harmony routes: the rig reads these itself
            {reply, {text, apply_routes(Body)}, State};
        {stage_text, Key, Body} ->
            %% (not `Text`: that is this function's argument, and a bound
            %% variable in a pattern is a comparison)
            case tidal_stage:valid_key(Key) of
                false ->
                    {reply, {text, <<"ERR: stage-text: no such key ", Key/binary, " (want <slot>/<name>, e.g. vetula/v3)">>}, State};
                true ->
                    Ver = tidal_stage:put_text(Key, Body, self()),
                    {reply, {text, iolist_to_binary(io_lib:format("OK: stage-text ~s ~s (version ~p)",
                        [Key, case Body of null -> "deleted"; _ -> "written" end, Ver]))}, State}
            end;
        {stage_relay, Kind, Key, Fields} ->
            case tidal_stage:valid_key(Key) of
                false ->
                    {reply, {text, <<"ERR: ", Kind/binary, ": no such key ", Key/binary>>}, State};
                true ->
                    tidal_stage:relay(Kind, Fields#{key => Key}, self()),
                    {reply, {text, <<"OK: ", Kind/binary, " ", Key/binary>>}, State}
            end;
        {stage_put, SlotBin, Json} ->
            case {stage_slot(SlotBin), catch json:decode(Json)} of
                {undefined, _} ->
                    {reply, {text, <<"ERR: stage-put unknown slot ", SlotBin/binary>>}, State};
                {Slot, Entry} when is_map(Entry) ->
                    tidal_stage:set(Slot, Entry, self()),
                    {reply, {text, <<"OK: stage-put ", SlotBin/binary>>}, State};
                _ ->
                    {reply, {text, <<"ERR: stage-put wants a JSON object">>}, State}
            end;
        {fire_at, Bus, Val, Dur, Delay} ->
            es9_relay(<<"/cv/trig/at">>,
                      [Bus, float(Val), float(Dur), float(Delay)]),
            {reply, {text, <<"OK: fire-at">>}, State};
        {cv_out, Bus, Val} ->
            es9_relay(<<"/cv">>, [Bus, float(Val)]),
            {reply, {text, <<"OK: cv-out">>}, State};
        {cv_slew, Bus, Val, Lag} ->
            es9_relay(<<"/cv/slew">>, [Bus, float(Val), float(Lag)]),
            {reply, {text, <<"OK: cv-slew">>}, State};
        {bind, Name, ActionSpec} ->
            tidal_dispatcher:set_binding_from_spec(Name, ActionSpec),
            Reply = {text, <<"OK: bind ", Name/binary, " ", ActionSpec/binary>>},
            {reply, Reply, State};
        {unbind, Name} ->
            tidal_dispatcher:remove_binding(Name),
            Reply = {text, <<"OK: unbind ", Name/binary>>},
            {reply, Reply, State};
        {tidal_line, Block} ->
            {reply, {text, tidal_line(Block)}, State};
        {hush} ->
            hush_everything(),
            Reply = {text, <<"OK: hush">>},
            {reply, Reply, State};
        {unhush} ->
            %% Inverse of {hush} for the Odonus side.  Tidal voices
            %% don't carry a hush flag — they're "hushed" by clearing
            %% the pattern, which requires re-arming to bring back, so
            %% unhush only touches Odonus.
            OdonusPids = odonus_voice_sup:which_voices(),
            lists:foreach(
              fun(Pid) -> gen_server:cast(Pid, unhush) end, OdonusPids),
            Reply = {text, <<"OK: unhush">>},
            {reply, Reply, State};
        {silence_one, Name} ->
            %% Per-voice silence: clear the pattern but keep the
            %% voice + binding alive so a subsequent arm restarts
            %% it cleanly.  Idempotent — silencing a missing or
            %% already-silent voice is a no-op.
            tidal_voice_sup:silence_voice(Name),
            Reply = {text, <<"OK: silence ", Name/binary>>},
            {reply, Reply, State};
        {reef_stop} ->
            %% Per-tab ATLANTIS stop: silence just the reef-odonus voice.
            catch reef_voice:stop(),
            {reply, {text, <<"OK: reef-stop">>}, State};
        {balistes_stop} ->
            %% Per-tab ATLANTIS stop: BOTH kinds of Balistes voice. The lockstep
            %% singleton (balistes-sim-at / -fixed) AND the named voices
            %% under balistes_voice_sup that the `balistes <json>` verb starts.
            %% Before 2026-08-07 this stopped only the singleton, so pressing stop
            %% on a named voice reported OK and changed nothing.
            catch reef_balistes_voice:stop(),
            stop_voice_tree(balistes_voice_sup),
            {reply, {text, <<"OK: balistes-stop">>}, State};
        {vetula_cards_play} ->
            vetula_cards:play(),
            {reply, {text, <<"OK: vetula-cards-play">>}, State};
        {vetula_cards_stop} ->
            vetula_cards:stop(),
            {reply, {text, <<"OK: vetula-cards-stop">>}, State};
        {vetula_stop} ->
            %% Per-tab ATLANTIS stop: silence just the Vetula brush voice.
            catch reef_vetula_brush:stop(),
            catch vetula_cards:stop(),
            {reply, {text, <<"OK: vetula-stop">>}, State};
        {log_level, N} ->
            tidal_log:set_level(N),
            NBin = integer_to_binary(N),
            Reply = {text, <<"OK: log-level ", NBin/binary>>},
            {reply, Reply, State};
        {reef_odonus, Json} ->
            %% Run a complete Odonus record (built in the frontend, decoded by
            %% the shared reef codec) as a reef voice. Heads emit on base+headIdx =
            %% ch 12/13/14/15 (one channel per head, separable in Ableton). Now
            %% LINK-CLOCK-LOCKED (P4b): the 3rd arg is the model step length in BEATS
            %% (0.25 = a 1/16 note), matching the frontend grid so the two runtimes
            %% agree on tick N.
            case reef_voice:start_json(Json, 12, 0.25) of
                {ok, _Pid} ->
                    {reply, {text, <<"OK: reef-odonus (ch12-15)">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: reef-odonus ", RB/binary>>}, State}
            end;
        {reef_sim, Json} ->
            %% The lockstep handoff (P4d): start a Link-clock-locked reef voice from
            %% the frontend's WHOLE SimState (gen + seed). Heads on base+headIdx =
            %% ch 12/13/14/15 (one per head), 1/16 grid.
            case reef_voice:start_sim_json(Json, 12, 0.25) of
                {ok, Pid} ->
                    routes_to_voice(Pid),
                    {reply, {text, <<"OK: reef-sim (ch12-15)">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: reef-sim ", RB/binary>>}, State}
            end;
        {reef_sim_at, N, Beats, Json} ->
            %% Phase-aligned handoff (P5): same SimState, but install the model-step
            %% grid (Beats) and hold the pushed state until absolute model step N (the
            %% frontend's nextModelStep) so both runtimes emit it on the SAME step in
            %% the SAME grid — the real flam fix. Heads on ch 12/13/14/15.
            case reef_voice:start_sim_at_json(Json, 12, Beats, N) of
                {ok, Pid} ->
                    routes_to_voice(Pid),
                    NB = integer_to_binary(N),
                    {reply, {text, <<"OK: reef-sim-at ", NB/binary, " (ch12-15)">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: reef-sim-at ", RB/binary>>}, State}
            end;
        {balistes_sim_at, N, Beats, Json} ->
            %% Balistes phase-aligned handoff: install the model-step grid (Beats)
            %% and hold the pushed BalSim until absolute step N (the frontend's
            %% nextModelStep), so browser and rig both emit it on the SAME absolute
            %% step — the Odonus #57 flam fix, baked in from the start. Drums-always-
            %% ch-10 convention (2026-07-12): rig plays ch 10, matching the frontend.
            case reef_balistes_voice:start_sim_at_json(Json, 10, Beats, N) of
                {ok, _Pid} ->
                    NB = integer_to_binary(N),
                    {reply, {text, <<"OK: balistes-sim-at ", NB/binary, " (ch10)">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: balistes-sim-at ", RB/binary>>}, State}
            end;
        {balistes_fixed, Json} ->
            %% Fixed-rhythm handoff: play a pushed FixedPattern on ch 10. Stateless, so
            %% the voice just evals renderFixed per absolute step — in lockstep with the
            %% frontend's AFixed branch, which reads the same Link step.
            case reef_balistes_voice:start_fixed_json(Json, 10, 0.25) of
                {ok, _Pid} ->
                    {reply, {text, <<"OK: balistes-fixed (ch10)">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: balistes-fixed ", RB/binary>>}, State}
            end;
        {dirt_play, Json} ->
            case dirt_audition(Json) of
                ok -> {reply, {text, <<"OK: dirt-play">>}, State};
                {error, Why} -> {reply, {text, <<"ERR: dirt-play ", Why/binary>>}, State}
            end;
        {balistes_routing, Json} ->
            case reef_balistes_voice:set_routing_json(Json) of
                ok ->
                    %% kept on the stage, which keeps it on disk, so a restarted
                    %% rig routes drums as before (tidal_stage:restore/2)
                    tidal_stage:put_text(<<"balistes/routing">>, Json, self()),
                    {reply, {text, <<"OK: balistes-routing">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: balistes-routing ", RB/binary>>}, State}
            end;
        {odonus_routing, Json} ->
            case reef_voice:set_routing_json(Json) of
                ok ->
                    tidal_stage:put_text(<<"odonus/routing">>, Json, self()),
                    {reply, {text, <<"OK: odonus-routing">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: odonus-routing ", RB/binary>>}, State}
            end;
        {balistes_input, Json} ->
            %% Balistes live knob sync: decode the tick-tagged BInput with the SAME
            %% codec the frontend encoded it with (reef_balistes_protocol@ps) and hand
            %% it to the running Balistes voice, which applies it on the tagged step.
            case 'reef_balistes_protocol@ps':decodeBTagged(Json) of
                {right, Tagged} ->
                    case whereis(reef_balistes_voice) of
                        undefined ->
                            {reply, {text, <<"ERR: balistes-input (no balistes voice)">>}, State};
                        _ ->
                            reef_balistes_voice ! {apply_input,
                                                   maps:get(tick, Tagged),
                                                   maps:get(input, Tagged)},
                            {reply, {text, <<"OK: balistes-input">>}, State}
                    end;
                {left, Errs} ->
                    RB = list_to_binary(io_lib:format("~p", [Errs])),
                    {reply, {text, <<"ERR: balistes-input decode ", RB/binary>>}, State}
            end;
        {vetula_perf, Json} ->
            %% Vetula performance handoff: run (or live-swap) the pushed Perf on the
            %% rig. The → odo voice conducts reef_voice — reproducing the browser's
            %% "Vetula chord progressions quantising Odonus output" entirely in the
            %% backend. Push Odonus (reef-sim-at) FIRST so the first chord lands.
            case reef_vetula_voice:start_perf_json(Json, 0.25) of
                {ok, _Pid} ->
                    {reply, {text, <<"OK: vetula-perf (conducts reef_voice)">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: vetula-perf ", RB/binary>>}, State}
            end;
        {vetula_voicings, Ch, Renderer, Json} ->
            %% Palette→brush handoff (Option B): build a real Tidal Pattern from the
            %% pushed voicings (Tidal.Vetula.Bridge: JSON → Voicings → renderer) and
            %% play it on the claimed channel via reef_vetula_brush — a self-contained
            %% reef-family voice on Odonus's Link grid, queried per pulse. A re-push
            %% swaps the pattern in place (live re-voice). No Calypso/dispatcher.
            case reef_vetula_brush:start_json(Ch, Renderer, Json) of
                {ok, _Pid} ->
                    {reply, {text, <<"OK: vetula-voicings ch",
                                     (integer_to_binary(Ch))/binary, " ",
                                     Renderer/binary>>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: vetula-voicings ", RB/binary>>}, State}
            end;
        {conspicillum_scene, Json} ->
            %% Conspicillum handoff: run (or live-swap) the pushed cloud, and
            %% record it on the stage.
            {Scene, Staged} = stage_envelope(Json),
            case reef_conspicillum_voice:start_json(Scene) of
                {ok, _Pid} ->
                    tidal_stage:put(conspicillum, Staged, self()),
                    {reply, {text, <<"OK: conspicillum-scene (SuperDirt :57120)">>}, State};
                {error, Reason} ->
                    RB = list_to_binary(io_lib:format("~p", [Reason])),
                    {reply, {text, <<"ERR: conspicillum-scene ", RB/binary>>}, State}
            end;
        {conspicillum_stop} ->
            catch reef_conspicillum_voice:stop(),
            tidal_stage:stopped(conspicillum),
            {reply, {text, <<"OK: conspicillum-stop">>}, State};
        {reef_input, Json} ->
            %% Lockstep live edit (P4c): decode the tick-tagged input with the SAME
            %% codec the frontend encoded it with (reef_protocol@ps:decodeTagged) and
            %% hand it to the running reef voice, which applies it on the tagged step.
            %% No-op with a clear reply if no voice is running (nothing to sync yet).
            case 'reef_protocol@ps':decodeTagged(Json) of
                {right, Tagged} ->
                    case whereis(reef_voice) of
                        undefined ->
                            {reply, {text, <<"ERR: reef-input (no reef voice)">>}, State};
                        _ ->
                            reef_voice ! {apply_input,
                                          maps:get(tick, Tagged),
                                          maps:get(input, Tagged)},
                            {reply, {text, <<"OK: reef-input">>}, State}
                    end;
                {left, Errs} ->
                    RB = list_to_binary(io_lib:format("~p", [Errs])),
                    {reply, {text, <<"ERR: reef-input decode ", RB/binary>>}, State}
            end;
        {reef_steplen, Beats} ->
            %% Lockstep STEP LENGTH sync (P4c): retune the running reef voice's grid.
            case whereis(reef_voice) of
                undefined ->
                    {reply, {text, <<"ERR: reef-steplen (no reef voice)">>}, State};
                _ ->
                    reef_voice ! {set_step_beats, Beats},
                    {reply, {text, <<"OK: reef-steplen">>}, State}
            end;
        {reef_swing, S} ->
            %% Lockstep SWING sync (P4f render stage 2): set the running voice's swing.
            case whereis(reef_voice) of
                undefined ->
                    {reply, {text, <<"ERR: reef-swing (no reef voice)">>}, State};
                _ ->
                    reef_voice ! {set_swing, S},
                    {reply, {text, <<"OK: reef-swing">>}, State}
            end;
        {load, Name} ->
            handle_load_setup(Name, State);
        {midi_device, Alias, DeviceName, Latency} ->
            tidal_dispatcher:register_midi_device(Alias, DeviceName, Latency),
            LatBin = list_to_binary(io_lib:format("~p", [Latency])),
            Reply = {text, <<"OK: midi-device ", Alias/binary,
                             " = ", DeviceName/binary,
                             " (lat ", LatBin/binary, "ms)">>},
            {reply, Reply, State};
        {fh2_gate, Voice, Output, Channel} ->
            %% Gate-only MCV configuration via fh2-config CLI shell-out.
            %% No scheduler state to update (gates are dispatched via
            %% bind+midi-note, which uses explicit channel — no voice
            %% lookup needed).
            spawn(fun() -> fh2_set_gate(Voice, Output, Channel) end),
            Reply = {text, <<"OK: fh2-gate voice ",
                             (integer_to_binary(Voice))/binary,
                             " -> output ", (integer_to_binary(Output))/binary,
                             " on ch ", (integer_to_binary(Channel))/binary,
                             " (SysEx push in flight)">>},
            {reply, Reply, State};
        {selene, Json} ->
            %% Polysignal: a multi-output autonomous FH-2 panel
            %% configuration (polylfo / polyclock / polyenv /
            %% polyeuclid / polyeuclid-pairs / polyrand). The cell
            %% block has been transposed by Calypso into a single
            %% line `polysignal <json>`, with the cell-text owner
            %% name carried in the JSON's `alias` field as of the
            %% port-claims-design step 4b wire format.
            %%
            %% Synchronous through the fh2-config daemon so claim
            %% errors (partial conflicts, capability mismatches,
            %% eviction reports) surface in the Calypso reply pane
            %% rather than getting silently logged by the daemon.
            %% Matches the drumkit arm's daemon-call shape; falls
            %% back to a fire-and-forget spago shell-out when the
            %% daemon is unreachable (~7s tax — visible delay, but
            %% the user gets *some* feedback instead of an
            %% erroneous OK).
            Reply = case fh2_daemon_call(<<"apply-polysignal ", Json/binary>>) of
                {ok, ReplyBin} ->
                    {text, ReplyBin};
                {error, _Reason} ->
                    spawn(fun() -> fh2_apply_selene_standalone(Json) end),
                    {text, <<"OK: selene apply in flight (daemon "
                             "unreachable; spago shell-out, ~7s)">>}
            end,
            {reply, Reply, State};
        {selene_apply, Socket, Bank, Json} ->
            %% Triggerfish Selene → modular (#142). Relay one CV/gate
            %% destination's apply-polysignal envelope to the right daemon
            %% control socket (es9-daemon or fh2-config daemon), both of
            %% which speak the identical line protocol. The reply echoes
            %% socket+bank so the browser can show OK / claim-eviction /
            %% ERR against the exact destination row. Purely a config
            %% relay — no scheduled voice, so no conformance surface.
            SockPath = selene_socket_path(Socket),
            Reply = case daemon_call(SockPath, <<"apply-polysignal ", Json/binary>>) of
                {ok, ReplyBin} ->
                    {text, <<"selene-reply ", Socket/binary, " ", Bank/binary, " ", ReplyBin/binary>>};
                {error, Reason} ->
                    ReasonBin = list_to_binary(io_lib:format("~p", [Reason])),
                    {text, <<"selene-reply ", Socket/binary, " ", Bank/binary,
                             " ERR daemon-unreachable: ", ReasonBin/binary>>}
            end,
            {reply, Reply, State};
        {balistes, Json} ->
            %% Balistes cell: a BEAM-native MI Balistes voice declared
            %% directly from a Calypso cell.  JSON shape:
            %%
            %%   {"alias":"myKit","deviceName":"FH-2","channel":13,
            %%    "x":128,"y":128,"fillBd":220,"fillSd":100,
            %%    "fillHh":180,"randomness":32,"mode":0}
            %%
            %% Builds a static BalistesConfig (`pure n` per slot) via
            %% the PS helper and spawns/updates the voice.  For
            %% richer Pattern-driven slots, declare in Studio.purs
            %% with `liveIntOr` etc. instead.
            Reply = apply_balistes_cell(Json),
            {reply, Reply, State};
        {drumkit, Json} ->
            %% Drum-kit apply, synchronous through the fh2-config
            %% daemon. Validation against the ClaimRig + MCV-slot
            %% allocation + FH-2 byte write happen daemon-side; the
            %% daemon's reply (OK with allocation info, or ERR with
            %% a typed error message) goes straight to the WS reply
            %% pane. ~10ms roundtrip in the happy path. On daemon
            %% unreachable, we surface that as the error rather than
            %% falling through to a slower path — drumkits are tied
            %% to live cells and need the daemon to be up.
            %%
            %% On a successful apply, the daemon's reply carries a
            %% `voices=name:channel,name:channel,...` segment. We
            %% parse that here and register a `midi-note` binding
            %% for each voice against the `fh2` device alias — that
            %% way pattern tokens like `bd` actually fire when the
            %% next cell runs. Without this step the FH-2 is
            %% configured but purerl-tidal doesn't know how to route
            %% to it.
            Reply = case fh2_daemon_call(<<"apply-drumkit ", Json/binary>>) of
                {ok, ReplyBin} ->
                    case is_drumkit_ok_reply(ReplyBin) of
                        true ->
                            register_drumkit_voice_bindings(ReplyBin);
                        false -> ok
                    end,
                    {text, ReplyBin};
                {error, Reason} ->
                    ReasonBin = list_to_binary(io_lib:format("~p", [Reason])),
                    {text, <<"ERR drumkit: fh2-config daemon unreachable (",
                             ReasonBin/binary, ")">>}
            end,
            {reply, Reply, State};
        {fh2_envelope, Voice, Output, Channel} ->
            %% Dispatcher owns the voice→channel mapping (PR1.6 +
            %% PR1.7b). setFh2VoiceChannel auto-registers the `fh2`
            %% MIDI device alias if the user hasn't done it manually.
            %% The FH-2 SysEx push runs in the background (5–10s);
            %% any fh2-trigger note that lands during the push just
            %% hits the still-old routing for a moment.
            tidal_dispatcher:set_fh2_voice_channel(Voice, Channel),
            spawn(fun() -> fh2_set_envelope(Voice, Output, Channel) end),
            Reply = {text, <<"OK: fh2-envelope voice ",
                             (integer_to_binary(Voice))/binary,
                             " -> output ", (integer_to_binary(Output))/binary,
                             " on ch ", (integer_to_binary(Channel))/binary,
                             " (SysEx push in flight)">>},
            {reply, Reply, State};
        {fh2_trigger, Voice, Pattern} ->
            %% After PR1.6: install a Discrete voice in the new tree
            %% with name `fh2-v<N>` and a single Fh2Trigger PrimAction.
            %% defaultNote = 60 (C4) matches MIDIScheduler's previous
            %% fallback for non-note-name tokens. Channel is resolved
            %% at dispatch time from the dispatcher's
            %% fh2VoiceChannels map (populated via fh2-envelope above).
            VoiceBin = integer_to_binary(Voice),
            VoiceName = <<"fh2-v", VoiceBin/binary>>,
            Binding = array:from_list(
                [{fh2Trigger, #{voice => Voice, defaultNote => 60}}]),
            OkBin = <<"OK: fh2-trigger v", VoiceBin/binary,
                      " ", Pattern/binary>>,
            install_pattern_voice(
                ('tidal_pattern_mini@ps':parseMiniPattern())(Pattern),
                VoiceName, Binding, <<"fh2-trigger">>, OkBin, State);
        {kit, KitName, Pattern} ->
            %% Install a voice named `kit-<KitName>` whose binding is
            %% a single KitDispatch PrimAction. On each event the
            %% dispatcher looks up the event TOKEN (not the voice
            %% name) in the binding registry and walks that
            %% binding's PrimActions. Pairs with `drumkit`-installed
            %% per-voice bindings — `kit kitA "bd sn bd cp"`
            %% dispatches each token through bd / sn / cp's bindings.
            %%
            %% Voice name is namespaced `kit-` so multiple kits can
            %% coexist and can't collide with arbitrary user bindings.
            %%
            %% `{kitDispatch}` is the purs-backend-erl encoding of
            %% the nullary `KitDispatch` PureScript constructor (a
            %% 1-tuple, per the reference-purs-backend-erl-
            %% constructor-encoding gotcha).
            VoiceName = <<"kit-", KitName/binary>>,
            Binding = array:from_list([{kitDispatch}]),
            OkBin = <<"OK: kit ", KitName/binary, " ", Pattern/binary>>,
            install_pattern_voice(
                ('tidal_pattern_mini@ps':parseMiniPattern())(Pattern),
                VoiceName, Binding, <<"kit">>, OkBin, State);
        {yarns, YarnsName, Mode, Alloc, GlideMs, VoiceCount,
         BaseChannel, Json} ->
            %% Yarns cell — daemon-side apply uses its OWN command
            %% (`apply-yarns`) so the ClaimRig tags ownership as
            %% OwnYarns rather than OwnDrumKit. JSON envelope shape
            %% is identical to drumkit's; the daemon's
            %% applyMacroEnvelope helper handles the kind dispatch.
            %% Reply prefix is `OK apply-yarns` accordingly.
            %%
            %% Install order: ETS allocator state before set_binding
            %% so the first dispatch event has somewhere to allocate
            %% against (tidal_yarns_state:install is synchronous).
            Reply = case fh2_daemon_call(<<"apply-yarns ", Json/binary>>) of
                {ok, ReplyBin} ->
                    case is_apply_ok_reply(<<"yarns">>, ReplyBin) of
                        true ->
                            register_yarns_binding(
                                YarnsName, Mode, Alloc, GlideMs,
                                BaseChannel, VoiceCount),
                            {text, ReplyBin};
                        false ->
                            {text, ReplyBin}
                    end;
                {error, Reason} ->
                    ReasonBin = list_to_binary(
                                  io_lib:format("~p", [Reason])),
                    {text, <<"ERR yarns: fh2-config daemon unreachable (",
                             ReasonBin/binary, ")">>}
            end,
            {reply, Reply, State};
        {chord, ChordName, ShapeName, VoiceCount, BaseChannel, Json} ->
            %% Chord cell — daemon-side apply uses its OWN command
            %% (`apply-chord`) so the ClaimRig tags ownership as
            %% OwnChord rather than OwnDrumKit. JSON envelope shape
            %% is identical to drumkit's; the daemon's
            %% applyMacroEnvelope helper handles the kind dispatch.
            %% Reply prefix is `OK apply-chord` accordingly.
            Reply = case fh2_daemon_call(<<"apply-chord ", Json/binary>>) of
                {ok, ReplyBin} ->
                    case is_apply_ok_reply(<<"chord">>, ReplyBin) of
                        true ->
                            register_chord_binding(
                                ChordName, ShapeName,
                                BaseChannel, VoiceCount),
                            {text, ReplyBin};
                        false ->
                            {text, ReplyBin}
                    end;
                {error, Reason} ->
                    ReasonBin = list_to_binary(
                                  io_lib:format("~p", [Reason])),
                    {text, <<"ERR chord: fh2-config daemon unreachable (",
                             ReasonBin/binary, ")">>}
            end,
            {reply, Reply, State};
        {release_claim, Kind, Name} ->
            %% Relay to fh2-config daemon. Daemon validates the kind
            %% and either OKs the release or returns a typed error.
            %% No BEAM-side state change beyond the relay — stale
            %% dispatcher bindings remain but their hardware is now
            %% unclaimed, so any in-flight patterns silently no-op.
            Reply = case fh2_daemon_call(
                            <<"release-claim ", Kind/binary,
                              " ", Name/binary>>) of
                {ok, ReplyBin} ->
                    {text, ReplyBin};
                {error, Reason} ->
                    ReasonBin = list_to_binary(
                                  io_lib:format("~p", [Reason])),
                    {text, <<"ERR release-claim: fh2-config daemon "
                             "unreachable (", ReasonBin/binary, ")">>}
            end,
            {reply, Reply, State};
        {fh2_shape, Voice, A, D, S, R} ->
            tidal_dispatcher:dispatch_fh2_shape(Voice, A, D, S, R),
            Reply = {text, <<"OK: fh2-shape v",
                             (integer_to_binary(Voice))/binary,
                             " A=", (integer_to_binary(A))/binary,
                             " D=", (integer_to_binary(D))/binary,
                             " S=", (integer_to_binary(S))/binary,
                             " R=", (integer_to_binary(R))/binary>>},
            {reply, Reply, State};
        {state} ->
            %% Read latest snapshot from StateBus (ETS-backed).  Falls
            %% back to "{}" if the table doesn't exist yet (boot window).
            Json = (tidal_stateBus@foreign:read())(),
            {reply, {text, Json}, State};
        {set_bpm, N} ->
            %% Clock owns the BPM value; dispatcher broadcasts to
            %% link-spike. Both fire in parallel — clock's set_bpm is
            %% synchronous (so the snapshot picks up the new value on
            %% the next publisher tick), dispatcher's set_link_tempo
            %% is fire-and-forget OSC.
            tidal_clock:set_bpm(N),
            tidal_dispatcher:set_link_tempo(N),
            NumBin = list_to_binary(io_lib:format("~p", [N])),
            {reply, {text, <<"OK: bpm = ", NumBin/binary>>}, State};
        {set_control, Name, Value} ->
            %% Live control bus: writes are O(1) ETS inserts.
            %% Voices pick up the new value on their next compute
            %% tick (every ~50ms per current clock config), via the
            %% snapshot threaded through Window.controlPairs and
            %% materialised as State.controls in pattern queries.
            tidal_control_bus:set(Name, Value),
            ValBin = list_to_binary(io_lib:format("~p", [Value])),
            {reply, {text, <<"OK: ", Name/binary, " = ", ValBin/binary>>}, State};
        {set_scale, Name} ->
            %% Active-scale ETS write.  Resolves the kebab-case name
            %% through `Tidal.Substrate.Scales.lookupScaleByName`; on the next
            %% tick every voice's Window.activeScale carries the new
            %% Scale value and Degree pitches re-render against it.
            case tidal_scale_bus:set_scale(Name) of
                {ok, _} ->
                    {reply,
                     {text, <<"OK: scale = ", Name/binary>>},
                     State};
                {error, unknown_scale} ->
                    {reply,
                     {text, <<"ERR set-scale: unknown scale '",
                              Name/binary,
                              "' (try c-major, c-mixolydian, "
                              "a-harmonic-minor, d-dorian, …)">>},
                     State}
            end;
        {clear_scale} ->
            tidal_scale_bus:clear_scale(),
            {reply, {text, <<"OK: scale cleared">>}, State};
        {clear_controls} ->
            %% Reset the live-control bus, preserving Odonus mute state
            %% (`odonus.mute*` keys).  Mute is a deliberate audible-
            %% performance gesture — a user who un-muted a playhead
            %% expects it to stay un-muted across a knob reset.  Every
            %% other set-control reading drops back to the cell's
            %% declared default on the next compute tick.  Version
            %% counter is bumped inside clear_except/1 so cached
            %% ControlMaps in voices are invalidated.
            tidal_control_bus:clear_except([<<"odonus.mute">>]),
            {reply, {text, <<"OK: controls cleared (mutes preserved)">>}, State};
        {phase_resync} ->
            %% Walk every Odonus voice and cast phase_resync.  Each
            %% voice resets its engine's playheads to cursor 0,
            %% accumulator 0, pend_step +1, and rewinds last_step to
            %% -1 so emission re-aligns on the next master tick.
            %% odonus_voice_sup:which_voices/0 returns bare pids.
            Pids = odonus_voice_sup:which_voices(),
            lists:foreach(
              fun(Pid) -> gen_server:cast(Pid, phase_resync) end, Pids),
            N = list_to_binary(integer_to_list(length(Pids))),
            {reply, {text, <<"OK: phase-resync ", N/binary,
                             " Odonus voice(s)">>}, State};
        {set_nav_mode, Mode} ->
            %% Live-mutate nav_mode on every Odonus voice.  Reuses the
            %% existing set_config cast path which already handles a
            %% partial #{nav_mode => Atom} via odonus_engine:set_field
            %% (validated against nav_modes() — bad atoms are rejected
            %% server-side, but the parser already restricts to the
            %% three known modes so we won't get here with garbage).
            Pids = odonus_voice_sup:which_voices(),
            lists:foreach(
              fun(Pid) -> gen_server:cast(Pid, {set_config,
                                                #{nav_mode => Mode}}) end,
              Pids),
            ModeBin = atom_to_binary(Mode, utf8),
            N2 = list_to_binary(integer_to_list(length(Pids))),
            {reply, {text, <<"OK: set-nav-mode ", ModeBin/binary,
                             " on ", N2/binary, " Odonus voice(s)">>}, State};
        {shred_mod, N} ->
            %% Mimetic-Digitalis-style mod reroll.  Reads the L-mid
            %% Globals shred-rate knob for modN from the control bus;
            %% for each cell idx 0..15 rolls uniform random < rate;
            %% on success writes a fresh random 0..127 to the cell's
            %% bus key.  Voices read the bus via liveIntArrayOr so the
            %% new values reach the engine on the next compute tick.
            %% Rate default 1.0 = full reroll on first press (no knob
            %% touched yet → defaults to full Mimetic behaviour).
            NBin     = integer_to_binary(N),
            RateKey  = <<"odonus.shredRate", NBin/binary>>,
            ModPrefix = <<"odonus.mod", NBin/binary, ".">>,
            Rate = case tidal_control_bus:get(RateKey, 1.0) of
                     R when is_number(R), R >= 0.0, R =< 1.0 -> R;
                     _ -> 1.0
                   end,
            Replaced = lists:foldl(
              fun(I, Acc) ->
                case rand:uniform() =< Rate of
                  false -> Acc;
                  true  ->
                    NewVal = float(rand:uniform(128) - 1),
                    Key = <<ModPrefix/binary,
                            (integer_to_binary(I))/binary>>,
                    tidal_control_bus:set(Key, NewVal),
                    Acc + 1
                end
              end, 0, lists:seq(0, 15)),
            RBin = integer_to_binary(Replaced),
            RateBin = list_to_binary(io_lib:format("~p", [Rate])),
            {reply, {text, <<"OK: shred-mod ", NBin/binary,
                             " rate=", RateBin/binary,
                             " replaced=", RBin/binary>>}, State};
        {reload_baseline} ->
            %% Force-load the typeful-cues baseline from ebin/. The
            %% Calypso server has just written + built a new
            %% Calypso.Generated.Session.purs, erlc'd the resulting
            %% .erl, and dropped the .beam in ebin/ — this reads it.
            %%
            %% BEAM keeps at most two versions of a module (current +
            %% one old). load_file does an implicit soft_purge of the
            %% old slot; if anything still references it, load fails
            %% with {error, not_purged}. We attempt soft_purge first
            %% (no kill) and fall back to a force purge (kills any
            %% process still running old code). For live-coding, that
            %% means voices using the old Session may be terminated
            %% and need re-arming — that's the trade-off for keeping
            %% fire-typeful idempotent.
            BaselineAtom = 'calypso_generated_session@ps',
            %% Also reload Studio (the rig declaration) so newly
            %% added devices / channels are picked up by the walker
            %% on the same > run that mentions them.  Without this,
            %% adding a channel to Studio.purs requires a manual
            %% purerl-tidal restart even though the .beam is on disk —
            %% Erlang doesn't auto-reload, so a stale in-memory Studio
            %% silently masks the new exports.
            StudioAtom = 'studio@ps',
            _ = case code:soft_purge(StudioAtom) of
                    true -> ok;
                    false -> code:purge(StudioAtom)
                end,
            _ = code:load_file(StudioAtom),
            %% Voice wrappers — calypso_voices_*@ps — are also hot-reloaded
            %% here.  Without this, editing Calypso/Voices/Qd1.purs to point
            %% `armed` at a different part (qd1A vs qd1B) requires a full
            %% deepstar restart even though the .beam is on disk: BEAM keeps
            %% the old code cached, and subsequent `arm` calls hit the stale
            %% wrapper.  Note that this only refreshes the *exported* armed/0
            %% — running voice gen_servers that have already captured a
            %% Pattern fun still hold it; re-arming the voice is needed for
            %% them to pick up the new wrapper body.
            reload_voice_wrappers(),
            _ = case code:soft_purge(BaselineAtom) of
                    true -> ok;
                    false -> code:purge(BaselineAtom)
                end,
            case code:load_file(BaselineAtom) of
                {module, _} ->
                    %% Walk the freshly-loaded module's 0-arity exports
                    %% and register every MidiDevice / MidiNote it finds
                    %% with the dispatcher. After this, `arm` against a
                    %% typeful tvoice (e.g. `bass1`) resolves the binding
                    %% without separate Level-2 wire commands.
                    Summary =
                        case tidal_session_walker:walk_baseline() of
                            {ok, Stats} ->
                                D  = maps:get(devices, Stats, 0),
                                I  = maps:get(instruments, Stats, 0),
                                K  = maps:get(drumKits, Stats, 0),
                                CE = maps:get(claimErrors, Stats, 0),
                                PS = maps:get(selenes, Stats, 0),
                                PE = maps:get(seleneErrors, Stats, 0),
                                GR = maps:get(balistes, Stats, 0),
                                GRE = maps:get(balistesErrors, Stats, 0),
                                ConflictPart = case CE of
                                    0 -> <<>>;
                                    _ -> iolist_to_binary([
                                            ", ", integer_to_binary(CE),
                                            " claim-error(s)"])
                                end,
                                PolyPart = case {PS, PE} of
                                    {0, 0} -> <<>>;
                                    {_, 0} -> iolist_to_binary([
                                            ", ", integer_to_binary(PS),
                                            " selene(s)"]);
                                    _      -> iolist_to_binary([
                                            ", ", integer_to_binary(PS),
                                            " selene(s), ",
                                            integer_to_binary(PE),
                                            " polysignal-error(s)"])
                                end,
                                BalistesPart = case {GR, GRE} of
                                    {0, 0} -> <<>>;
                                    {_, 0} -> iolist_to_binary([
                                            ", ", integer_to_binary(GR),
                                            " balistes voice(s)"]);
                                    _      -> iolist_to_binary([
                                            ", ", integer_to_binary(GR),
                                            " balistes voice(s), ",
                                            integer_to_binary(GRE),
                                            " balistes-error(s)"])
                                end,
                                iolist_to_binary([
                                    " (",
                                    integer_to_binary(D), " device(s), ",
                                    integer_to_binary(I), " instrument(s), ",
                                    integer_to_binary(K), " drum kit(s)",
                                    PolyPart,
                                    BalistesPart,
                                    ConflictPart,
                                    ")"]);
                            {error, _} ->
                                <<>>
                        end,
                    Reply = {text,
                             <<"OK: reload-baseline", Summary/binary>>},
                    {reply, Reply, State};
                {error, LoadErr} ->
                    ErrBin = list_to_binary(
                        io_lib:format("~p", [LoadErr])),
                    Reply = {text,
                             <<"ERR reload-baseline: ", ErrBin/binary>>},
                    {reply, Reply, State}
            end;
        {dump_odonus_samples, VoiceName} ->
            %% Pull the timing-sample buffer out of an instrumented
            %% odonus_voice gen_server and format as CSV.  See
            %% [[project_timing_jitter_investigation_queued]] for the
            %% analysis pipeline downstream.
            try
                Samples = odonus_voice:get_samples(VoiceName),
                Rows = [io_lib:format(
                          "~p,~B,~B,~B,~B,~B~n",
                          [NowUs, TRecv, TEvalDone, TRefreshDone,
                           TEmitDone, WallUs])
                        || {NowUs, TRecv, TEvalDone, TRefreshDone,
                            TEmitDone, WallUs}
                            <- lists:reverse(Samples)],
                Header = <<"NowUs,TRecv,TEvalDone,TRefreshDone,TEmitDone,WallUs\n">>,
                Body = iolist_to_binary([Header | Rows]),
                {reply,
                 {text, <<"OK: dump-odonus-samples ", VoiceName/binary, " ",
                          (integer_to_binary(length(Samples)))/binary,
                          " rows\n", Body/binary>>},
                 State}
            catch _:Err ->
                ErrBin = list_to_binary(io_lib:format("~p", [Err])),
                {reply,
                 {text, <<"ERR dump-odonus-samples: ", ErrBin/binary>>},
                 State}
            end;
        {clear_odonus_samples, VoiceName} ->
            try
                odonus_voice:clear_samples(VoiceName),
                {reply,
                 {text, <<"OK: clear-odonus-samples ", VoiceName/binary>>},
                 State}
            catch _:Err ->
                ErrBin = list_to_binary(io_lib:format("~p", [Err])),
                {reply,
                 {text, <<"ERR clear-odonus-samples: ", ErrBin/binary>>},
                 State}
            end;
        {dump_anchor_log} ->
            %% Drain the anchor-log ring buffer as CSV.  Three event
            %% kinds today (anchor_rx / clock_transition / voice_dropout);
            %% the format column tells the consumer how to parse the rest.
            try
                Entries = tidal_anchor_log:dump(),
                Rows = [io_lib:format("~B,~B,~p~n", [Seq, NowUs, Event])
                        || {Seq, NowUs, Event} <- Entries],
                Header = <<"Seq,NowUs,Event\n">>,
                Body = iolist_to_binary([Header | Rows]),
                {reply,
                 {text, <<"OK: dump-anchor-log ",
                          (integer_to_binary(length(Entries)))/binary,
                          " rows\n", Body/binary>>},
                 State}
            catch _:DErr ->
                ErrBin = list_to_binary(io_lib:format("~p", [DErr])),
                {reply,
                 {text, <<"ERR dump-anchor-log: ", ErrBin/binary>>},
                 State}
            end;
        {clear_anchor_log} ->
            tidal_anchor_log:clear(),
            {reply, {text, <<"OK: clear-anchor-log">>}, State};
        {play_piece, Name} ->
            %% Hand the named Pattern AnyPart value to the conductor.
            %% The conductor resolves it via
            %%   calypso_generated_session@ps:<Name>/0
            %% and on each subsequent clock tick fires arms for the
            %% events whose `whole.start` lands in the new window.
            case tidal_conductor:play_piece(Name) of
                {ok, _} ->
                    {reply,
                     {text, <<"OK: play-piece ", Name/binary>>},
                     State};
                {error, ErrBin} ->
                    {reply,
                     {text, <<"ERR play-piece: ", ErrBin/binary>>},
                     State}
            end;
        {stop_piece} ->
            ok = tidal_conductor:stop_piece(),
            {reply, {text, <<"OK: stop-piece">>}, State};
        {get_studio} ->
            %% Return the Studio snapshot captured by the most recent
            %% walk_baseline.  Calypso's Studio pane parses the
            %% tab-delimited payload — see studio_lines/0 in
            %% tidal_session_walker for the wire format.
            Lines = tidal_session_walker:studio_lines(),
            Body = case Lines of
                       [] -> <<>>;
                       _  -> iolist_to_binary([<<"\n">>,
                                lists:join(<<"\n">>, Lines)])
                   end,
            {reply,
             {text, iolist_to_binary([<<"OK: get-studio">>, Body])},
             State};
        {play_armed, MvoiceName, CueName} ->
            %% Install a typeful cue's body into the named mvoice's
            %% voice gen_server.  Pre-condition: the user has fired
            %% the composition pane at least once (reload-baseline
            %% loaded Calypso.Generated.Session and the walker
            %% registered devices + bindings for the named mvoices).
            %%
            %% Two routing paths:
            %%   - discrete binding (lookup_binding succeeds):
            %%       hand the Pattern String to set_voice_pat.
            %%   - continuous binding (lookup_continuous_binding):
            %%       fmap-parse Pattern String → Pattern Number via
            %%       Tidal.Pattern.Core.patternStringToNumber, then
            %%       hand to set_voice_cont_pat.  Tokens that don't
            %%       parse as a number become 0.0 (silence-equivalent
            %%       for CC / CV).
            %%
            %% Phase preserved across replacement (see Tidal.Voice).
            case resolve_cue_body(CueName) of
                {ok, Pat} ->
                    case tidal_dispatcher:lookup_binding(MvoiceName) of
                        {just, Binding} ->
                            case tidal_voice_sup:set_voice_pat(
                                   MvoiceName, Binding, Pat) of
                                ok ->
                                    Reply = {text,
                                             <<"OK: play-armed ",
                                               MvoiceName/binary, " ",
                                               CueName/binary>>},
                                    {reply, Reply, State};
                                {error, InstallErr} ->
                                    InstallBin = list_to_binary(
                                        io_lib:format("~p", [InstallErr])),
                                    Reply = {text,
                                             <<"ERR play-armed: install: ",
                                               InstallBin/binary>>},
                                    {reply, Reply, State}
                            end;
                        {nothing} ->
                            case tidal_dispatcher:lookup_continuous_binding(
                                   MvoiceName) of
                                {just, Dest} ->
                                    %% Typed cue body is Pattern Pitch;
                                    %% continuous voice wants Pattern
                                    %% Number.  Coerce per-event using
                                    %% Tidal.Pitch.patternPitchToNumber.
                                    NumPat = ('tidal_pitch@ps':
                                                patternPitchToNumber())(Pat),
                                    case tidal_voice_sup:set_voice_cont_pat(
                                           MvoiceName, Dest, NumPat) of
                                        ok ->
                                            Reply = {text,
                                                     <<"OK: play-armed ",
                                                       MvoiceName/binary, " ",
                                                       CueName/binary>>},
                                            {reply, Reply, State};
                                        {error, InstallErr} ->
                                            InstallBin = list_to_binary(
                                                io_lib:format("~p", [InstallErr])),
                                            Reply = {text,
                                                     <<"ERR play-armed: install: ",
                                                       InstallBin/binary>>},
                                            {reply, Reply, State}
                                    end;
                                {nothing} ->
                                    Reply = {text,
                                             <<"ERR play-armed: no binding for '",
                                               MvoiceName/binary,
                                               "'.  Fire the composition first "
                                               "(> run) so the Session walker "
                                               "can register channels.">>},
                                    {reply, Reply, State}
                            end
                    end;
                {error, ErrBin} ->
                    Reply = {text,
                             <<"ERR play-armed: ", ErrBin/binary>>},
                    {reply, Reply, State}
            end;
        {alias_recorded, Verb, Alias, Detail} ->
            %% Composition-grammar device verbs that don't back a
            %% legacy MIDI device (es9 / es5 / esx-* / fhx-* / osc).
            %% The ETS write happened in try_parse_prefixed; this
            %% arm only crafts the OK reply.
            DetailBin = format_alias_detail(Detail),
            Reply = {text, <<"OK: ", Verb/binary, " ", Alias/binary,
                             " ", DetailBin/binary>>},
            {reply, Reply, State};
        {routing_error, Verb, Reason} ->
            Reply = {text, <<"ERR: ", Verb/binary, ": ", Reason/binary>>},
            {reply, Reply, State};
        none ->
            %% Not a built-in verb. Per the architectural-bet doc, the
            %% bare-binding-name wire-protocol dispatch (path 4) and the
            %% `:<expr>` host-language operator (path 2) are gone.
            %% Music cells flow through `cue <body>` + `play-armed
            %% <tvoice> <module>` instead — Calypso wraps non-verb cells
            %% at fire time. Unknown input here reaches the user as a
            %% concrete error rather than a silent swallow.
            Reply = {text, <<"ERROR: not a verb -- wrap the cell in `cue` "
                             "and dispatch via `play-armed`. (Bare-binding "
                             "and `:expr` dispatch were retired.)">>},
            {reply, Reply, State}
    end.

%% Run one block of Tidal (Tidal.Line) and say what happened, as the reply
%% frame. A refusal names its reason; nothing half-runs.
tidal_line(Block) ->
    case machine_hush(Block) of
        {hush, Machine} -> hush_machine(Machine);
        none -> machine_line(Block)
    end.

%% `<machine> $ hush`: silence one machine, and tell its page through the
%% stage. Its page starts it again (entering Rig, pressing play), or for
%% drums and Conspicillum, the next line written.
machine_hush(Block) ->
    case re:run(Block, <<"^\\s*(odonus|vetula|balistes|drums|conspicillum)\\s*\\$\\s*hush\\s*$">>,
                [{capture, all_but_first, binary}]) of
        {match, [Machine]} -> {hush, Machine};
        nomatch -> none
    end.

hush_machine(<<"odonus">>) ->
    [gen_server:cast(Pid, hush) || Pid <- odonus_voice_sup:which_voices()],
    catch reef_voice:stop(),
    catch tidal_stage:stopped(odonus),
    <<"OK: odonus hushed">>;
hush_machine(<<"vetula">>) ->
    catch vetula_cards:stop(),
    catch reef_vetula_voice:stop(),
    catch reef_vetula_brush:stop(),
    catch tidal_stage:stopped(vetula),
    <<"OK: vetula hushed">>;
hush_machine(<<"balistes">>) ->
    catch reef_balistes_voice:stop(),
    catch tidal_stage:stopped(balistes),
    <<"OK: balistes hushed">>;
hush_machine(<<"drums">>) ->
    case whereis(tidal_dirt_voice:registered_name(drums)) of
        undefined -> ok;
        Pid -> gen_server:call(Pid, {set_pattern, 'tidal_pattern_types@ps':silence()})
    end,
    <<"OK: drums hushed">>;
hush_machine(<<"conspicillum">>) ->
    catch reef_conspicillum_voice:stop(),
    catch tidal_stage:stopped(conspicillum),
    <<"OK: conspicillum hushed">>.

%% A block may hold several machine lines (`odonus $ loop` then `odonus $
%% slide "<0 -1>"`, with no blank line between): each line that starts with
%% a machine's name at the margin begins a statement, indented lines continue
%% it (a recall's `{ … }`), and each statement runs in turn.
machine_line(Block) ->
    case machine_statements(Block) of
        [One] -> machine_statement(One);
        Many -> iolist_to_binary(lists:join(<<"\n">>, [machine_statement(S) || S <- Many]))
    end.

machine_statements(Block) ->
    Lines = binary:split(string:trim(Block), <<"\n">>, [global]),
    Heads = [<<"odonus">>, <<"vetula">>, <<"drums">>, <<"conspicillum">>, <<"balistes">>],
    Starts = fun(L) -> lists:any(fun(H) -> starts_word(L, H) end, Heads) end,
    Groups = lists:foldl(
               fun(L, []) -> [[L]];
                  (L, [Cur | Rest]) ->
                       case Starts(L) of
                           true -> [[L], Cur | Rest];
                           false -> [[L | Cur] | Rest]
                       end
               end, [], Lines),
    [iolist_to_binary(lists:join(<<"\n">>, lists:reverse(G))) || G <- lists:reverse(Groups)].

starts_word(Line, Head) ->
    N = byte_size(Head),
    case Line of
        <<Head:N/binary>> -> true;
        <<Head:N/binary, C, _/binary>> -> C =:= $\s orelse C =:= $$;
        _ -> false
    end.

machine_statement(Block) ->
    case string:trim(Block, leading) of
        <<"odonus", _/binary>> = Line ->
            case review_cue(Line) of
                none ->
                    case cue_word(Line) of
                        true -> <<"ERR: odonus: a cue line is mark, loop [N | off], slide / widen / narrow N or \"PATTERN\" or off, chained with # (moves go on a line of their own)">>;
                        false -> odonus_line(Line)
                    end;
                Cue -> send_cue(Cue)
            end;
        <<"vetula", _/binary>> = Line ->
            case review_cue(Line) of
                none -> <<"ERR: vetula: a vetula line is a cue (mark, loop, loop N, loop off); a card is v3 $ ... (Limulus writes cards to the stage)">>;
                Cue -> send_cue(Cue)
            end;
        <<"drums", Rest/binary>> -> drums_line(Rest);
        <<"conspicillum", _/binary>> ->
            <<"ERR: conspicillum: its line goes through the stage (Limulus writes conspicillum/line); here only conspicillum $ hush">>;
        <<"balistes", _/binary>> ->
            <<"ERR: balistes: only balistes $ hush, so far">>;
        _ -> tidal_pattern_line(Block)
    end.

%% `drums $ <control pattern>`: Tidal, played on the drum kit. The pattern is
%% read as `d1`'s would be and installed on the `drums` stream, which turns
%% each event into a hit on the lane its `s` names (Tidal.DrumVoice) and plays
%% it through the drum routing table (reef_balistes_voice:play_hit). `hush`
%% silences it with the `d` streams.
drums_line(Rest) ->
    case string:trim(Rest, leading) of
        <<"$", Body/binary>> ->
            try ('tidal_line@ps':parseLine(<<"d1 $ ", Body/binary>>)) of
                {right, {play, _, Pattern}} ->
                    case tidal_dirt_voice_sup:set(drums, Pattern) of
                        ok -> <<"OK: drums">>;
                        Err -> iolist_to_binary(io_lib:format("ERR: drums: ~p", [Err]))
                    end;
                {left, Reason} -> <<"ERR: drums: ", Reason/binary>>;
                _ -> <<"ERR: drums: a drums line is drums $ <pattern>">>
            catch
                Class:Why -> iolist_to_binary(io_lib:format("ERR: drums: ~p:~p", [Class, Why]))
            end;
        _ -> <<"ERR: drums: a drums line is drums $ <pattern>">>
    end.

%% Review cues (docs/kb/plans/text-on-the-stage.md, slice 2): time markers on
%% a machine's Review surface, and their loops, from the live-coding station.
%%   odonus $ mark        drop a mark now, as the surface's own mark control
%%   odonus $ loop 2      loop mark 2 (counting from 1) on the Review surface
%%   odonus $ loop        loop the latest mark
%%   odonus $ loop off    stop the loop
%%   odonus $ slide -1    move the loop window by bars (a fraction is fine)
%%   odonus $ widen 2     move its end later by bars; narrow N, earlier
%%                        (each acts on the mark looping, else the latest)
%% The marks and their notes live in the page, so the rig only relays the cue
%% to every page (`cue <json>`), and the page of that machine acts on it.
review_cue(Line) ->
    case binary:split(Line, <<" ">>) of
        [Head, Rest] when Head =:= <<"odonus">>; Head =:= <<"vetula">> ->
            Body = string:trim(case string:trim(Rest, leading) of
                                   <<"$", After/binary>> -> After;
                                   Other -> Other
                               end),
            case split_hashes(Body) of
                [_] -> one_cue(Head, Body);
                Parts ->
                    %% `loop # slide "<0 -1>"`: cues chain as moves do; all
                    %% of them must be cues, or the line is not one
                    Cues = [one_cue(Head, P) || P <- Parts],
                    case lists:member(none, Cues) of
                        true -> none;
                        false -> {many, Cues}
                    end
            end;
        _ -> none
    end.

%% Whether a machine line starts with a cue's word, so a malformed cue says
%% so rather than reading as a move.
cue_word(Line) ->
    case binary:split(Line, <<"$">>) of
        [_, Rest] ->
            case binary:split(string:trim(Rest), [<<" ">>, <<"#">>]) of
                [W | _] -> lists:member(W, [<<"mark">>, <<"loop">>, <<"slide">>, <<"widen">>, <<"narrow">>]);
                _ -> false
            end;
        _ -> false
    end.

%% Split at `#` outside double quotes, each part trimmed.
split_hashes(Body) ->
    split_hashes(binary_to_list(Body), false, [], []).
split_hashes([], _, Cur, Acc) ->
    lists:reverse([trim_part(Cur) | Acc]);
split_hashes([$" | T], Q, Cur, Acc) ->
    split_hashes(T, not Q, [$" | Cur], Acc);
split_hashes([$# | T], false, Cur, Acc) ->
    split_hashes(T, false, [], [trim_part(Cur) | Acc]);
split_hashes([C | T], Q, Cur, Acc) ->
    split_hashes(T, Q, [C | Cur], Acc).
trim_part(Rev) -> string:trim(list_to_binary(lists:reverse(Rev))).

one_cue(Head, Body) ->
            case Body of
                <<"mark">> -> {Head, #{cue => <<"mark">>}};
                <<"loop">> -> {Head, #{cue => <<"loop">>, n => 0}};
                <<"loop off">> -> {Head, #{cue => <<"stop">>}};
                <<"slide", By/binary>> -> window_cue(Head, <<"slide">>, By);
                <<"widen", By/binary>> -> window_cue(Head, <<"widen">>, By);
                <<"narrow", By/binary>> -> window_cue(Head, <<"narrow">>, By);
                <<"loop ", N/binary>> ->
                    case string:to_integer(string:trim(N)) of
                        {I, <<>>} when I >= 1 -> {Head, #{cue => <<"loop">>, n => I}};
                        _ -> none
                    end;
                _ -> none
            end.

%% A window cue's count of bars: a number, default 1; or a pattern of them
%% in quotes (`slide "<0 -1 -2>"`, bars from where the mark was made), which
%% window_patterns follows; or `off`, to stop following it.
window_cue(Head, Kind, ByBin) ->
    case string:trim(ByBin) of
        <<>> -> {Head, #{cue => Kind, by => 1.0}};
        <<"off">> when Kind =/= <<"narrow">> -> {pattern, Head, Kind, off};
        <<"\"", _/binary>> = Q when Kind =/= <<"narrow">> ->
            case string:trim(Q, both, "\"") of
                <<>> -> none;
                Text -> {pattern, Head, Kind, Text}
            end;
        B ->
            case parse_number(B) of
                {ok, N} -> {Head, #{cue => Kind, by => N}};
                error -> none
            end
    end.

send_cue({many, Cues}) ->
    iolist_to_binary(lists:join(<<"\n">>, [send_cue(C) || C <- Cues]));
send_cue({pattern, Slot, Kind, off}) ->
    window_patterns:set(Slot, Kind, off),
    <<"OK: ", Slot/binary, " ", Kind/binary, " follows no pattern">>;
send_cue({pattern, Slot, Kind, Text}) ->
    case 'tidal_window@ps':checkWindow(Text) of
        {left, Why} -> <<"ERR: ", Slot/binary, ": ", Why/binary>>;
        {right, _} ->
            window_patterns:set(Slot, Kind, Text),
            <<"OK: ", Slot/binary, " ", Kind/binary, " follows \"", Text/binary, "\" (bars from the mark, each beat)">>
    end;
send_cue({Slot, Cue}) ->
    Json = iolist_to_binary(json:encode(Cue#{slot => Slot})),
    tidal_link_anchor:sync_broadcast(<<"cue ", Json/binary>>),
    Say = case Cue of
              #{cue := <<"mark">>} -> <<"mark dropped">>;
              #{cue := <<"loop">>, n := 0} -> <<"looping the latest mark">>;
              #{cue := <<"loop">>, n := N} -> iolist_to_binary(io_lib:format("looping mark ~p", [N]));
              #{cue := <<"stop">>} -> <<"loop stopped">>;
              #{cue := K, by := By} -> iolist_to_binary(io_lib:format("~s ~p bars", [K, By]))
          end,
    <<"OK: ", Slot/binary, " ", Say/binary, " (on its Review surface, if the page is open)">>.

%% Odonus's patterns sampled for a page that plays it itself (Solo), as
%% reef_voice samples them for its own voice: the same samplers, at the same
%% place in the cycle (step N is N * quarters sixteenths of a four-beat
%% cycle), through the same Reef.Engine.samplePatterns. The request:
%%   {"key": K, "from": N, "count": C, "quarters": Q,
%%    "harmony": T|null, "scale": T|null, "outScale": {"pattern": T, "root": R}|null}
%% The reply, to that page alone, one SetSampled a step from N:
%%   odonus-samples {"key": K, "from": N, "inputs": [<input>, ...]}
odonus_samples(Json) ->
    try json:decode(Json) of
        #{<<"from">> := From, <<"count">> := Count, <<"quarters">> := Q} = Req
          when is_integer(From), is_integer(Count), Count > 0, Count =< 256, is_integer(Q) ->
            Opt = fun(K) -> case maps:get(K, Req, null) of
                                null -> {nothing};
                                V -> {just, V}
                            end
                  end,
            Out = case maps:get(<<"outScale">>, Req, null) of
                      #{<<"pattern">> := P, <<"root">> := R} -> {just, #{pattern => P, root => R}};
                      _ -> {nothing}
                  end,
            Patterns = #{harmony => Opt(<<"harmony">>), scale => Opt(<<"scale">>), outScale => Out},
            Inputs = [begin
                          Pos = Step * Q,
                          H = fun(T) -> 'tidal_harmony@ps':harmonySampler(Pos, 16, T) end,
                          S = fun(T) -> 'tidal_scales@ps':scaleSampler(Pos, 16, T) end,
                          'reef_protocol@ps':encodeInput(('reef_engine@ps':samplePatterns(H, S, Patterns)))
                      end || Step <- lists:seq(From, From + Count - 1)],
            Key = json:encode(maps:get(<<"key">>, Req, <<>>)),
            iolist_to_binary([<<"odonus-samples {\"key\":">>, Key,
                              <<",\"from\":">>, integer_to_binary(From),
                              <<",\"inputs\":[">>, lists:join(<<",">>, Inputs), <<"]}">>]);
        _ ->
            <<"ERR: odonus-sample: want {key, from, count (1-256), quarters, harmony, scale, outScale}">>
    catch
        Class:Why ->
            iolist_to_binary(io_lib:format("ERR: odonus-sample: ~p:~p", [Class, Why]))
    end.

%% A move on the Odonus voice: parsed by the shared Reef.Move, applied by
%% reef_voice on its next step (and restored after n bars, for `for n`).
odonus_line(Line) ->
    try 'reef_move@ps':parse(Line) of
        {left, Reason} ->
            <<"ERR: odonus: ", Reason/binary>>;
        {right, Move} ->
            case {whereis(reef_voice), unreadable_harmony(Move)} of
                {_, {bad, Why}} ->
                    <<"ERR: odonus: ", Why/binary>>;
                {undefined, ok} ->
                    <<"ERR: odonus: no Odonus voice is running (start Odonus from Triggerfish)">>;
                {Pid, ok} ->
                    Pid ! {move, Move},
                    N = array:size('reef_move@ps':inputsOf(Move)),
                    iolist_to_binary(io_lib:format("OK: odonus (~p gestures)", [N]))
            end
    catch
        Class:Why ->
            iolist_to_binary(io_lib:format("ERR: odonus: ~p:~p", [Class, Why]))
    end.

%% **Harmony routes** (Reef.Route, docs/kb/plans/matrix-router.md): what
%% feeds Odonus's grid and output, kept on the stage as `routing/harmony`, one
%% route a line. Unlike the pages' objects the rig reads this one: a write is
%% parsed and its patterns checked before it is kept (a refusal leaves the
%% table as it was). Keeping it is all this does: `odonus_feeds` hears the
%% write and moves Odonus (it also knows Vetula's key and cards, which the
%% Vetula rows need). The canonical text is announced to every page, the
%% writer too, so all views spell it alike.
apply_routes(Body) ->
    Text = case Body of null -> <<>>; _ -> Body end,
    try 'reef_route@ps':parse(Text) of
        {left, Why} -> <<"ERR: routing: ", Why/binary>>;
        {right, New} ->
            Move = {gestures, 'reef_route@ps':odonusInputs(current_routes(), New)},
            case unreadable_harmony(Move) of
                {bad, Why} -> <<"ERR: routing: ", Why/binary>>;
                ok ->
                    Canon = case array:size(New) of
                                0 -> null;
                                _ -> 'reef_route@ps':print(New)
                            end,
                    tidal_stage:put_text(<<"routing/harmony">>, Canon, rig),
                    iolist_to_binary(io_lib:format("OK: routing (~p routes)", [array:size(New)]))
            end
    catch
        Class:Why -> iolist_to_binary(io_lib:format("ERR: routing: ~p:~p", [Class, Why]))
    end.

current_routes() ->
    case tidal_stage:get_text(<<"routing/harmony">>) of
        T when is_binary(T) ->
            case 'reef_route@ps':parse(T) of
                {right, R} -> R;
                _ -> array:new()
            end;
        _ -> array:new()
    end.

%% A starting Odonus voice takes everything that feeds it: routes written
%% while none was running reached nothing.
routes_to_voice(Pid) ->
    odonus_feeds:to_voice(Pid).

%% A `harmony "..."` or `scale "..."` pattern is read by Littorina on each
%% step, which treats one it cannot read as a rest; refuse it here instead,
%% with Tidal's reason (or, for a scale, the names it does not know).
unreadable_harmony(Move) ->
    Texts = [{Tag, T} || I <- array:to_list('reef_move@ps':inputsOf(Move)),
                  #{tag := Tag, txt := {just, T}} <- ['reef_input@ps':toWire(I)],
                  Tag =:= <<"SetHarmony">> orelse Tag =:= <<"SetScalePattern">> orelse Tag =:= <<"SetOutScale">>],
    lists:foldl(fun({Tag, T}, ok) ->
                        Check = case Tag of
                                    <<"SetHarmony">> -> 'tidal_harmony@ps':checkHarmony(T);
                                    _ -> 'tidal_scales@ps':checkScalePattern(T)
                                end,
                        case Check of
                            {left, Why} -> {bad, Why};
                            {right, _} -> ok
                        end;
                   (_, Bad) -> Bad
                end, ok, Texts).

tidal_pattern_line(Block) ->
    try ('tidal_line@ps':parseLine(Block)) of
        {right, {play, N, Pattern}} ->
            case tidal_dirt_voice_sup:set(N, Pattern) of
                ok -> <<"OK: d", (integer_to_binary(N))/binary>>;
                Err -> iolist_to_binary(io_lib:format("ERR: d~p: ~p", [N, Err]))
            end;
        {right, {hush}} ->
            hush_everything(),
            <<"OK: hush (everything)">>;
        {right, {setCps, Cps}} ->
            Bpm = Cps * 240.0,
            tidal_clock:set_bpm(Bpm),
            tidal_dispatcher:set_link_tempo(Bpm),
            iolist_to_binary(io_lib:format("OK: setcps ~p (bpm ~p)", [Cps, Bpm]));
        {left, Reason} ->
            <<"ERR: ", Reason/binary>>
    catch
        Class:Why ->
            iolist_to_binary(io_lib:format("ERR: ~p:~p", [Class, Why]))
    end.

%% Wrap the Tidal parser in try/catch so any uncaught exception
%% (e.g. Data.String.split blowing up on incomplete UTF-8) becomes
%% a graceful {parse_err, Reason} instead of crashing the scheduler.
%% The parser returns Either-shaped {right, _} | {left, _}, so we
%% also surface Left as parse_err.
safe_parse(Text) ->
    try
        case ('tidal_parse_parser@ps':parse())(Text) of
            {right, _} -> {ok, ok};
            {left, Err} ->
                {parse_err, list_to_binary(io_lib:format("~p", [Err]))}
        end
    catch
        Class:Reason ->
            {parse_err, list_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.


websocket_info({stage_broadcast, Bin}, State) ->
    %% A change on the stage made by another page (tidal_stage).
    {reply, {text, Bin}, State};
websocket_info({sync_broadcast, Bin}, State) ->
    %% A change the rig made that this page must follow in lockstep
    %% (tidal_link_anchor:sync_broadcast/1), e.g. an `odonus` move.
    {reply, {text, Bin}, State};
websocket_info({anchor_broadcast, Bin}, State) ->
    %% Forwarded Link anchor from tidal_link_anchor — push it to this
    %% subscribed browser client as a text frame (Atlantis Sync Protocol).
    {reply, {text, Bin}, State};
websocket_info(Info, State) ->
    io:format("WebSocket: Info: ~p~n", [Info]),
    {ok, State}.

%% Play one sample through SuperDirt, 50 ms from now (so the bundle lands
%% ahead of its timetag). Missing fields take a whole, forward, unit-gain play
%% on orbit 1, the drums' orbit.
dirt_audition(Json) ->
    try json:decode(Json) of
        #{<<"s">> := S} = V when is_binary(S) ->
            Num = fun(K, D) -> float(maps:get(K, V, D)) end,
            Msg = dirt_osc:encode_msg(<<"/dirt/play">>,
                    [ <<"s">>, S
                    , <<"n">>, Num(<<"n">>, 0)
                    , <<"orbit">>, round(maps:get(<<"orbit">>, V, 1))
                    , <<"begin">>, Num(<<"begin">>, 0)
                    , <<"end">>, Num(<<"end">>, 1)
                    , <<"speed">>, Num(<<"speed">>, 1)
                    , <<"gain">>, Num(<<"gain">>, 1)
                    ]),
            {ok, Sock} = gen_udp:open(0, [binary]),
            dirt_osc:send_at(Sock, erlang:system_time(microsecond) + 50000, Msg),
            gen_udp:close(Sock),
            ok;
        _ -> {error, <<"needs {\"s\": <set>, ...}">>}
    catch _:_ -> {error, <<"bad JSON">>}
    end.

%% The slots a page may set with stage-put. Conspicillum's is set by its
%% scene push instead.
stage_slot(<<"odonus">>) -> odonus;
stage_slot(<<"vetula">>) -> vetula;
stage_slot(<<"balistes">>) -> balistes;
stage_slot(<<"selene">>) -> selene;
stage_slot(_) -> undefined.

%% Split a scene push into the scene for the voice and what the stage
%% records. A push is either the scene itself or the envelope
%% {"scene": …, "base", "edited", "page", "by"}; anything unreadable goes to
%% the voice unchanged, to be refused there with its own error.
stage_envelope(Json) ->
    try json:decode(Json) of
        #{<<"scene">> := Scene} = Envelope ->
            {iolist_to_binary(json:encode(Scene)), maps:remove(<<"scene">>, Envelope)};
        _ ->
            {Json, #{}}
    catch _:_ ->
        {Json, #{}}
    end.

%% Sanitize a name from a WS verb argument to prevent path traversal
%% on filesystem operations (e.g. `load <name>` reads
%% `setup/<name>.tidal`). Only allows alphanumeric, dash, underscore.
sanitize_name(Name) when is_binary(Name) ->
    sanitize_name_loop(Name, <<>>).

sanitize_name_loop(<<>>, Acc) -> Acc;
sanitize_name_loop(<<C, Rest/binary>>, Acc) when
        (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $- orelse C =:= $_ ->
    sanitize_name_loop(Rest, <<Acc/binary, C>>);
sanitize_name_loop(<<_, Rest/binary>>, Acc) ->
    sanitize_name_loop(Rest, Acc).


%% ============================================================================
%% Load Setup File Handler
%% ============================================================================
%%
%% `load <name>` reads `setup/<name>.tidal` and evaluates each non-blank,
%% non-comment line as if it had been typed in the WS one at a time.
%% Useful for one-line "boot" of a device's full bind set:
%%   - load rample      → 44-line Rample MIDI vocabulary
%%   - load fh2-base    → standard FH-2 envelope farm
%%   - load show1-set1  → live-coded scene preset
%%
%% Comments use Tidal's `--` line-comment syntax (Haskell-derived).
%% Blank lines are ignored.
%%
%% Each line is parsed via the same try_parse_prefixed + dispatch logic
%% used by direct WS messages, so any verb (bind, midi-device, fh2-*,
%% rample-*, gate, cv, hush, even other `load` calls) works inside
%% setup files. Errors on individual lines are logged but don't abort
%% the load (best-effort — partial setup is more useful than none).

handle_load_setup(Name, State) ->
    case sanitize_name(Name) of
        <<>> ->
            Reply = {text, <<"ERROR: load - invalid name (alphanum/dash/underscore only)">>},
            {reply, Reply, State};
        SafeName ->
            FilePath = setup_file_path(SafeName),
            case file:read_file(FilePath) of
                {ok, Content} ->
                    Lines = binary:split(Content, <<"\n">>, [global]),
                    {Total, Skipped, Errors} = lists:foldl(
                        fun(Line, {T, S, E}) ->
                            Trimmed = trim_line(Line),
                            case classify_line(Trimmed) of
                                blank   -> {T, S + 1, E};
                                comment -> {T, S + 1, E};
                                code    ->
                                    case dispatch_setup_line(Trimmed) of
                                        ok    -> {T + 1, S, E};
                                        error -> {T + 1, S, E + 1}
                                    end
                            end
                        end,
                        {0, 0, 0},
                        Lines
                    ),
                    Summary = iolist_to_binary(io_lib:format(
                        "OK: load ~s - ~B lines fired (~B skipped, ~B errors)",
                        [SafeName, Total, Skipped, Errors])),
                    {reply, {text, Summary}, State};
                {error, enoent} ->
                    Msg = iolist_to_binary(io_lib:format(
                        "ERROR: load ~s - file not found at ~s",
                        [SafeName, FilePath])),
                    {reply, {text, Msg}, State};
                {error, Reason} ->
                    Msg = iolist_to_binary(io_lib:format(
                        "ERROR: load ~s - ~p", [SafeName, Reason])),
                    {reply, {text, Msg}, State}
            end
    end.

%% Resolve a setup name to a filesystem path. Relative to BEAM CWD,
%% which is typically purerl-tidal/ when started via `rebar3 shell`.
setup_file_path(SafeName) ->
    filename:join([?SETUP_DIR, <<SafeName/binary, ".tidal">>]).

%% Strip leading/trailing whitespace AND a trailing \r (for CRLF files).
%% Erlang binary patterns require a size on a /binary segment unless it's
%% the last in the pattern, so we use string:trim with the explicit char
%% set instead of pattern-matching for the \r.
trim_line(Line) ->
    string:trim(Line, both, "\r \t").

%% Classify a (trimmed) line as blank, comment, or code.
classify_line(<<>>) -> blank;
classify_line(<<"--", _/binary>>) -> comment;
classify_line(_) -> code.

%% Dispatch one line from a setup file. Mirrors handle_pattern_message
%% minus the WS replies, plus a "name + pattern" path for unprefixed
%% lines.
dispatch_setup_line(Line) ->
    case try_parse_prefixed(Line) of
        none ->
            %% Unprefixed line — treat as named-binding dispatch with
            %% optional `#` parameter joins.
            {Word, Rest, ParamSpecs} = parse_with_join(Line),
            case safe_parse(Rest) of
                {ok, _} ->
                    case tidal_dispatcher:lookup_binding(Word) of
                        {just, Binding} ->
                            case tidal_voice_sup:set_voice(
                                   Word, Binding, Rest, ParamSpecs) of
                                ok -> ok;
                                {error, Err} ->
                                    io:format("[load] install error on line ~s: ~p~n",
                                              [Line, Err]),
                                    error
                            end;
                        {nothing} ->
                            io:format("[load] no binding for '~s' on line: ~s~n",
                                      [Word, Line]),
                            error
                    end;
                {parse_err, _} ->
                    io:format("[load] parse error on line: ~s~n", [Line]),
                    error
            end;
        Action ->
            dispatch_setup_action(Action)
    end.

%% Run a parsed action against the same destinations
%% handle_pattern_message uses, minus the WS reply side. Add a clause
%% here whenever a new verb is added to handle_pattern_message that
%% should also work inside setup files.
dispatch_setup_action(Action) ->
    case Action of
        {midi_device, Alias, DeviceName, Latency} ->
            tidal_dispatcher:register_midi_device(Alias, DeviceName, Latency),
            ok;
        {bind, Name, ActionSpec} ->
            tidal_dispatcher:set_binding_from_spec(Name, ActionSpec),
            ok;
        {unbind, Name} ->
            tidal_dispatcher:remove_binding(Name),
            ok;
        {hush} ->
            tidal_voice_sup:hush_all(),
            ok;
        {load, Name} ->
            %% Recursive load — common pattern: a "scene" file that
            %% loads device packs first, then defines patterns.
            handle_load_setup(Name, #{}),
            ok;
        {fh2_gate, Voice, Output, Channel} ->
            %% Synchronous on the load path. fh2-config does a read-
            %% modify-write of the FH-2's full config blob; parallel
            %% invocations race and clobber each other (only the last
            %% writer's slot survives). Serialising here costs ~7s per
            %% gate but is the only way to reliably configure multiple
            %% MCVs in one `load`. The WS-direct path (handle_pattern_
            %% message) still spawns since one-off typing can't race.
            fh2_set_gate(Voice, Output, Channel),
            ok;
        {fh2_envelope, Voice, Output, Channel} ->
            tidal_dispatcher:set_fh2_voice_channel(Voice, Channel),
            fh2_set_envelope(Voice, Output, Channel),
            ok;
        {set_bpm, N} ->
            tidal_clock:set_bpm(N),
            tidal_dispatcher:set_link_tempo(N),
            ok;
        Other ->
            io:format("[load] verb not yet supported in setup files: ~p~n", [Other]),
            error
    end.

%% Shell out to fh2-config to push the per-MCV envelope routing to the
%% real FH-2 hardware. Synchronous within the spawned process (caller
%% spawn/1's it so the WS handler returns immediately). Logs the result
%% to stdout where the BEAM is running so failures aren't silent.
%%
%% The fh2-config binary lives at a known path; if you move it, update
%% here too. (Could be made configurable via app env later.)
fh2_set_envelope(Voice, Output, Channel) ->
    %% Composite --set-envelope-with-ccs (envelope routing + ADSR CCs in
    %% one config write).  Tries the fh2-config daemon first via Unix
    %% socket; falls back to `spago run -- --set-envelope-with-ccs ...`
    %% if no daemon is reachable.  Daemon path is sub-100ms; standalone
    %% is 5-10s per call.
    Cmd = iolist_to_binary(io_lib:format(
        "set-envelope-with-ccs ~B ~B ~B", [Voice, Output, Channel])),
    case fh2_daemon_call(Cmd) of
        {ok, Reply} ->
            io:format("[fh2-envelope daemon] voice=~B output=~B ch=~B: ~s~n",
                      [Voice, Output, Channel, Reply]);
        {error, _Reason} ->
            io:format("[fh2-envelope] no daemon, falling back to spago shell-out~n"),
            fh2_set_envelope_standalone(Voice, Output, Channel)
    end.

fh2_set_envelope_standalone(Voice, Output, Channel) ->
    Path = "/Users/afc/work/afc-work/music/expert-sleepers/fh2-config",
    Cmd = io_lib:format(
        "cd ~s && spago run -- --set-envelope-with-ccs ~B ~B ~B 2>&1",
        [Path, Voice, Output, Channel]),
    Output0 = os:cmd(lists:flatten(Cmd)),
    io:format("[fh2-envelope shell-out] voice=~B output=~B ch=~B done~n~ts~n",
              [Voice, Output, Channel, Output0]).

fh2_set_gate(Voice, Output, Channel) ->
    %% Gate-only MCV.  Routes to FH-2 main jacks (1-8), FHX-8CV (9-64),
    %% or FHX-8GT (65-128) automatically based on output number.  Tries
    %% the daemon first; falls back to spago shell-out otherwise.
    Cmd = iolist_to_binary(io_lib:format(
        "set-gate ~B ~B ~B", [Voice, Output, Channel])),
    case fh2_daemon_call(Cmd) of
        {ok, Reply} ->
            io:format("[fh2-gate daemon] voice=~B output=~B ch=~B: ~s~n",
                      [Voice, Output, Channel, Reply]);
        {error, _Reason} ->
            io:format("[fh2-gate] no daemon, falling back to spago shell-out~n"),
            fh2_set_gate_standalone(Voice, Output, Channel)
    end.

fh2_set_gate_standalone(Voice, Output, Channel) ->
    Path = "/Users/afc/work/afc-work/music/expert-sleepers/fh2-config",
    Cmd = io_lib:format(
        "cd ~s && spago run -- --set-gate ~B ~B ~B 2>&1",
        [Path, Voice, Output, Channel]),
    Output0 = os:cmd(lists:flatten(Cmd)),
    io:format("[fh2-gate shell-out] voice=~B output=~B ch=~B done~n~ts~n",
              [Voice, Output, Channel, Output0]).

%% Apply a polysignal: try the fh2-config daemon first via Unix socket
%% (sub-100ms); fall back to `spago run -- --apply-polysignal < tempfile`
%% if no daemon is reachable (~7s spago boot tax). Same `daemon-or-live`
%% pattern as fh2_set_envelope / fh2_set_gate.
%%
%% JsonBinary is what Calypso sent after the `polysignal ` prefix —
%% exactly the {bank, family, slots} envelope fh2-config expects on stdin
%% AND the payload the daemon's `apply-polysignal <json>` line accepts.
fh2_apply_polysignal(JsonBinary) ->
    %% Daemon line protocol: "apply-polysignal <json>\n". JSON is
    %% single-line (Calypso's polySignalEnvelopeJson emits it that way),
    %% so the line splitter on the daemon side won't fragment it.
    Cmd = iolist_to_binary([<<"apply-polysignal ">>, JsonBinary]),
    case fh2_daemon_call(Cmd) of
        {ok, Reply} ->
            io:format("[polysignal daemon] ~s~n", [Reply]);
        {error, _Reason} ->
            io:format("[polysignal] no daemon, falling back to spago shell-out~n"),
            fh2_apply_selene_standalone(JsonBinary)
    end.

%% --------------------------------------------------------------------
%% Balistes cell apply.  Parses the JSON envelope Calypso sends for a
%% `balistes` cell, builds a static BalistesConfig (`pure n` per slot) via
%% the PS helper, and either spawns a new voice under balistes_voice_sup
%% or pushes set_config into the existing one.
%% --------------------------------------------------------------------
apply_balistes_cell(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Alias       = maps:get(<<"alias">>,      Map, undefined),
            DeviceName  = maps:get(<<"deviceName">>, Map, <<"FH-2">>),
            Channel     = maps:get(<<"channel">>,    Map, 13),
            X           = maps:get(<<"x">>,          Map, 128),
            Y           = maps:get(<<"y">>,          Map, 128),
            FillBd      = maps:get(<<"fillBd">>,     Map, 128),
            FillSd      = maps:get(<<"fillSd">>,     Map, 128),
            FillHh      = maps:get(<<"fillHh">>,     Map, 128),
            Random      = maps:get(<<"randomness">>, Map, 0),
            Mode        = maps:get(<<"mode">>,       Map, 0),
            case Alias of
                undefined ->
                    {text, <<"ERR balistes: JSON missing alias field">>};
                _ ->
                    Cfg = 'tidal_balistes@ps':mkStaticBalistesConfig(
                            int_arg(X), int_arg(Y),
                            int_arg(FillBd), int_arg(FillSd), int_arg(FillHh),
                            int_arg(Random), int_arg(Mode)),
                    VoiceConfig = #{
                        port_name  => DeviceName,
                        channel    => int_arg(Channel),
                        note_bd    => 36,
                        note_sd    => 38,
                        note_hh    => 42,
                        vel        => 90,
                        vel_accent => 127,
                        dur_ms     => 30,
                        cfg        => Cfg
                    },
                    AliasAtom = binary_to_atom(Alias, utf8),
                    case balistes_voice_sup:lookup_voice(AliasAtom) of
                        undefined ->
                            case balistes_voice_sup:start_voice(AliasAtom, VoiceConfig) of
                                {ok, _Pid} ->
                                    {text, iolist_to_binary([
                                        <<"OK balistes ">>, Alias,
                                        <<" started on ">>, DeviceName,
                                        <<" ch">>, integer_to_binary(int_arg(Channel))
                                    ])};
                                {error, Reason} ->
                                    R = list_to_binary(io_lib:format("~p", [Reason])),
                                    {text, <<"ERR balistes start: ", R/binary>>}
                            end;
                        _Pid ->
                            balistes_voice:set_config(AliasAtom, Cfg),
                            {text, iolist_to_binary([
                                <<"OK balistes ">>, Alias, <<" updated">>
                            ])}
                    end
            end;
        Other ->
            R = list_to_binary(io_lib:format("~p", [Other])),
            {text, <<"ERR balistes: JSON not an object: ", R/binary>>}
    catch
        Class:What:_ST ->
            R = list_to_binary(io_lib:format("~p:~p", [Class, What])),
            {text, <<"ERR balistes: JSON parse failed: ", R/binary>>}
    end.

%% Coerce a JSON number (integer or float) into an Erlang integer.
int_arg(N) when is_integer(N) -> N;
int_arg(N) when is_float(N)   -> trunc(N);
int_arg(_)                    -> 0.

fh2_apply_selene_standalone(JsonBinary) ->
    Path = "/Users/afc/work/afc-work/music/expert-sleepers/fh2-config",
    %% Unique tempfile per call so concurrent fires don't clobber each
    %% other. Erlang's monotonic_time gives us nanosecond granularity.
    TmpFile = lists:flatten(
        io_lib:format("/tmp/polysignal-~B.json",
                      [erlang:system_time(microsecond)])),
    case file:write_file(TmpFile, JsonBinary) of
        ok -> ok;
        {error, WriteErr} ->
            io:format("[polysignal] tempfile write failed: ~p~n", [WriteErr]),
            erlang:error({selene_tempfile, WriteErr})
    end,
    Cmd = io_lib:format(
        "cd ~s && spago run -- --apply-polysignal < ~s 2>&1",
        [Path, TmpFile]),
    Output = os:cmd(lists:flatten(Cmd)),
    file:delete(TmpFile),
    %% os:cmd returns a codepoint list; fh2-config emits ✓/✗ Unicode
    %% chars whose codepoints (10003/10007) blow up list_to_binary.
    %% unicode:characters_to_binary/2 handles UTF-8 encoding properly.
    case unicode:characters_to_binary(Output, utf8) of
        Bin when is_binary(Bin) ->
            case binary:match(Bin, <<"✓"/utf8>>) of
                nomatch -> io:format("[polysignal] FAILED:~n~ts~n", [Output]);
                _       -> io:format("[polysignal] applied:~n~ts~n", [Output])
            end;
        _ ->
            io:format("[polysignal] output (undecodable):~n~ts~n", [Output])
    end.

%% --- fh2-config daemon client ---------------------------------------
%% Single round-trip Unix-socket client.  Matches fh2-config's daemon
%% protocol: send one line, read one newline-terminated reply, close.
%% Returns {ok, ReplyBinary} on success, {error, Reason} on failure
%% (including ENOENT when no daemon is listening).

%% =========================================================================
%% Composition-grammar verb helpers (Calypso routing grammar).
%% =========================================================================

%% Tokenize a binary into whitespace-separated tokens, with `"..."`
%% blocks treated as single tokens (quotes stripped).  Powers all the
%% new-grammar verb parsers since legacy `binary:split <" ">` doesn't
%% cope with the multi-space alignment users will write
%% (`midi      live    "IAC Driver Tidal"`).
%% --- Direct OSC relay to es9-daemon (Atlantis Sync Protocol output) ----
%% Self-contained minimal OSC encoder + sender so the fire-at / cv-out /
%% cv-slew verbs can reach es9-daemon (127.0.0.1:57130) without coupling
%% to the dispatcher's gate config or tidal_oSC's hardcoded gate-bus math.
%% Fresh socket per send (matching tidal_oSC's *After helpers — a
%% long-lived socket silently dies across es9-daemon restarts).
%% Port moved 57120 → 57130 (workstream C) with the rest of the es9 path.
es9_relay(Address, Args) ->
    case gen_udp:open(0, [binary]) of
        {ok, Socket} ->
            Msg = es9_osc_encode(Address, Args),
            gen_udp:send(Socket, {127,0,0,1}, 57130, Msg),
            gen_udp:close(Socket);
        _ ->
            ok
    end.

es9_osc_encode(Address, Args) ->
    PaddedAddr = es9_osc_pad(Address),
    {TypeTag, Encoded} = es9_osc_args(Args, <<>>, <<>>),
    PaddedTag = es9_osc_pad(<<",", TypeTag/binary>>),
    <<PaddedAddr/binary, PaddedTag/binary, Encoded/binary>>.

es9_osc_args([], Tag, Enc) -> {Tag, Enc};
es9_osc_args([A | Rest], Tag, Enc) when is_integer(A) ->
    es9_osc_args(Rest, <<Tag/binary, "i">>,
                 <<Enc/binary, A:32/big-signed-integer>>);
es9_osc_args([A | Rest], Tag, Enc) when is_float(A) ->
    es9_osc_args(Rest, <<Tag/binary, "f">>, <<Enc/binary, A:32/float>>).

%% Pad a binary to a 4-byte boundary with a null terminator (OSC rule).
es9_osc_pad(Bin) ->
    Len = byte_size(Bin) + 1,
    Pad = (4 - (Len rem 4)) rem 4,
    <<Bin/binary, 0:8, 0:(Pad*8)>>.

ws_tokens(Bin) -> ws_tokens(Bin, []).

ws_tokens(<<>>, Acc) -> lists:reverse(Acc);
ws_tokens(<<C, Rest/binary>>, Acc) when C =:= $\s; C =:= $\t;
                                          C =:= $\r; C =:= $\n ->
    ws_tokens(Rest, Acc);
ws_tokens(<<$", Rest/binary>>, Acc) ->
    {Tok, Rest2} = ws_read_quoted(Rest, <<>>),
    ws_tokens(Rest2, [Tok | Acc]);
ws_tokens(Bin, Acc) ->
    {Tok, Rest} = ws_read_bare(Bin, <<>>),
    ws_tokens(Rest, [Tok | Acc]).

ws_read_quoted(<<>>, Acc) -> {Acc, <<>>};
ws_read_quoted(<<$", Rest/binary>>, Acc) -> {Acc, Rest};
ws_read_quoted(<<C, Rest/binary>>, Acc) ->
    ws_read_quoted(Rest, <<Acc/binary, C>>).

ws_read_bare(<<>>, Acc) -> {Acc, <<>>};
ws_read_bare(<<C, _/binary>> = Bin, Acc) when C =:= $\s; C =:= $\t;
                                                C =:= $\r; C =:= $\n ->
    {Acc, Bin};
ws_read_bare(<<C, Rest/binary>>, Acc) ->
    ws_read_bare(Rest, <<Acc/binary, C>>).

%% Try to parse an integer-valued binary.  Uses the same approach as
%% parse_number above but constrained to integers.
parse_int(Bin) ->
    try {ok, binary_to_integer(trim_binary(Bin))}
    catch error:badarg -> error end.

%% Strip an optional trailing `latency N` from a token list, returning
%% {LeadingTokens, LatFloat}.  Lat default 0.0.
peel_latency_suffix(Tokens) ->
    case lists:reverse(Tokens) of
        [LatVal, <<"latency">> | Rest] ->
            case parse_number(LatVal) of
                {ok, N} -> {lists:reverse(Rest), N};
                error -> {Tokens, 0.0}
            end;
        _ -> {Tokens, 0.0}
    end.

%% Insert / overwrite an alias-type record.
register_alias(Alias, Type, Parent, Detail) ->
    ets:insert(tidal_alias_types, {Alias, Type, Parent, Detail}).

%% Look up an alias-type record.  Returns `{ok, Type, Parent, Detail}`
%% or `not_found`.
alias_type(Alias) ->
    case ets:lookup(tidal_alias_types, Alias) of
        [{Alias, Type, Parent, Detail}] -> {ok, Type, Parent, Detail};
        [] -> not_found
    end.

%% Format a Detail map for the {alias_recorded, ...} reply text.
format_alias_detail(Detail) when is_map(Detail) ->
    Pairs = [io_lib:format("~s=~s",
                           [atom_to_list(K), format_detail_value(V)])
             || {K, V} <- maps:to_list(Detail)],
    list_to_binary(string:join(Pairs, " "));
format_alias_detail(_) -> <<>>.

format_detail_value(V) when is_binary(V) -> binary_to_list(V);
format_detail_value(V) when is_integer(V) -> integer_to_list(V);
format_detail_value(V) when is_atom(V) -> atom_to_list(V);
format_detail_value(V) -> io_lib:format("~p", [V]).

%% --- Device verb parsers --------------------------------------------

%% Root device with a MIDI port: `<verb> <alias> "<port>" [latency N]`.
%% Records the alias type in ETS and returns a `{midi_device, ...}`
%% tuple so the existing dispatch arm registers the underlying MIDI
%% device alias for sendmidi.
parse_root_device_verb(Type, Rest) ->
    Tokens = ws_tokens(Rest),
    {Lead, Lat} = peel_latency_suffix(Tokens),
    case Lead of
        [Alias, Port] when Alias =/= <<>>, Port =/= <<>> ->
            register_alias(Alias, Type, undefined, #{port => Port}),
            {midi_device, Alias, Port, Lat};
        _ -> none
    end.

%% es9: alias only — es9-daemon talks to the ES-9 directly via
%% CoreAudio, not MIDI, so no midi-device backing.  Form:
%% `es9 <alias> "<port-name>"`.
parse_es9_verb(Rest) ->
    case ws_tokens(Rest) of
        [Alias, Port] when Alias =/= <<>>, Port =/= <<>> ->
            register_alias(Alias, es9, undefined, #{port => Port}),
            {alias_recorded, <<"es9">>, Alias, #{port => Port}};
        _ -> none
    end.

%% Expander: `<type> <alias> on <parent>`.  Just records the alias →
%% parent relationship; later gate/cv bindings consult it to figure
%% out the legacy output / channel they should fire.
parse_expander_verb(TypeAtom, VerbBin, Rest) ->
    case ws_tokens(Rest) of
        [Alias, <<"on">>, Parent] when Alias =/= <<>>, Parent =/= <<>> ->
            register_alias(Alias, TypeAtom, Parent, #{}),
            {alias_recorded, VerbBin, Alias, #{parent => Parent}};
        _ -> none
    end.

%% osc: `osc <alias> host=<host> port=<int>`.  Recorded for
%% completeness; current dispatch doesn't use OSC devices yet.
parse_osc_verb(Rest) ->
    case ws_tokens(Rest) of
        [Alias, HostKv, PortKv] ->
            case {parse_kv_string(<<"host">>, HostKv),
                  parse_kv_int(<<"port">>, PortKv)} of
                {{ok, Host}, {ok, Port}} ->
                    Detail = #{host => Host, port => Port},
                    register_alias(Alias, osc, undefined, Detail),
                    {alias_recorded, <<"osc">>, Alias, Detail};
                _ -> none
            end;
        _ -> none
    end.

%% Parse a `key=value` token where value is a string.  Returns
%% `{ok, ValueBin}` or `error`.
parse_kv_string(Key, Bin) ->
    Prefix = <<Key/binary, "=">>,
    case binary:split(Bin, Prefix) of
        [<<>>, Val] when Val =/= <<>> -> {ok, Val};
        _ -> error
    end.

parse_kv_int(Key, Bin) ->
    case parse_kv_string(Key, Bin) of
        {ok, Val} -> parse_int(Val);
        error -> error
    end.

%% --- Device-internal config: fh2-config -----------------------------

%% `fh2-config <alias>:<mode> voice=<N> out=<O> ch=<K>`.  Mode is
%% `gate` or `envelope`; `out=N` is a literal local FH-2 output
%% (1-8), `out=<expander-alias>:<slot>` resolves through the
%% expander's type to a legacy output number (FHX-8GT slots map to
%% legacy outputs 65+).
parse_fh2_config_verb(Rest) ->
    case ws_tokens(Rest) of
        [DevModeBin | KVTokens] ->
            case binary:split(DevModeBin, <<":">>) of
                [DevAlias, ModeBin] ->
                    parse_fh2_config_kvs(DevAlias, ModeBin, KVTokens);
                _ -> none
            end;
        _ -> none
    end.

parse_fh2_config_kvs(DevAlias, ModeBin, KVTokens) ->
    Map = maps:from_list(
        [{K, V} ||
            T <- KVTokens,
            {K, V} <- [case binary:split(T, <<"=">>) of
                           [Ka, Va] -> {Ka, Va};
                           _ -> {<<>>, <<>>}
                       end],
            K =/= <<>>]),
    case {maps:get(<<"voice">>, Map, undefined),
          maps:get(<<"out">>, Map, undefined),
          maps:get(<<"ch">>, Map, undefined)} of
        {VoiceBin, OutBin, ChBin} when VoiceBin =/= undefined,
                                         OutBin =/= undefined,
                                         ChBin =/= undefined ->
            case {parse_int(VoiceBin),
                  resolve_fh2_out(OutBin),
                  parse_int(ChBin)} of
                {{ok, V}, {ok, Out}, {ok, Ch}} ->
                    case ModeBin of
                        <<"gate">> ->
                            ets:insert(tidal_fh2_voices,
                                       {{DevAlias, V},
                                        #{channel => Ch,
                                          output => Out,
                                          mode => gate}}),
                            {fh2_gate, V, Out, Ch};
                        <<"envelope">> ->
                            ets:insert(tidal_fh2_voices,
                                       {{DevAlias, V},
                                        #{channel => Ch,
                                          output => Out,
                                          mode => envelope}}),
                            {fh2_envelope, V, Out, Ch};
                        _ ->
                            {routing_error, <<"fh2-config">>,
                             <<"mode must be 'gate' or 'envelope', got '",
                               ModeBin/binary, "'">>}
                    end;
                _ ->
                    {routing_error, <<"fh2-config">>,
                     <<"could not parse voice/out/ch as integers">>}
            end;
        _ ->
            {routing_error, <<"fh2-config">>,
             <<"missing one of voice= / out= / ch=">>}
    end.

%% Resolve `out=<value>` into the legacy fh2 output number.
%%   bare int N        → N (FH-2 local output 1..8)
%%   <alias>:<slot>    → look up alias type:
%%                         fhx_8gt → 65 + slot  (FHX-8GT outputs 1..8)
%%                         (other expanders not supported yet)
resolve_fh2_out(Bin) ->
    case binary:split(Bin, <<":">>) of
        [Alias, SlotBin] ->
            case {alias_type(Alias), parse_int(SlotBin)} of
                {{ok, fhx_8gt, _Parent, _Detail}, {ok, Slot}} ->
                    {ok, 65 + Slot};
                _ ->
                    error
            end;
        [_] -> parse_int(Bin)
    end.

%% --- Binding verb parsers --------------------------------------------

%% `midi-note <name> <dev> <ch> <note> <vel> <dur> [latency N]`
%%   → bind <name> midi-note <dev> <ch> <note> <vel> <dur> [lat N]
parse_binding_midi_note_verb(Rest) ->
    Tokens = ws_tokens(Rest),
    {Lead, Lat} = peel_latency_suffix(Tokens),
    case Lead of
        [Name, Dev, Ch, Note, Vel, Dur] ->
            ActionSpec = build_action_spec(
                <<"midi-note">>, [Dev, Ch, Note, Vel, Dur], Lat),
            {bind, Name, ActionSpec};
        _ -> none
    end.

%% `midi-cc <name> <dev> <ch> <cc> [latency N]` and `midi-cc-cont` ditto.
parse_binding_midi_cc_verb(Verb, Rest) ->
    Tokens = ws_tokens(Rest),
    {Lead, Lat} = peel_latency_suffix(Tokens),
    case Lead of
        [Name, Dev, Ch, Cc] ->
            ActionSpec = build_action_spec(Verb, [Dev, Ch, Cc], Lat),
            {bind, Name, ActionSpec};
        _ -> none
    end.

%% `gate <name> <dev> <bus> [latency N]` — alias-type-dependent dispatch.
%%   es5 alias  → bind <name> es5gate <bus>
%%   es9 alias  → bind <name> cv      <bus>   (es9-daemon /cv path; gate-style)
%%   fh2 alias  → bind <name> midi-note <dev> <ch> 60 100 50  where <ch> is
%%                resolved from the `fh2-config <dev>:gate|envelope voice=<bus> ch=<ch>`
%%                that the user must have fired earlier.
%%   esx_8gt    → not yet supported (es9-daemon has no chained-expander gate addressing)
parse_binding_gate_verb(Rest) ->
    Tokens = ws_tokens(Rest),
    {Lead, Lat} = peel_latency_suffix(Tokens),
    case Lead of
        [Name, Dev, BusBin] ->
            case {alias_type(Dev), parse_int(BusBin)} of
                {{ok, es5, _Parent, _Detail}, {ok, Bus}} ->
                    ActionSpec = build_action_spec(
                        <<"es5gate">>, [integer_to_binary(Bus)], Lat),
                    {bind, Name, ActionSpec};
                {{ok, es9, _Parent, _Detail}, {ok, Bus}} ->
                    %% es9 alias on the gate verb fires a *trigger* on
                    %% the es9-daemon direct bus.  cv-trig holds the bus
                    %% high for gateDuration ms then auto-clears (vs
                    %% the legacy `cv` action which sets a sustained
                    %% value that never decays).
                    ActionSpec = build_action_spec(
                        <<"cv-trig">>, [integer_to_binary(Bus)], Lat),
                    {bind, Name, ActionSpec};
                {{ok, fh2, _Parent, _Detail}, {ok, Voice}} ->
                    case ets:lookup(tidal_fh2_voices, {Dev, Voice}) of
                        [{_, #{channel := Ch}}] ->
                            ActionSpec = build_action_spec(
                                <<"midi-note">>,
                                [Dev, integer_to_binary(Ch),
                                 <<"60">>, <<"100">>, <<"50">>], Lat),
                            {bind, Name, ActionSpec};
                        [] ->
                            VoiceBin = integer_to_binary(Voice),
                            {routing_error, <<"gate">>,
                             <<"fh2 voice ", VoiceBin/binary,
                               " on '", Dev/binary,
                               "' not configured; "
                               "declare with `fh2-config ", Dev/binary,
                               ":gate voice=", VoiceBin/binary,
                               " out=… ch=…` first">>}
                    end;
                {{ok, esx_8gt, _Parent, _Detail}, _} ->
                    {routing_error, <<"gate">>,
                     <<"esx-8gt chained gate addressing isn't in es9-daemon yet; "
                       "for ES-5's own panel gates use the es5 alias directly">>};
                {{ok, OtherType, _, _}, _} ->
                    TypeBin = atom_to_binary(OtherType, utf8),
                    {routing_error, <<"gate">>,
                     <<"alias '", Dev/binary, "' is type ",
                       TypeBin/binary,
                       "; gate verb supports es5/es9/fh2 today">>};
                {not_found, _} ->
                    {routing_error, <<"gate">>,
                     <<"unknown device alias '", Dev/binary,
                       "'; declare it first">>};
                {_, error} -> none
            end;
        _ -> none
    end.

%% `cv <name> <dev> <bus> <mode> [latency N]`.
%%   es9     alias → bind <name> cv  <bus> <mode>   (mode threaded; legacy
%%                   cv action accepts voct/literal; sample-map → literal + warn)
%%   esx_8cv alias → bind <name> esx <slot>          (mode dropped — esx
%%                   action is literal-only)
%%   yarns         → not yet (Yarns CV requires a MIDI dispatch path that
%%                   doesn't exist as a legacy action atom)
parse_binding_cv_verb(Rest) ->
    Tokens = ws_tokens(Rest),
    {Lead, Lat} = peel_latency_suffix(Tokens),
    case Lead of
        [Name, Dev, BusBin, ModeBin] ->
            case {alias_type(Dev), parse_int(BusBin)} of
                {{ok, es9, _Parent, _Detail}, {ok, Bus}} ->
                    LegacyMode = legacy_cv_mode(ModeBin),
                    ActionSpec = build_action_spec(
                        <<"cv">>,
                        [integer_to_binary(Bus), LegacyMode], Lat),
                    {bind, Name, ActionSpec};
                {{ok, esx_8cv, _Parent, _Detail}, {ok, Slot}} ->
                    ActionSpec = build_action_spec(
                        <<"esx">>, [integer_to_binary(Slot)], Lat),
                    {bind, Name, ActionSpec};
                {{ok, yarns, _Parent, _Detail}, _} ->
                    {routing_error, <<"cv">>,
                     <<"yarns CV outputs aren't wired through purerl-tidal yet; "
                       "drive Yarns via `midi-note` on its MIDI port for now">>};
                {{ok, OtherType, _, _}, _} ->
                    TypeBin = atom_to_binary(OtherType, utf8),
                    {routing_error, <<"cv">>,
                     <<"alias '", Dev/binary, "' is type ",
                       TypeBin/binary,
                       "; cv verb supports es9/esx-8cv today">>};
                {not_found, _} ->
                    {routing_error, <<"cv">>,
                     <<"unknown device alias '", Dev/binary,
                       "'; declare it first">>};
                {_, error} -> none
            end;
        _ -> none
    end.

%% Map a new-grammar cv mode word to the legacy `cv` action's accepted
%% modes.  voct + literal pass through; sample-map collapses to literal
%% (the es9-daemon doesn't have a sample-map encoder; pattern values are
%% already in 0..1 ish range and end up the same shape on the wire).
legacy_cv_mode(<<"voct">>)        -> <<"voct">>;
legacy_cv_mode(<<"literal">>)     -> <<"literal">>;
legacy_cv_mode(<<"sample-map">>) -> <<"literal">>;
legacy_cv_mode(_)                 -> <<"literal">>.

%% `cv-cont <name> <dev> <bus> [latency N]` — declare a continuous-CV
%% binding on a es9-daemon direct bus.  Lowers to `bind <name> cv-cont
%% <bus>` which the dispatcher's `parseContBinding` recognises and
%% installs in the continuousBindings map.  Useful for host-driven
%% LFOs / slow modulators where each event sets a sustained value
%% (no auto-decay deadline, unlike the discrete `cv` action's
%% sample-accurate per-tick re-emit).
%%
%% Today `cv-cont` only supports the es9 alias (es9-daemon direct
%% buses).  ESX-8CV continuous would need a `ContESX` ContDest variant
%% which doesn't exist yet.
parse_binding_cv_cont_verb(Rest) ->
    Tokens = ws_tokens(Rest),
    {Lead, Lat} = peel_latency_suffix(Tokens),
    case Lead of
        [Name, Dev, BusBin] ->
            case {alias_type(Dev), parse_int(BusBin)} of
                {{ok, es9, _Parent, _Detail}, {ok, Bus}} ->
                    ActionSpec = build_action_spec(
                        <<"cv-cont">>, [integer_to_binary(Bus)], Lat),
                    {bind, Name, ActionSpec};
                {{ok, esx_8cv, _Parent, _Detail}, _} ->
                    {routing_error, <<"cv-cont">>,
                     <<"esx-8cv continuous output isn't wired through "
                       "purerl-tidal yet; only es9 direct buses are "
                       "supported on `cv-cont` today">>};
                {{ok, OtherType, _, _}, _} ->
                    TypeBin = atom_to_binary(OtherType, utf8),
                    {routing_error, <<"cv-cont">>,
                     <<"alias '", Dev/binary, "' is type ",
                       TypeBin/binary,
                       "; cv-cont verb supports es9 today">>};
                {not_found, _} ->
                    {routing_error, <<"cv-cont">>,
                     <<"unknown device alias '", Dev/binary,
                       "'; declare it first">>};
                {_, error} -> none
            end;
        _ -> none
    end.

%% Build a `<verb> <a> <b> ...` ActionSpec binary for set_binding_from_spec,
%% optionally appending ` lat <ms>`.  Latency is only emitted when > 0
%% (matches legacy convention where omission means "no compensation").
build_action_spec(Verb, Args, Lat) ->
    Joined = list_to_binary(string:join([binary_to_list(A) ||
                                            A <- [Verb | Args]], " ")),
    case Lat > 0.0 of
        true ->
            LatBin = list_to_binary(io_lib:format("~p", [Lat])),
            <<Joined/binary, " lat ", LatBin/binary>>;
        false ->
            Joined
    end.

%% =========================================================================
%% FH-2 daemon socket (unchanged, original code below).
%% =========================================================================

%% --- Drum-kit cell-text parser --------------------------------------
%%
%% Translates the user-facing cell text into the JSON envelope the
%% fh2-config daemon expects. Grammar:
%%
%% Three forms supported, the parser dispatches on whether the first
%% token after the kit name starts with `[`:
%%
%% Form 1 — head-bracket, auto-allocated slots (preferred / minimal):
%%   drumkit <name> [<v1> <v2> ... <vN>]
%%     gates <bank>
%%     pitch <bank>
%%     ch <baseChannel>
%%   ⇒ ranges default to 0..(N-1); voices laid out positionally
%%
%% Form 2 — head-bracket, explicit ranges (kit on outputs 4-7 etc):
%%   drumkit <name> [<v1> <v2> ... <vN>]
%%     gates <bank> <lo>-<hi>
%%     pitch <bank> <lo>-<hi>
%%     ch <baseChannel>
%%   ⇒ voices laid out positionally inside the declared range
%%
%% Form 3 — legacy / non-contiguous offsets (escape hatch):
%%   drumkit <name>
%%     gates <bank> <lo>-<hi>
%%     pitch <bank> <lo>-<hi>
%%     ch <baseChannel>
%%     <>
%%     <voice>: <offset>
%%     ...
%%   ⇒ each voice's offset within the bank declared explicitly
%%
%% All three produce the same JSON envelope; each voice carries:
%%   channel   = baseChannel + offset
%%   gateSlot  = gateLo      + offset
%%   pitchSlot = pitchLo     + offset
%%
%% The whole block arrives as one WS frame (Calypso bundles `<>`
%% continuation lines). Whitespace, including newlines, is delimiter.
%% Form 1/2 ignore any trailing `<>` body if present — the bracket
%% defines the voice list.

parse_drumkit_cell(Rest) ->
    %% Filter all `<>` continuation tokens up-front. They're a Calypso
    %% UI affordance (line-break marker for multi-line cells), not a
    %% grammar token — neither form depends on them for structure, and
    %% the legacy form's header/body split happens by token shape
    %% (`<voice>:` ends with colon). Filtering early means the rest of
    %% the parser doesn't have to thread `<>`-tolerance through every
    %% match clause.
    Tokens = [T || T <- ws_tokens(Rest), T =/= <<"<>">>],
    case Tokens of
        [Name | T0] ->
            case is_bracket_start(T0) of
                true ->
                    parse_drumkit_bracket_form(Name, T0);
                false ->
                    parse_drumkit_legacy_form(Name, T0)
            end;
        [] ->
            {routing_error, <<"drumkit">>, <<"empty body">>}
    end.

%% Does the first token of this list start a `[...]` voice-list head?
%% Matches both joined-with-content forms (`<<"[bd">>`) and the
%% bare-bracket form (`<<"[">>` if the user wrote `[ bd sn ]`).
is_bracket_start([<<$[, _/binary>> | _]) -> true;
is_bracket_start(_) -> false.

%% Distinguish the yarns macro cell from the yarns device-alias verb.
%% Macro: `yarns <voiceName> [<N>] …`  → 2nd token starts with `[`
%% Device: `yarns <alias> "<deviceName>"` or `yarns <alias>`
%%
%% The token-after-name shape is reliable because device aliases
%% don't use `[`-prefixed identifiers (the routing grammar's
%% alias-and-detail form doesn't admit bracket tokens). Used in the
%% `try_parse_prefixed(<<"yarns ", _>>)` dispatch above.
looks_like_yarns_macro(Body) ->
    Tokens = [T || T <- ws_tokens(Body), T =/= <<"<>">>],
    case Tokens of
        [_Name | T0] -> is_bracket_start(T0);
        _ -> false
    end.

%% Form 3 dispatch — original parser, body-driven offsets.
parse_drumkit_legacy_form(Name, Tokens) ->
    case parse_drumkit_header(Tokens) of
        {ok, Header, T1} ->
            VoiceTokens = drop_separator_token(T1),
            case parse_drumkit_voices(VoiceTokens, Header, []) of
                {ok, []} ->
                    {routing_error, <<"drumkit">>,
                     <<"no voices declared (expected `<voice>: <offset>` pairs after `<>`, or use the `[<v1> <v2> ...]` head form)">>};
                {ok, Voices} ->
                    Json = build_drumkit_json(Name, Voices),
                    {drumkit, Json};
                {error, Msg} ->
                    {routing_error, <<"drumkit">>, Msg}
            end;
        {error, Msg} ->
            {routing_error, <<"drumkit">>, Msg}
    end.

%% Form 1/2 dispatch — bracket-head voice list, positional offsets.
parse_drumkit_bracket_form(Name, Tokens) ->
    case extract_bracket_tokens(Tokens) of
        {ok, [], _} ->
            {routing_error, <<"drumkit">>, <<"empty voice list `[]`">>};
        {ok, VoiceNames, RestTokens} ->
            N = length(VoiceNames),
            case parse_drumkit_header_lenient(RestTokens, N) of
                {ok, Header} ->
                    case build_voices_positional(VoiceNames, Header) of
                        {ok, Voices} ->
                            Json = build_drumkit_json(Name, Voices),
                            {drumkit, Json};
                        {error, Msg} ->
                            {routing_error, <<"drumkit">>, Msg}
                    end;
                {error, Msg} ->
                    {routing_error, <<"drumkit">>, Msg}
            end;
        {error, Msg} ->
            {routing_error, <<"drumkit">>, Msg}
    end.

parse_drumkit_header([<<"gates">>, GateBank, GateRange,
                      <<"pitch">>, PitchBank, PitchRange,
                      <<"ch">>, ChBin | Rest]) ->
    case {parse_range(GateRange), parse_range(PitchRange), parse_int(ChBin)} of
        {{ok, GLo, GHi}, {ok, PLo, PHi}, {ok, ChBase}} when GHi - GLo =:= PHi - PLo ->
            {ok, #{gate_bank  => GateBank,
                   gate_lo    => GLo,
                   gate_hi    => GHi,
                   pitch_bank => PitchBank,
                   pitch_lo   => PLo,
                   pitch_hi   => PHi,
                   ch_base    => ChBase},
             Rest};
        {{ok, _, _}, {ok, _, _}, {ok, _}} ->
            {error, <<"gate range and pitch range must be the same size">>};
        _ ->
            {error, <<"malformed header: expected `<bank> <lo>-<hi>` and integer channel">>}
    end;
parse_drumkit_header(_) ->
    {error,
     <<"expected: <name> gates <bank> <lo>-<hi> pitch <bank> <lo>-<hi> ch <baseChannel> <> <voice>: <offset> ...">>}.

drop_separator_token([<<"<>">> | T]) -> T;
drop_separator_token(T) -> T.

parse_drumkit_voices([], _Header, Acc) ->
    {ok, lists:reverse(Acc)};
parse_drumkit_voices([NameTok, OffsetTok | Rest], Header, Acc) ->
    case strip_trailing_colon(NameTok) of
        {ok, VoiceName} ->
            case parse_int(OffsetTok) of
                {ok, Offset} ->
                    case build_voice(VoiceName, Offset, Header) of
                        {ok, Voice} ->
                            parse_drumkit_voices(Rest, Header, [Voice | Acc]);
                        {error, Msg} -> {error, Msg}
                    end;
                error ->
                    {error, <<"voice `", VoiceName/binary,
                              "`: offset is not an integer (got `",
                              OffsetTok/binary, "`)">>}
            end;
        error ->
            {error, <<"expected `<voice>:` token, got `", NameTok/binary,
                      "` — voice names must end with `:`">>}
    end;
parse_drumkit_voices([Trail], _Header, _Acc) ->
    {error, <<"trailing token without offset: `", Trail/binary, "`">>}.

strip_trailing_colon(Bin) ->
    Size = byte_size(Bin),
    case Size of
        0 -> error;
        _ ->
            case binary:last(Bin) of
                $: -> {ok, binary:part(Bin, 0, Size - 1)};
                _  -> error
            end
    end.

build_voice(Name, Offset, H) ->
    #{gate_lo := GLo, gate_hi := GHi,
      pitch_lo := PLo, pitch_hi := PHi,
      gate_bank := GateBank, pitch_bank := PitchBank,
      ch_base := ChBase} = H,
    case Offset >= 0 andalso (GLo + Offset) =< GHi
                     andalso (PLo + Offset) =< PHi of
        true ->
            {ok, #{name       => Name,
                   channel    => ChBase + Offset,
                   gate_bank  => GateBank,
                   gate_slot  => GLo + Offset,
                   pitch_bank => PitchBank,
                   pitch_slot => PLo + Offset}};
        false ->
            OffBin = integer_to_binary(Offset),
            {error, <<"voice `", Name/binary,
                      "`: offset ", OffBin/binary,
                      " falls outside the declared gate/pitch range">>}
    end.

parse_range(Bin) ->
    case binary:split(Bin, <<"-">>) of
        [LoBin, HiBin] ->
            case {parse_int(LoBin), parse_int(HiBin)} of
                {{ok, Lo}, {ok, Hi}} when Lo =< Hi -> {ok, Lo, Hi};
                _ -> error
            end;
        _ -> error
    end.

%% Yarns cell parser. Returns
%% {yarns, Name, Mode, Alloc, GlideMs, N, BaseChannel, Json} on success.
%%
%% Cell-text body (all keywords after [N] are optional except gates/
%% pitch/ch):
%%
%%   yarns <name> [<N>] [mode <m>] [alloc <a>] [glide <ms>]
%%                gates <bank> [<lo>-<hi>] pitch <bank> [<lo>-<hi>]
%%                ch <chBase>
%%
%% Defaults: mode=poly, alloc=round-robin, glide=0.
parse_yarns_cell(Rest) ->
    Tokens = [T || T <- ws_tokens(Rest), T =/= <<"<>">>],
    case Tokens of
        [Name | T0] ->
            case is_bracket_start(T0) of
                true -> parse_yarns_bracket_form(Name, T0);
                false ->
                    {routing_error, <<"yarns">>,
                     <<"expected `[<voiceCount>]` after `<name>` — "
                       "e.g. `yarns synth1 [4] gates gt0 pitch main "
                       "ch 11`">>}
            end;
        [] -> {routing_error, <<"yarns">>, <<"empty body">>}
    end.

parse_yarns_bracket_form(Name, Tokens) ->
    case extract_bracket_tokens(Tokens) of
        {ok, [CountBin], RestTokens} ->
            case parse_int(CountBin) of
                {ok, N} when N > 0 ->
                    parse_yarns_body(Name, N, RestTokens);
                _ ->
                    {routing_error, <<"yarns">>,
                     <<"voice count must be a positive integer, got `",
                       CountBin/binary, "`">>}
            end;
        {ok, _Multi, _} ->
            {routing_error, <<"yarns">>,
             <<"expected `[<voiceCount>]` — single integer in bracket">>};
        {error, Msg} ->
            {routing_error, <<"yarns">>, Msg}
    end.

parse_yarns_body(Name, N, Tokens0) ->
    {Mode, Tokens1} = peel_optional_keyword(<<"mode">>, Tokens0, <<"poly">>),
    {Alloc, Tokens2} = peel_optional_keyword(<<"alloc">>, Tokens1,
                                              <<"round-robin">>),
    {Glide, Tokens3} = peel_optional_int_keyword(<<"glide">>, Tokens2, 0),
    case validate_yarns_mode(Mode) of
        {error, Msg} -> {routing_error, <<"yarns">>, Msg};
        ok ->
            case validate_yarns_alloc(Alloc) of
                {error, Msg} -> {routing_error, <<"yarns">>, Msg};
                ok ->
                    case parse_drumkit_header_lenient(Tokens3, N) of
                        {ok, Header} ->
                            ChBase = maps:get(ch_base, Header),
                            Json = build_chord_json(Name, N, Header),
                            {yarns, Name, Mode, Alloc, Glide, N,
                             ChBase, Json};
                        {error, Msg} ->
                            {routing_error, <<"yarns">>, Msg}
                    end
            end
    end.

%% Peel an optional `<keyword> <value>` pair off the head of a token
%% list. If the head matches the keyword, consume both tokens and
%% return the value + remainder. Otherwise return the default and
%% leave tokens untouched.
peel_optional_keyword(Keyword, [Keyword, Value | Rest], _Default) ->
    {Value, Rest};
peel_optional_keyword(_Keyword, Tokens, Default) ->
    {Default, Tokens}.

peel_optional_int_keyword(Keyword, [Keyword, ValueBin | Rest], _Default) ->
    case parse_int(ValueBin) of
        {ok, N} -> {N, Rest};
        _ -> {0, Rest}  %% defensive — silently fall back rather than error
    end;
peel_optional_int_keyword(_Keyword, Tokens, Default) ->
    {Default, Tokens}.

validate_yarns_mode(<<"poly">>) -> ok;
validate_yarns_mode(<<"mono">>) -> ok;
validate_yarns_mode(<<"unison">>) -> ok;
validate_yarns_mode(M) ->
    {error, <<"unknown yarns mode `", M/binary,
              "` — expected `poly` / `mono` / `unison`">>}.

validate_yarns_alloc(<<"round-robin">>) -> ok;
validate_yarns_alloc(<<"steal-oldest">>) ->
    {error, <<"alloc `steal-oldest` not implemented in v1 — use "
              "`round-robin` or omit (default)">>};
validate_yarns_alloc(<<"steal-newest">>) ->
    {error, <<"alloc `steal-newest` not implemented in v1 — use "
              "`round-robin` or omit (default)">>};
validate_yarns_alloc(A) ->
    {error, <<"unknown yarns alloc `", A/binary,
              "` — only `round-robin` supported in v1">>}.

%% Chord cell parser. Cell text shape:
%%
%%   chord <name> [<N>] shape <shapeName> gates <bank> [<lo>-<hi>]
%%                       pitch <bank> [<lo>-<hi>] ch <chBase>
%%
%% Synthesises N voice records (`<name>-1`..`<name>-N`) and reuses the
%% drumkit envelope — the daemon doesn't know it's a chord. Returns
%% `{chord, Name, ShapeName, N, BaseChannel, Json}` for the handler arm.
parse_chord_cell(Rest) ->
    Tokens = [T || T <- ws_tokens(Rest), T =/= <<"<>">>],
    case Tokens of
        [Name | T0] ->
            case is_bracket_start(T0) of
                true ->
                    parse_chord_bracket_form(Name, T0);
                false ->
                    {routing_error, <<"chord">>,
                     <<"expected `[<voiceCount>]` after `<name>` — "
                       "e.g. `chord pad1 [4] shape minor7 gates gt0 "
                       "pitch main ch 12`">>}
            end;
        [] ->
            {routing_error, <<"chord">>, <<"empty body">>}
    end.

parse_chord_bracket_form(Name, Tokens) ->
    case extract_bracket_tokens(Tokens) of
        {ok, [CountBin], RestTokens} ->
            case parse_int(CountBin) of
                {ok, N} when N > 0 ->
                    parse_chord_body(Name, N, RestTokens);
                _ ->
                    {routing_error, <<"chord">>,
                     <<"voice count must be a positive integer, got `",
                       CountBin/binary, "`">>}
            end;
        {ok, _Multi, _} ->
            {routing_error, <<"chord">>,
             <<"expected `[<voiceCount>]` — single integer in bracket">>};
        {error, Msg} ->
            {routing_error, <<"chord">>, Msg}
    end.

parse_chord_body(Name, N, Tokens) ->
    case Tokens of
        [<<"shape">>, ShapeName | T1] ->
            case ('tidal_chords@ps':lookupChord())(ShapeName) of
                {nothing} ->
                    {routing_error, <<"chord">>,
                     <<"unknown chord shape `", ShapeName/binary,
                       "` — check Tidal.Chords for the supported list "
                       "(major / minor / major7 / minor7 / sus4 / dim "
                       "/ aug / …)">>};
                {just, _Intervals} ->
                    case parse_drumkit_header_lenient(T1, N) of
                        {ok, Header} ->
                            Json = build_chord_json(Name, N, Header),
                            ChBase = maps:get(ch_base, Header),
                            {chord, Name, ShapeName, N, ChBase, Json};
                        {error, Msg} ->
                            {routing_error, <<"chord">>, Msg}
                    end
            end;
        _ ->
            {routing_error, <<"chord">>,
             <<"expected `shape <shapeName>` after `[N]`">>}
    end.

%% Build the drumkit-shaped JSON envelope from a chord header.
%% Synthesises N voice records `<chordName>-1`..`<chordName>-N`,
%% each on its own MIDI channel + gate slot + pitch slot.
build_chord_json(Name, N, Header) ->
    #{gate_bank := GateBank, gate_lo := GLo,
      pitch_bank := PitchBank, pitch_lo := PLo,
      ch_base := ChBase} = Header,
    Voices = [
        #{name       => <<Name/binary, "-",
                          (integer_to_binary(I + 1))/binary>>,
          channel    => ChBase + I,
          gate_bank  => GateBank,
          gate_slot  => GLo + I,
          pitch_bank => PitchBank,
          pitch_slot => PLo + I}
        || I <- lists:seq(0, N - 1)
    ],
    build_drumkit_json(Name, Voices).

%% Walk tokens collecting names inside a `[...]` head bracket. Handles
%% three input styles depending on how ws_tokens carved them up:
%%
%%   [bd sn hh cp]    → tokens [<<"[bd">>, <<"sn">>, <<"hh">>, <<"cp]">>]
%%   [bd]             → tokens [<<"[bd]">>]
%%   [ bd sn ]        → tokens [<<"[">>, <<"bd">>, <<"sn">>, <<"]">>]
%%
%% Returns the cleaned name list plus the tokens after the closing
%% bracket, or {error, Msg} if the bracket is unterminated.
extract_bracket_tokens([First | Rest]) ->
    %% First token starts with `[`. Strip the leading byte.
    FirstStripped = binary:part(First, 1, byte_size(First) - 1),
    extract_bracket_loop(FirstStripped, Rest, []).

%% Walks the remaining tokens until one ends with `]`. Accumulates
%% non-empty intermediate tokens as voice names. Tokens that are
%% empty (degenerate `[` or `]` alone) are dropped silently.
extract_bracket_loop(Tok, Rest, Acc) ->
    Size = byte_size(Tok),
    EndsWithBracket = Size > 0 andalso binary:last(Tok) =:= $],
    case EndsWithBracket of
        true ->
            Cleaned = binary:part(Tok, 0, Size - 1),
            FinalAcc = case Cleaned of
                <<>> -> Acc;
                _ -> [Cleaned | Acc]
            end,
            {ok, lists:reverse(FinalAcc), Rest};
        false ->
            case Rest of
                [] ->
                    {error, <<"missing closing `]` in voice list">>};
                [Next | Rest2] ->
                    NewAcc = case Tok of
                        <<>> -> Acc;
                        _ -> [Tok | Acc]
                    end,
                    extract_bracket_loop(Next, Rest2, NewAcc)
            end
    end.

%% Header parser for the bracket-head form. Ranges are optional —
%% omitted ranges default to 0..(VoiceCount - 1), so a four-voice kit
%% with `gates gt0` lands on slots 0..3 of bank `gt0` automatically.
%%
%% Required keywords in order: gates, pitch, ch. Ranges appear
%% between bank name and the next keyword when present; absence is
%% detected by checking whether the next token parses as `lo-hi`.
parse_drumkit_header_lenient(Tokens, VoiceCount) ->
    case Tokens of
        [<<"gates">>, GateBank | T1] ->
            {GLo, GHi, T2} = peel_optional_range(T1, 0, VoiceCount - 1),
            case T2 of
                [<<"pitch">>, PitchBank | T3] ->
                    {PLo, PHi, T4} = peel_optional_range(T3, 0,
                                                         VoiceCount - 1),
                    case T4 of
                        [<<"ch">>, ChBin | _] ->
                            case parse_int(ChBin) of
                                {ok, ChBase} ->
                                    GateSlots = GHi - GLo + 1,
                                    PitchSlots = PHi - PLo + 1,
                                    case GateSlots >= VoiceCount
                                         andalso PitchSlots >= VoiceCount of
                                        true ->
                                            {ok, #{gate_bank  => GateBank,
                                                   gate_lo    => GLo,
                                                   gate_hi    => GHi,
                                                   pitch_bank => PitchBank,
                                                   pitch_lo   => PLo,
                                                   pitch_hi   => PHi,
                                                   ch_base    => ChBase}};
                                        false ->
                                            {error,
                                             <<"gate/pitch range too small "
                                               "for the voice count in `[...]`">>}
                                    end;
                                error ->
                                    {error, <<"`ch` expects an integer baseChannel">>}
                            end;
                        _ ->
                            {error,
                             <<"expected `ch <baseChannel>` after pitch declaration">>}
                    end;
                _ ->
                    {error,
                     <<"expected `pitch <bank> [<lo>-<hi>]` after gates">>}
            end;
        _ ->
            {error,
             <<"expected `gates <bank> [<lo>-<hi>]` "
               "`pitch <bank> [<lo>-<hi>]` `ch <baseChannel>` after `[...]`">>}
    end.

%% If the next token parses as a `lo-hi` range, peel it; otherwise
%% return the defaults and leave the tokens untouched (the next
%% keyword stays in place for the outer parser to consume).
peel_optional_range([RangeTok | T] = Tokens, DefaultLo, DefaultHi) ->
    case parse_range(RangeTok) of
        {ok, Lo, Hi} -> {Lo, Hi, T};
        error -> {DefaultLo, DefaultHi, Tokens}
    end;
peel_optional_range([], DefaultLo, DefaultHi) ->
    {DefaultLo, DefaultHi, []}.

%% Bracket-form voice construction: bracket index = offset.
%% Reuses build_voice/3 unchanged — bracket position N becomes
%% offset N from the bank's declared (or default) lo.
build_voices_positional(Names, Header) ->
    build_voices_positional(Names, Header, 0, []).

build_voices_positional([], _Header, _Idx, Acc) ->
    {ok, lists:reverse(Acc)};
build_voices_positional([Name | Rest], Header, Idx, Acc) ->
    case build_voice(Name, Idx, Header) of
        {ok, Voice} ->
            build_voices_positional(Rest, Header, Idx + 1, [Voice | Acc]);
        {error, Msg} ->
            {error, Msg}
    end.

build_drumkit_json(Name, Voices) ->
    VoicesJson = lists:map(fun voice_to_json/1, Voices),
    Joined = bin_join(VoicesJson, <<",">>),
    <<"{\"name\":\"", Name/binary,
      "\",\"voices\":[", Joined/binary, "]}">>.

voice_to_json(V) ->
    iolist_to_binary([
        "{\"name\":\"",       maps:get(name, V),                "\",",
        "\"channel\":",       integer_to_binary(maps:get(channel, V)),    ",",
        "\"gateBank\":\"",    maps:get(gate_bank, V),           "\",",
        "\"gateSlot\":",      integer_to_binary(maps:get(gate_slot, V)),  ",",
        "\"pitchBank\":\"",   maps:get(pitch_bank, V),          "\",",
        "\"pitchSlot\":",     integer_to_binary(maps:get(pitch_slot, V)),
        "}"]).

bin_join([], _Sep) -> <<>>;
bin_join([X], _Sep) -> X;
bin_join([H | T], Sep) ->
    iolist_to_binary([H, [iolist_to_binary([Sep, X]) || X <- T]]).

%% --- Drum-kit reply parsing + binding installation ------------------
%%
%% The fh2-config daemon's apply-drumkit OK reply has the shape:
%%
%%   OK apply-drumkit <kitName> voices=<v1>:<ch1>,<v2>:<ch2>,... mcv=... size=...
%%
%% We extract the `voices=...` segment and, for each name:channel
%% pair, register a `midi-note <fh2-device> <channel> 60 100 50`
%% binding on the dispatcher. The MIDI device alias is `fh2` — the
%% convention purerl-tidal already uses for FH-2 routing.

is_drumkit_ok_reply(Reply) ->
    is_apply_ok_reply(<<"drumkit">>, Reply).

%% Verb-parameterised reply check. Matches replies of the form
%% `OK apply-<verb> <name> voices=…` produced by the daemon's
%% applyMacroEnvelope helper. Used for drumkit / chord / yarns.
is_apply_ok_reply(Verb, Reply) ->
    Prefix = <<"OK apply-", Verb/binary, " ">>,
    case binary:match(Reply, Prefix) of
        {0, _} -> true;
        _ -> false
    end.

%% Pull the value of the `voices=` field out of a daemon reply line.
%% Returns the value binary (up to next space) or `not_found`.
extract_voices_field(Reply) ->
    case binary:match(Reply, <<" voices=">>) of
        nomatch -> not_found;
        {Start, _Len} ->
            ValStart = Start + byte_size(<<" voices=">>),
            Tail = binary:part(Reply, ValStart, byte_size(Reply) - ValStart),
            case binary:match(Tail, <<" ">>) of
                nomatch -> Tail;
                {SpaceAt, _} -> binary:part(Tail, 0, SpaceAt)
            end
    end.

%% Register a midi-note binding per voice on the `fh2` device alias.
%% Silent no-op on any malformed pair so a typo in one entry doesn't
%% drop the whole kit's installation; the bindings that DO parse
%% still get installed.
%%
%% First ensures the `fh2` MIDI device alias exists — without it the
%% registered bindings dispatch to a non-existent device and the kit
%% sounds silent. The `fh2-envelope` arm registers the alias as a
%% side-effect of `set_fh2_voice_channel`, but drumkit doesn't go
%% through that path; we make the registration here so a freshly-
%% restarted purerl-tidal doesn't require the user to fire a code
%% pane (`midi-device fh2 FH-2`) before the drumkit will sound.
%% Re-registering when the alias already exists is a no-op on the
%% PureScript side (`registerMidiDevice` overwrites with the same
%% record); 0.0 latency matches what `setFh2VoiceChannel` writes.
register_drumkit_voice_bindings(Reply) ->
    tidal_dispatcher:register_midi_device(<<"fh2">>, <<"FH-2">>, 0.0),
    case extract_voices_field(Reply) of
        not_found -> ok;
        VoicesBin ->
            Pairs = binary:split(VoicesBin, <<",">>, [global]),
            lists:foreach(fun register_one_voice_binding/1, Pairs)
    end.

register_one_voice_binding(Pair) ->
    case binary:split(Pair, <<":">>) of
        [Name, ChannelBin] ->
            case parse_int(ChannelBin) of
                {ok, Channel} ->
                    %% midi-note fh2 <ch> 60 100 50 — same shape as the
                    %% `gate <name> fh2 <jack>` verb's expansion. Default
                    %% note 60 (C4) — tokens like `c4`, `e4` etc.
                    %% override it; bare token names (`bd`, `1`, `x`)
                    %% fall back to default-note, which is the standard
                    %% drum-machine-trigger behaviour.
                    Spec = <<"midi-note fh2 ",
                             ChannelBin/binary,
                             " 60 100 50">>,
                    tidal_dispatcher:set_binding_from_spec(Name, Spec);
                error -> ok
            end;
        _ -> ok
    end.

%% Install a single ChordDispatch binding under the chord's name.
%% Auto-registers the `fh2` device alias for the same reason
%% drumkit does (a freshly-restarted purerl-tidal shouldn't require
%% the user to fire a code pane before chord cells will sound).
%%
%% The `{chordDispatch, #{...}}` shape is the purs-backend-erl
%% encoding of `ChordDispatch { device, baseChannel, voiceCount,
%% shape, defaultNote, velocity, durationMs }` — single-record
%% constructor with atom-keyed map fields.
register_chord_binding(ChordName, ShapeName, BaseChannel, VoiceCount) ->
    tidal_dispatcher:register_midi_device(<<"fh2">>, <<"FH-2">>, 0.0),
    Binding = array:from_list(
      [{chordDispatch, #{device      => <<"fh2">>,
                         baseChannel => BaseChannel,
                         voiceCount  => VoiceCount,
                         shape       => ShapeName,
                         defaultNote => 60,
                         velocity    => 100,
                         durationMs  => 200}}]),
    tidal_dispatcher:set_binding(ChordName, Binding).

%% Install yarns allocator state AND a single YarnsDispatch binding
%% under the yarns name. Allocator state goes first so the first
%% dispatch event has somewhere to allocate against.
%%
%% `{yarnsDispatch, #{...}}` is the purs-backend-erl encoding of
%% the YarnsDispatch record constructor.
register_yarns_binding(YarnsName, Mode, Alloc, GlideMs,
                       BaseChannel, VoiceCount) ->
    tidal_dispatcher:register_midi_device(<<"fh2">>, <<"FH-2">>, 0.0),
    tidal_yarns_state:install(YarnsName, Mode, Alloc, VoiceCount),
    Binding = array:from_list(
      [{yarnsDispatch, #{device      => <<"fh2">>,
                         baseChannel => BaseChannel,
                         voiceCount  => VoiceCount,
                         mode        => Mode,
                         alloc       => Alloc,
                         glideMs     => GlideMs,
                         defaultNote => 60,
                         velocity    => 100,
                         durationMs  => 200}}]),
    tidal_dispatcher:set_binding(YarnsName, Binding).

fh2_daemon_socket_path() ->
    case os:getenv("HOME") of
        false -> "/tmp/fh2-control.sock";
        Home -> Home ++ "/.fh2/control.sock"
    end.

es9_daemon_socket_path() ->
    case os:getenv("HOME") of
        false -> "/tmp/es9-control.sock";
        Home -> Home ++ "/.es9/control.sock"
    end.

%% Map a Selene push socket id (es9 | fh2) to its daemon control.sock.
%% Both daemons speak the identical apply-polysignal line protocol; the
%% only difference is which unix socket (and which physical rack) it hits.
selene_socket_path(<<"es9">>) -> es9_daemon_socket_path();
selene_socket_path(<<"fh2">>) -> fh2_daemon_socket_path();
selene_socket_path(_) -> es9_daemon_socket_path().

%% Resolve a typeful cue's body Pattern from the loaded Session module.
%% Returns {ok, Pat} or {error, ErrBin}. The Calypso server's
%% /session-source path arranges for calypso_generated_session@ps to be
%% loaded with the user's parts exported as 0-arity functions returning
%% #{mvoice => ..., destination => ..., body => Pat}
%% (newtype PitchedPart elision).
resolve_cue_body(CueName) ->
    SessionAtom = 'calypso_generated_session@ps',
    CueAtom = binary_to_atom(CueName, utf8),
    case erlang:function_exported(SessionAtom, CueAtom, 0) of
        false ->
            case code:is_loaded(SessionAtom) of
                false ->
                    {error,
                     <<"Session module not loaded.  Fire the composition "
                       "first (> run) to build + load Calypso.Generated."
                       "Session.">>};
                _ ->
                    {error,
                     <<"cue '", CueName/binary,
                       "' not found in current Session.  ",
                       "Add it to the composition pane and fire again.">>}
            end;
        true ->
            try erlang:apply(SessionAtom, CueAtom, []) of
                #{destination := Dest, body := Pat} ->
                    {ok, coerce_body_for_dispatch(Dest, Pat)};
                #{body := Pat} -> {ok, Pat};
                Other ->
                    OtherBin = list_to_binary(io_lib:format("~p", [Other])),
                    {error,
                     <<"cue '", CueName/binary,
                       "' returned unexpected shape (no body field): ",
                       OtherBin/binary>>}
            catch
                Class:What ->
                    ClassBin = atom_to_binary(Class, utf8),
                    WhatBin = list_to_binary(io_lib:format("~p", [What])),
                    {error,
                     <<"cue '", CueName/binary, "' raised ",
                       ClassBin/binary, ": ", WhatBin/binary>>}
            end
    end.

%% Body pass-through.  Since the typed-`Sound` realignment, BOTH
%% pitched and drum part bodies are already `Pattern Sound` (the lift
%% from the `PitchedNote12` pitch carrier happens at the `on` boundary
%% in `Calypso.Prelude`, and drum/`#`-control verbs are `Sound`-typed
%% directly).  So no per-destination coercion is needed any more — the
%% body flows straight to the voice's `setPattern`.  Kept as a named
%% function (rather than inlining) so the dispatch call site stays
%% readable and a future destination-specific shim has a home.
coerce_body_for_dispatch(_Dest, Pat) ->
    Pat.

fh2_daemon_call(Command) ->
    daemon_call(fh2_daemon_socket_path(), Command).

%% Generic unix-socket line-protocol call: connect, send `<Command>\n`,
%% read one line, strip the trailing newline. Shared by the fh2-config
%% daemon and es9-daemon (both speak the same apply-polysignal grammar).
daemon_call(SockPath, Command) ->
    Opts = [{active, false}, binary, {packet, line}],
    case gen_tcp:connect({local, SockPath}, 0, Opts, 1000) of
        {ok, Sock} ->
            try
                ok = gen_tcp:send(Sock, [Command, $\n]),
                case gen_tcp:recv(Sock, 0, 5000) of
                    {ok, Reply} ->
                        %% Strip trailing newline for cleaner logs.
                        Trimmed = case Reply of
                            <<>> -> Reply;
                            _ ->
                                case binary:last(Reply) of
                                    $\n -> binary:part(Reply, 0, byte_size(Reply) - 1);
                                    _ -> Reply
                                end
                        end,
                        {ok, Trimmed};
                    {error, RecvReason} ->
                        {error, RecvReason}
                end
            after
                gen_tcp:close(Sock)
            end;
        {error, ConnReason} ->
            {error, ConnReason}
    end.

%% Enumerate `calypso_voices_*@ps.beam` files in the loaded code path and
%% force-reload each one.  Used by reload-baseline so that edits to
%% Calypso/Voices/<X>.purs (which the per-voice arming daemon writes when
%% the user re-arms with a different part) actually take effect in the
%% running VM.  Without this, BEAM keeps the previously-loaded wrapper
%% cached and subsequent `arm` calls hit the stale `armed/0`.
reload_voice_wrappers() ->
    Pattern = "calypso_voices_*@ps.beam",
    Dirs = code:get_path(),
    Files = lists:flatmap(fun(Dir) -> filelib:wildcard(Pattern, Dir) end, Dirs),
    %% Files are basenames like "calypso_voices_qd1@ps.beam"; dedup and
    %% strip the .beam extension to derive the module atom.
    Mods = lists:usort([
        list_to_atom(filename:rootname(F)) || F <- Files
    ]),
    Results = lists:map(fun(M) ->
        _ = case code:soft_purge(M) of
                true  -> ok;
                false -> code:purge(M)
            end,
        case code:load_file(M) of
            {module, _}  -> {M, loaded};
            {error, Why} -> {M, {error, Why}}
        end
    end, Mods),
    tidal_log:info("reload_voice_wrappers: ~p~n", [Results]),
    ok.

%% =========================================================================
%% Per-machine voice trees
%% =========================================================================
%%
%% The six voice supervisors started by purerl_tidal_sup fall into two
%% groups. `tidal_voice_sup` (patterns, cleared by hush_all) and
%% `odonus_voice_sup` (engines that keep advancing behind a hush flag) each
%% have their own semantics and are handled inline. The remaining four share
%% one interface — start_voice/2, stop_voice/1, which_voices/0,
%% lookup_voice/1 — and one lifecycle, so they sweep uniformly.
%%
%% Added 2026-08-07: hush previously missed all four. A voice under any of
%% them was unreachable by `hush`, unreachable by the per-tab stop verbs, and
%% invisible to `state`, so it played until the BEAM was restarted. See
%% triggerfish/docs/RIG-ISSUES-2026-08-07.md #1.
voice_trees() ->
    [balistes_voice_sup,
     repetitor_voice_sup,
     virtual_selene_voice_sup,
     selene_pattern_voice_sup].

%% Terminate every voice under one tree.
%%
%% which_voices/0 returns Pids, and all four supervisors are
%% simple_one_for_one, for which terminate_child/2 takes a Pid (not a child
%% id) — the same call stop_voice/1 makes internally after its name lookup.
%% Their children are `restart => temporary`, so a terminated voice stays
%% dead rather than being brought back by the supervisor.
%%
%% Everything is wrapped in catch, deliberately: this is the panic path, and
%% one unstarted or wedged supervisor must not abort the sweep of the others.
%% A silence that stops three of four things is worth more than an exception.
stop_voice_tree(Sup) ->
    case catch Sup:which_voices() of
        Pids when is_list(Pids) ->
            lists:foreach(
              fun(Pid) -> catch supervisor:terminate_child(Sup, Pid) end,
              Pids);
        _ ->
            ok
    end.

%% Hush: stop all sound on the rig. The `hush` verb, and Tidal's `hush` as
%% Limulus sends it (`tidal hush`): hush means silence, whoever is making it.
%% One machine at a time is `<machine> $ hush` (hush_machine/1).
hush_everything() ->
    %% Tidal-voice patterns get cleared; Odonus voices flip
    %% their hush flag so emit_step skips MIDI output (engine
    %% advance keeps running so they stay clock-aligned).
    tidal_voice_sup:hush_all(),
    OdonusPids = odonus_voice_sup:which_voices(),
    lists:foreach(
      fun(Pid) -> gen_server:cast(Pid, hush) end, OdonusPids),
    %% Also silence the standalone reef voice (reef-odonus). It isn't
    %% under odonus_voice_sup, so hush_all/which_voices miss it.
    catch reef_voice:stop(),
    %% and the standalone Balistes lockstep voice (balistes-sim-at / -fixed).
    catch reef_balistes_voice:stop(),
    %% and the Vetula performance conductor (vetula-perf). It emits no MIDI,
    %% but stop it so a hushed rig isn't still re-conducting a revived Odonus.
    catch reef_vetula_voice:stop(),
    %% and the Vetula brush voice (vetula-voicings, Option B) — a real MIDI
    %% emitter, so hush must silence it.
    catch reef_vetula_brush:stop(),
    %% and Vetula's cards (vetula-cards-play)
    catch vetula_cards:stop(),
    %% and the Conspicillum grain cloud (conspicillum-scene) — also a
    %% /dirt/play emitter, and the densest one on the rig, so hush must
    %% reach it too.
    catch reef_conspicillum_voice:stop(),
    %% and tell the stage, so every page shows the slots stopped.
    tidal_stage:stopped_all(),
    %% and the four PER-MACHINE voice trees. Until 2026-08-07 hush missed
    %% all of these: a voice under one of them was unreachable by every UI
    %% action AND invisible to `state` (which samples only tidal_clock +
    %% tidal_dispatcher), so it emitted until the BEAM was restarted. That
    %% is the fault this arm exists to close — see
    %% triggerfish/docs/RIG-ISSUES-2026-08-07.md #1.
    %%
    %% These voices handle no hush cast, so the only stop available is
    %% TERMINATION — unlike Odonus above, which keeps advancing behind a
    %% flag. Consequence: {unhush} does NOT revive them; re-publish to
    %% restore. That matches the reef_* singletons above, which hush also
    %% stops outright.
    lists:foreach(fun stop_voice_tree/1, voice_trees()),
    %% and the Tidal streams d1..d16 (Limulus), silenced as Tidal's
    %% own hush does, so they resume on the next pattern sent.
    catch tidal_dirt_voice_sup:hush_all(),
    %% and the ES-9's autonomous generators. Selene polysignals are NOT
    %% voices — once applied they run inside es9-daemon's audio callback
    %% with nothing driving them, so stopping every BEAM voice above
    %% leaves the modular still playing. `panic` is the daemon's
    %% sweep-everything verb (added 2026-08-07 for exactly this).
    %%
    %% Best-effort and non-fatal: if the daemon is down there is nothing
    %% to silence there anyway, and a hush that stopped every voice must
    %% still report OK. The FH-2 has no equivalent yet — its
    %% release-claim is bookkeeping-only and --silent leaves the LFOs
    %% running (RIG-ISSUES-2026-08-07 #3/#4/#5).
    _ = daemon_call(es9_daemon_socket_path(), <<"panic">>).
