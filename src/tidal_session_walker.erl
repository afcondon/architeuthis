%% @doc Session-walker shell — PR 1.5 of the DSL naming refactor.
%%
%% After PR 1.5 this module is a thin event-applier.  All
%% type-discrimination logic for the Calypso.Generated.Session +
%% Studio modules lives in PureScript at `Tidal.SessionWalker`; the
%% Erlang side just invokes the PureScript walker, gets back a flat
%% `[RegistrationEvent]`, and folds events into the dispatcher.
%%
%% This embodies the PureScript/Erlang boundary principle articulated
%% in `docs/dsl-naming-refactor-plan.md`:
%%
%%     Type-discrimination logic lives in PureScript;
%%     OTP/ETS/IO/scheduling lives in Erlang.
%%     The boundary is a small set of flat registration-event ADTs.
%%
%% The clauses on `apply_event/1` below match on the
%% `RegistrationEvent` constructor tags — small, stable, intentional —
%% never on session/instrument/part ADT shapes.  Adding new
%% destination kinds (PR 2: DrumKit, VPerOctInstrument) is one new
%% clause here for each new event constructor in
%% `Tidal.SessionWalker`; the existing clauses do not change.
%%
%% Legacy exports preserved for callers (tidal_conductor):
%%   lookup_channel_alias/1, ensure_channel_alias_table/0 — the
%% function/table names are mid-rename, retired when the conductor
%% gets its own cleanup pass.
-module(tidal_session_walker).

-export([walk_baseline/0,
         lookup_channel_alias/1,
         ensure_channel_alias_table/0,
         studio_lines/0]).

-define(WALKER_PS_MODULE,  'tidal_sessionWalker@ps').
-define(CHANNEL_ALIAS_ETS, tidal_channel_aliases).
%% Studio snapshot lives in persistent_term (not ETS) so reads work
%% from any process — including a fresh cowboy WS handler that didn't
%% participate in the most-recent walk_baseline.  ETS named tables are
%% owned by the process that creates them and die on owner exit, which
%% would empty the table the moment the wscat / Calypso-side reload-
%% baseline session closes.
-define(STUDIO_STATE_KEY,  {tidal_studio_state, events}).

%% ====================================================================
%% Public API
%% ====================================================================

%% @doc Walk Studio + Session and register devices/instruments with
%% the dispatcher.  Returns `{ok, #{devices => N, instruments => M}}`
%% on success (the shape the WS handler's reload-baseline summary
%% expects), or `{error, Reason}`.
walk_baseline() ->
    case ensure_walker_ps_loaded() of
        false ->
            {error, ps_walker_not_loaded};
        true ->
            ensure_channel_alias_table(),
            %% Stale alias entries from a prior walk could point arms
            %% at the wrong binding if an instrument was renamed; drop
            %% the table before re-registering.
            ets:delete_all_objects(?CHANNEL_ALIAS_ETS),

            EventsThunk = ?WALKER_PS_MODULE:walkBaseline(),
            %% PureScript Array a is Erlang stdlib `array` on the BEAM;
            %% the FFI wrapped a list `into` an array on the way in, so
            %% we unwrap on the way back.  See memory
            %% `reference_purerl_array_is_erlang_array_module`.
            EventsArray = EventsThunk(),
            Events = array:to_list(EventsArray),

            Stats = lists:foldl(
                fun apply_event/2,
                #{devices => 0, cvRouters => 0,
                  instruments => 0, drumKits => 0, claimErrors => 0,
                  %% device_latencies — internal bookkeeping the walker
                  %% reads when registering vmod voices so it can pass
                  %% `latency_ms` into VoiceConfig.  Stripped from the
                  %% caller-facing summary before returning.  Keyed by
                  %% device alias (binary) → latencyMs (float ms).
                  device_latencies => #{}},
                Events),
            %% Capture a Studio-pane snapshot from the raw event list so
            %% `get-studio` (and any future Studio-state queries) can
            %% read it without re-walking the PureScript modules.
            %% persistent_term, not ETS — see STUDIO_STATE_KEY note above.
            persistent_term:put(?STUDIO_STATE_KEY, Events),
            {ok, Stats}
    end.

%% @doc Resolve an Instrument tuple (the AnyPart.destination value)
%% back to the binding name it was registered under.  Used by
%% tidal_conductor to find the right dispatcher binding for a
%% section-fired arm.  Returns `{just, BinName}` or `nothing`.
lookup_channel_alias(Instrument) ->
    case ets:info(?CHANNEL_ALIAS_ETS) of
        undefined -> nothing;
        _ ->
            case ets:lookup(?CHANNEL_ALIAS_ETS, Instrument) of
                [{_, BindName}] -> {just, BindName};
                _ -> nothing
            end
    end.

ensure_channel_alias_table() ->
    case ets:info(?CHANNEL_ALIAS_ETS) of
        undefined ->
            ets:new(?CHANNEL_ALIAS_ETS,
                    [named_table, public, set,
                     {read_concurrency, true}]);
        _ -> ok
    end.

%% @doc Format the current Studio snapshot as a list of tab-delimited
%% binary lines, one per device / instrument / drum kit / claim
%% conflict.  Used by the `get-studio` WS verb to populate Calypso's
%% Studio pane.  Empty list if walk_baseline hasn't run yet.
%%
%% Line shapes:
%%   device      <TAB> <alias> <TAB> <name>       <TAB> <latencyMs>
%%   instrument  <TAB> <alias> <TAB> <deviceAlias> <TAB> <channel>
%%                              <TAB> <defNote> <TAB> <defVel> <TAB> <defDurMs>
%%   drumkit     <TAB> <alias> <TAB> <deviceAlias> <TAB> <channel>
%%                              <TAB> <name>:<note>:<vel>:<dur>,...
%%   conflict    <TAB> <deviceAlias> <TAB> <channel>
%%                              <TAB> <kind>:<owner>,<kind>:<owner>
%%                              <TAB> <human-readable message>
studio_lines() ->
    Events = persistent_term:get(?STUDIO_STATE_KEY, []),
    lists:filtermap(fun event_to_line/1, Events).

event_to_line({registerMidiDevice,
               #{alias := A, name := N, latencyMs := L}}) ->
    {true,
     iolist_to_binary([<<"device\t">>, A, <<"\t">>, N, <<"\t">>,
                       integer_to_binary(L)])};
event_to_line({registerCvRouter,
               #{alias := A, host := H, port := P}}) ->
    {true,
     iolist_to_binary([<<"cv-router\t">>, A, <<"\t">>, H, <<"\t">>,
                       integer_to_binary(P)])};
event_to_line({registerMidiInstrument,
               #{alias := A, deviceAlias := D, channel := Ch,
                 defNote := Note, defVel := Vel, defDurMs := Dur}}) ->
    {true,
     iolist_to_binary([<<"instrument\t">>, A, <<"\t">>, D, <<"\t">>,
                       integer_to_binary(Ch), <<"\t">>,
                       integer_to_binary(Note), <<"\t">>,
                       integer_to_binary(Vel), <<"\t">>,
                       integer_to_binary(Dur)])};
event_to_line({registerVPerOctInstrument,
               #{alias := A, routerAlias := R,
                 gateChannel := G, voctBus := V}}) ->
    {true,
     iolist_to_binary([<<"vperoct\t">>, A, <<"\t">>, R, <<"\t">>,
                       integer_to_binary(G), <<"\t">>,
                       integer_to_binary(V)])};
event_to_line({registerMidiDrumKit,
               #{alias := A, deviceAlias := D, channel := Ch,
                 hits := HitsArr}}) ->
    HitsList = try array:to_list(HitsArr) catch _:_ -> [] end,
    HitSpecs = [ iolist_to_binary([N, ":", integer_to_binary(Nt), ":",
                                   integer_to_binary(V), ":",
                                   integer_to_binary(DurH)])
              || #{name := N, note := Nt, vel := V, durMs := DurH}
                   <- HitsList ],
    HitsBin = iolist_to_binary(lists:join(<<",">>, HitSpecs)),
    {true,
     iolist_to_binary([<<"drumkit\t">>, A, <<"\t">>, D, <<"\t">>,
                       integer_to_binary(Ch), <<"\t">>, HitsBin])};
event_to_line({registerGateDrumKit,
               #{alias := A, routerAlias := R, hits := HitsArr}}) ->
    HitsList = try array:to_list(HitsArr) catch _:_ -> [] end,
    HitSpecs = [ iolist_to_binary([N, ":",
                                   integer_to_binary(G), ":",
                                   integer_to_binary(DurH)])
              || #{name := N, gateChannel := G, durMs := DurH}
                   <- HitsList ],
    HitsBin = iolist_to_binary(lists:join(<<",">>, HitSpecs)),
    {true,
     iolist_to_binary([<<"gatekit\t">>, A, <<"\t">>, R, <<"\t">>,
                       HitsBin])};
event_to_line({registerPolySignal,
               #{alias := A, family := F}}) ->
    {true,
     iolist_to_binary([<<"polysignal\t">>, A, <<"\t">>, F])};
event_to_line({registerVirtualPolySignal,
               #{alias := A, family := F, busPrefix := P}}) ->
    {true,
     iolist_to_binary([<<"vpolysignal\t">>, A, <<"\t">>, F,
                       <<"\t">>, P])};
event_to_line({registerBalistes,
               #{alias := A, deviceAlias := D, channel := Ch}}) ->
    {true,
     iolist_to_binary([<<"balistes\t">>, A, <<"\t">>, D, <<"\t">>,
                       integer_to_binary(Ch)])};
event_to_line({registerRepetitor,
               #{alias := A, deviceAlias := D, channel := Ch,
                 library := Lib, patternSlug := Slug}}) ->
    {true,
     iolist_to_binary([<<"repetitor\t">>, A, <<"\t">>, D, <<"\t">>,
                       integer_to_binary(Ch), <<"\t">>, Lib,
                       <<"\t">>, Slug])};
event_to_line({registerOdonus,
               #{alias := A, deviceAlias := D, channel := Ch,
                 navMode := Nav}}) ->
    {true,
     iolist_to_binary([<<"odonus\t">>, A, <<"\t">>, D, <<"\t">>,
                       integer_to_binary(Ch), <<"\t">>, Nav])};
event_to_line({reportClaimError,
               #{deviceAlias := D, channel := Ch,
                 owners := OwnersArr, message := Msg}}) ->
    OwnersList = try array:to_list(OwnersArr) catch _:_ -> [] end,
    OwnerSpecs = [ iolist_to_binary([K, ":", Name])
                || #{name := Name, kind := K} <- OwnersList ],
    OwnersBin = iolist_to_binary(lists:join(<<",">>, OwnerSpecs)),
    {true,
     iolist_to_binary([<<"conflict\t">>, D, <<"\t">>,
                       integer_to_binary(Ch), <<"\t">>, OwnersBin,
                       <<"\t">>, Msg])};
event_to_line(_) ->
    false.

%% ====================================================================
%% Event application — one clause per RegistrationEvent constructor
%% ====================================================================

%% A device event registers the MIDI port + latency with the
%% dispatcher under the user-given alias.  We also stash the
%% alias→latencyMs mapping in the accumulator so subsequent vmod
%% registrations (odonus/balistes/repetitor) can pull device latency into
%% their VoiceConfig — the F-LAT fix mirrors what
%% `Tidal.Dispatcher` does for Tidal-pattern emits
%% (`adjustedUnixUs = wallUs - dev.latencyMs * 1000`).
apply_event({registerMidiDevice,
             #{alias := A, name := N, latencyMs := L}}, Acc) ->
    tidal_dispatcher:register_midi_device(A, N, L),
    Lats = maps:get(device_latencies, Acc, #{}),
    NewAcc = Acc#{device_latencies => Lats#{A => float(L)}},
    bump(devices, NewAcc);

%% A cv-router event (PR 2c) records the named cv-router endpoint in
%% the Studio snapshot.  In the single-router runtime (PR 2c) the
%% dispatcher doesn't actually act on this — all OSC goes through the
%% singleton OSCClient opened against the default host:port at boot.
%% PR 2c.2 will hook this up to a per-alias OSCClient map so multiple
%% cv-routers can be addressed independently (shared jams across
%% machines / multi-ES-9).  Until then, declaring a non-default
%% host:port is silently equivalent to the default.
apply_event({registerCvRouter,
             #{alias := _A, host := _H, port := _P}}, Acc) ->
    bump(cvRouters, Acc);

%% An instrument event synthesises the same Level-2 `midi-note <alias>
%% <ch> <note> <vel> <dur>` spec the dispatcher's parser already
%% handles, then inserts the raw Instrument value → binding-name into
%% the alias ETS so tidal_conductor can resolve section-fired arms.
%%
%% The `instrumentValue` field is an opaque BEAM term — we never
%% pattern-match on its shape, only use it as a map key.  That's the
%% boundary principle in practice: PureScript classified it, Erlang
%% just transports it.
apply_event({registerMidiInstrument,
             #{ alias        := A
              , deviceAlias  := D
              , channel      := Ch
              , defNote      := Note
              , defVel       := Vel
              , defDurMs     := Dur
              , instrumentValue := IV
              }}, Acc) ->
    Spec = iolist_to_binary([
        "midi-note ", D, " ",
        integer_to_binary(Ch), " ",
        integer_to_binary(Note), " ",
        integer_to_binary(Vel), " ",
        integer_to_binary(Dur)
    ]),
    ets:insert(?CHANNEL_ALIAS_ETS, {IV, A}),
    tidal_dispatcher:set_binding_from_spec(A, Spec),
    bump(instruments, Acc);

%% A V/oct instrument event (PR 2c) installs a compound binding of
%% the form `gate <gateChannel> + cv <voctBus> voct` — reuses the
%% existing Gate + CV NoteNameVoct PrimActions, no new dispatcher
%% code on the pitched side.  The router alias is currently
%% informational (singleton OSCClient).
%%
%% `instrumentValue` goes into the channel-alias ETS exactly like
%% the MidiInstrument path so tidal_conductor can resolve
%% section-fired arms whose destination is a VPerOctInstrument value.
apply_event({registerVPerOctInstrument,
             #{ alias        := A
              , routerAlias  := _R
              , gateChannel  := G
              , voctBus      := V
              , instrumentValue := IV
              }}, Acc) ->
    Spec = iolist_to_binary([
        "gate ", integer_to_binary(G),
        " + cv ", integer_to_binary(V), " voct"
    ]),
    ets:insert(?CHANNEL_ALIAS_ETS, {IV, A}),
    tidal_dispatcher:set_binding_from_spec(A, Spec),
    bump(instruments, Acc);

%% A drum-kit event (PR 2b) registers ONE binding per kit, of the
%% new `MidiDrumKit` PrimAction kind: per-event dispatch consults
%% the binding's hits map at the dispatcher emit path (classic
%% Tidal/SuperDirt per-orbit `s`-keyed lookup, ported to typed
%% MIDI dispatch).
%%
%% The spec encoding is `midi-drum-kit <device> <channel>` for an
%% empty kit, or `midi-drum-kit <device> <channel> <name>:<note>:
%% <vel>:<dur>,…` for a populated one.  The dispatcher's
%% `parseAction` recognises both forms.
%%
%% Like `registerMidiInstrument`, the `drumKitValue` field goes
%% into the alias ETS so the conductor can resolve section-fired
%% arms whose destination is a DrumKit value.
apply_event({registerMidiDrumKit,
             #{ alias        := A
              , deviceAlias  := D
              , channel      := Ch
              , hits         := HitsArr
              , drumKitValue := KV
              }}, Acc) ->
    %% Hits arrive as an Erlang stdlib `array` (PureScript Array
    %% convention).  Walk to a list, encode each entry as
    %% `name:note:vel:dur`, join with commas.
    HitsList = try array:to_list(HitsArr)
               catch _:_ -> []
               end,
    HitSpecs = [ iolist_to_binary([
                     N, ":",
                     integer_to_binary(Nt), ":",
                     integer_to_binary(V), ":",
                     integer_to_binary(Dur)
                 ])
              || #{name := N, note := Nt, vel := V, durMs := Dur}
                   <- HitsList ],
    HitsBin = case HitSpecs of
                  [] -> <<>>;
                  _  -> iolist_to_binary(
                          lists:join(<<",">>, HitSpecs))
              end,
    Spec = case HitsBin of
               <<>> ->
                   iolist_to_binary([
                       "midi-drum-kit ", D, " ",
                       integer_to_binary(Ch)]);
               _ ->
                   iolist_to_binary([
                       "midi-drum-kit ", D, " ",
                       integer_to_binary(Ch), " ", HitsBin])
           end,
    ets:insert(?CHANNEL_ALIAS_ETS, {KV, A}),
    tidal_dispatcher:set_binding_from_spec(A, Spec),
    bump(drumKits, Acc);

%% A gate-drum-kit event (PR 2c) registers ONE binding per kit, of
%% the new `GateDrumKit` PrimAction kind: per-event dispatch looks
%% up the event's token in the binding's hits map and fires a
%% cv-router gate trigger on the matching channel for the hit's
%% declared duration.  Parallel to registerMidiDrumKit but routed
%% through cv-router instead of MIDI.
%%
%% Spec encoding: `gate-drum-kit <router-alias>` (empty kit) or
%% `gate-drum-kit <router-alias> <name>:<ch>:<dur>,…` (populated).
%% The router alias is currently informational (singleton OSCClient).
apply_event({registerGateDrumKit,
             #{ alias        := A
              , routerAlias  := R
              , hits         := HitsArr
              , drumKitValue := KV
              }}, Acc) ->
    HitsList = try array:to_list(HitsArr)
               catch _:_ -> []
               end,
    HitSpecs = [ iolist_to_binary([
                     N, ":",
                     integer_to_binary(G), ":",
                     integer_to_binary(Dur)
                 ])
              || #{name := N, gateChannel := G, durMs := Dur}
                   <- HitsList ],
    HitsBin = case HitSpecs of
                  [] -> <<>>;
                  _  -> iolist_to_binary(
                          lists:join(<<",">>, HitSpecs))
              end,
    Spec = case HitsBin of
               <<>> ->
                   iolist_to_binary([
                       "gate-drum-kit ", R]);
               _ ->
                   iolist_to_binary([
                       "gate-drum-kit ", R, " ", HitsBin])
           end,
    ets:insert(?CHANNEL_ALIAS_ETS, {KV, A}),
    tidal_dispatcher:set_binding_from_spec(A, Spec),
    bump(drumKits, Acc);

%% Balistes vmod Phase 3 (2026-05-18): a BEAM-native Balistes voice declared
%% at the Session level.  We start the gen_server under balistes_voice_sup
%% with the captured config + MIDI output settings.  Same-alias re-fire
%% just updates the running voice's cfg in place (no restart, no
%% step-counter reset) — the live-mutation showcase.
apply_event({registerBalistes,
             #{ alias       := A
              , deviceAlias := D
              , deviceName  := PortName
              , channel     := Ch
              , noteBd      := NBd
              , noteSd      := NSd
              , noteHh      := NHh
              , vel         := V
              , velAccent   := VA
              , durMs       := Dur
              , config      := Cfg
              }}, Acc) ->
    LatencyMs = maps:get(D, maps:get(device_latencies, Acc, #{}), 0.0),
    VoiceConfig = #{
        port_name => PortName,
        channel   => Ch,
        note_bd   => NBd,
        note_sd   => NSd,
        note_hh   => NHh,
        vel       => V,
        vel_accent => VA,
        dur_ms    => Dur,
        cfg       => Cfg,
        latency_ms => LatencyMs
    },
    AliasAtom = binary_to_atom(A, utf8),
    case balistes_voice_sup:lookup_voice(AliasAtom) of
        undefined ->
            case balistes_voice_sup:start_voice(AliasAtom, VoiceConfig) of
                {ok, _Pid} ->
                    tidal_log:info("balistes voice ~s started on ~s ch~B~n",
                                   [A, PortName, Ch]),
                    bump(balistes, Acc);
                {error, Reason} ->
                    tidal_log:err("balistes voice ~s: start failed: ~p~n",
                                  [A, Reason]),
                    bump(balistesErrors, Acc)
            end;
        _Pid ->
            %% Live update — same alias, just swap the config.  Step
            %% counter and perturbations survive; the next step queries
            %% the new patterns.
            balistes_voice:set_config(AliasAtom, Cfg),
            bump(balistes, Acc)
    end;

%% Repetitor vmod Phase 3 (2026-05-19): a BEAM-native Repetitor voice
%% declared at the Session level.  Mirror of registerBalistes — same
%% MIDI-routing fields plus library + pattern_slug selectors that
%% choose which corpus entry the voice plays.  Same live-mutation
%% semantics: same-alias re-fire updates config in place; the
%% engine's step counter is preserved.
apply_event({registerRepetitor,
             #{ alias         := A
              , deviceAlias   := D
              , deviceName    := PortName
              , channel       := Ch
              , noteM         := NM
              , noteC1        := NC1
              , noteC2        := NC2
              , noteC3        := NC3
              , vel           := V
              , durMs         := Dur
              , stepsPerCycle := Sp
              , library       := Lib
              , patternSlug   := Slug
              , config        := Cfg
              }}, Acc) ->
    LibMod = binary_to_atom(<<"repetitor_library_", Lib/binary>>, utf8),
    LatencyMs = maps:get(D, maps:get(device_latencies, Acc, #{}), 0.0),
    VoiceConfig = #{
        port_name        => PortName,
        channel          => Ch,
        note_m           => NM,
        note_c1          => NC1,
        note_c2          => NC2,
        note_c3          => NC3,
        vel              => V,
        dur_ms           => Dur,
        steps_per_cycle  => Sp,
        library_mod      => LibMod,
        pattern_slug     => Slug,
        cfg              => Cfg,
        latency_ms       => LatencyMs
    },
    AliasAtom = binary_to_atom(A, utf8),
    case repetitor_voice_sup:lookup_voice(AliasAtom) of
        undefined ->
            case repetitor_voice_sup:start_voice(AliasAtom, VoiceConfig) of
                {ok, _Pid} ->
                    tidal_log:info(
                      "repetitor voice ~s started on ~s ch~B (~s/~s)~n",
                      [A, PortName, Ch, Lib, Slug]),
                    bump(repetitor, Acc);
                {error, Reason} ->
                    tidal_log:err("repetitor voice ~s: start failed: ~p~n",
                                  [A, Reason]),
                    bump(repetitorErrors, Acc)
            end;
        _Pid ->
            repetitor_voice:set_config(AliasAtom,
                #{pattern_slug => Slug, cfg => Cfg}),
            bump(repetitor, Acc)
    end;

%% René machine Phase 3 (2026-05-19): a BEAM-native Make-Noise-René-
%% inspired voice declared at the Session level.  User-supplied 16
%% notes + modal arrays + autonomous traversal.  The four arrays
%% arrive as PureScript Array (Erlang `array` module) — convert to
%% lists at this boundary before feeding the engine.
apply_event({registerOdonus,
             #{ alias         := A
              , deviceAlias   := D
              , deviceName    := PortName
              , channel       := Ch
              , vel           := V
              , durMs         := Dur
              , stepsPerCycle := Sp
              , notes         := NotesArr
              , skip          := SkipArr
              , gate          := GateArr
              , glide         := GlideArr
              , navMode       := NavBin
              , config        := Cfg
              }}, Acc) ->
    NavAtom = binary_to_atom(NavBin, utf8),
    Notes = try array:to_list(NotesArr) catch _:_ -> [] end,
    Skip  = try array:to_list(SkipArr)  catch _:_ -> [] end,
    Gate  = try array:to_list(GateArr)  catch _:_ -> [] end,
    Glide = try array:to_list(GlideArr) catch _:_ -> [] end,
    LatencyMs = maps:get(D, maps:get(device_latencies, Acc, #{}), 0.0),
    VoiceConfig = #{
        port_name        => PortName,
        channel          => Ch,
        vel              => V,
        dur_ms           => Dur,
        steps_per_cycle  => Sp,
        notes            => Notes,
        skip             => Skip,
        gate             => Gate,
        glide            => Glide,
        nav_mode         => NavAtom,
        cfg              => Cfg,
        latency_ms       => LatencyMs
    },
    AliasAtom = binary_to_atom(A, utf8),
    case odonus_voice_sup:lookup_voice(AliasAtom) of
        undefined ->
            case odonus_voice_sup:start_voice(AliasAtom, VoiceConfig) of
                {ok, _Pid} ->
                    tidal_log:info(
                      "odonus voice ~s started on ~s ch~B (~s)~n",
                      [A, PortName, Ch, NavBin]),
                    bump(odonus, Acc);
                {error, Reason} ->
                    tidal_log:err("odonus voice ~s: start failed: ~p~n",
                                  [A, Reason]),
                    bump(odonusErrors, Acc)
            end;
        _Pid ->
            odonus_voice:set_config(AliasAtom,
                #{notes => Notes, skip => Skip, gate => Gate, glide => Glide,
                  nav_mode => NavAtom, cfg => Cfg}),
            bump(odonus, Acc)
    end;

%% Slab C step 1 (2026-05-18): an autonomous FH-2 polysignal declared
%% at the Session level (typed PolySignal binding).  The PureScript
%% walker projected the value to the JSON envelope the daemon already
%% understands; we hand it verbatim to fh2-daemon via
%% `apply-polysignal <json>` on its Unix socket.  Daemon does the real
%% claim work at `Rig.applyWithClaims` — name conflicts come back as
%% an `ERR` line that we surface via `tidal_log:err` (same warn-on-
%% conflict policy as the front-end reservations Phase 1 path).
apply_event({registerPolySignal,
             #{ alias        := A
              , family       := F
              , jsonEnvelope := J
              }}, Acc) ->
    Cmd = iolist_to_binary([<<"apply-polysignal ">>, J]),
    case fh2_daemon_call(Cmd) of
        {ok, <<"OK", _/binary>> = Reply} ->
            tidal_log:debug(
                "session_walker: polysignal ~s (~s) -> ~s~n",
                [A, F, Reply]),
            bump(polySignals, Acc);
        {ok, ErrReply} ->
            tidal_log:err(
                "session_walker: polysignal ~s (~s) refused: ~s~n",
                [A, F, ErrReply]),
            bump(polySignalErrors, Acc);
        {error, Reason} ->
            tidal_log:err(
                "session_walker: polysignal ~s (~s) daemon error: ~p~n",
                [A, F, Reason]),
            bump(polySignalErrors, Acc)
    end;

%% A virtual polysignal — runs entirely in BEAM, no fh2-daemon
%% round-trip.  Start (or live-update) a virtual_polysignal_voice
%% under virtual_polysignal_voice_sup.  Same-alias re-fire swaps the
%% PolySignal value in place; cycle phase is preserved across edits.
apply_event({registerVirtualPolySignal,
             #{ alias           := A
              , busPrefix       := Prefix
              , family          := F
              , polySignalValue := PV
              }}, Acc) ->
    VoiceConfig = #{
        bus_prefix => Prefix,
        family     => F,
        polysig    => PV
    },
    AliasAtom = binary_to_atom(A, utf8),
    case virtual_polysignal_voice_sup:lookup_voice(AliasAtom) of
        undefined ->
            case virtual_polysignal_voice_sup:start_voice(AliasAtom, VoiceConfig) of
                {ok, _Pid} ->
                    tidal_log:info(
                      "virtual polysignal ~s (~s) started, prefix=~s~n",
                      [A, F, Prefix]),
                    bump(virtualPolySignals, Acc);
                {error, Reason} ->
                    tidal_log:err(
                      "virtual polysignal ~s (~s): start failed: ~p~n",
                      [A, F, Reason]),
                    bump(virtualPolySignalErrors, Acc)
            end;
        _Pid ->
            virtual_polysignal_voice:set_config(AliasAtom,
                #{polysig => PV}),
            bump(virtualPolySignals, Acc)
    end;

%% A claim-error event surfaces a Phase-1 reservation-validation
%% finding (e.g. duplicate MIDI channel claim).  The PureScript walker
%% pre-renders a human-readable line in `message`; we log it via
%% tidal_log:err and bump a counter for the boot-summary.  Registration
%% of the conflicting bindings is NOT blocked — warn-only is the v1
%% policy; the last-write-wins behaviour of the dispatcher is preserved.
apply_event({reportClaimError,
             #{ message := Msg }}, Acc) ->
    tidal_log:err("session_walker: ~s~n", [Msg]),
    bump(claimErrors, Acc);

%% Unknown event — log and skip.  Forward-compat for any
%% RegistrationEvent constructors added on the PureScript side
%% before their Erlang clause lands.
apply_event(Other, Acc) ->
    tidal_log:debug(
        "session_walker: unknown registration event ~p~n", [Other]),
    Acc.

%% ====================================================================
%% Internal
%% ====================================================================

ensure_walker_ps_loaded() ->
    case erlang:module_loaded(?WALKER_PS_MODULE) of
        true -> true;
        false ->
            case code:load_file(?WALKER_PS_MODULE) of
                {module, _} -> true;
                {error, _}  -> false
            end
    end.

bump(Key, Acc) ->
    Acc#{Key => maps:get(Key, Acc, 0) + 1}.

%% ====================================================================
%% fh2-daemon client — synchronous request/reply over a Unix socket.
%%
%% DUPLICATED from tidal_webSocket_handler@foreign for now (Slab C
%% step 1).  Both copies are tiny.  Extract to src/tidal_fh2.erl when
%% a third caller emerges — see task #71.
%% ====================================================================

fh2_daemon_call(Command) ->
    SockPath = fh2_daemon_socket_path(),
    Opts = [{active, false}, binary, {packet, line}],
    case gen_tcp:connect({local, SockPath}, 0, Opts, 1000) of
        {ok, Sock} ->
            try
                ok = gen_tcp:send(Sock, [Command, $\n]),
                case gen_tcp:recv(Sock, 0, 5000) of
                    {ok, Reply} ->
                        Trimmed = case Reply of
                            <<>> -> Reply;
                            _ ->
                                case binary:last(Reply) of
                                    $\n -> binary:part(Reply, 0,
                                                       byte_size(Reply) - 1);
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

fh2_daemon_socket_path() ->
    case os:getenv("HOME") of
        false -> "/tmp/fh2-control.sock";
        Home -> Home ++ "/.fh2/control.sock"
    end.
