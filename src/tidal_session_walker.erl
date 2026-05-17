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
         ensure_channel_alias_table/0]).

-define(WALKER_PS_MODULE,  'tidal_sessionWalker@ps').
-define(CHANNEL_ALIAS_ETS, tidal_channel_aliases).

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
                #{devices => 0, instruments => 0, drumKits => 0},
                Events),
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

%% ====================================================================
%% Event application — one clause per RegistrationEvent constructor
%% ====================================================================

%% A device event registers the MIDI port + latency with the
%% dispatcher under the user-given alias.
apply_event({registerMidiDevice,
             #{alias := A, name := N, latencyMs := L}}, Acc) ->
    tidal_dispatcher:register_midi_device(A, N, L),
    bump(devices, Acc);

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

%% A drum-kit event (PR 2a) registers the kit as a single MIDI
%% binding using the first-hit defaults — same shape as
%% `registerMidiInstrument`, just with a different binding alias.
%% PR 2b will replace this with N per-hit bindings (`qd1.bd`,
%% `qd1.sn`, …) once the dispatch path handles per-event hit lookup.
%%
%% The `drumKitValue` field is the opaque DrumKit BEAM term — same
%% role as `instrumentValue`: it goes into the alias ETS so the
%% conductor can resolve section-fired arms whose destination is a
%% DrumKit value.
apply_event({registerMidiDrumKit,
             #{ alias        := A
              , deviceAlias  := D
              , channel      := Ch
              , defNote      := Note
              , defVel       := Vel
              , defDurMs     := Dur
              , drumKitValue := KV
              }}, Acc) ->
    Spec = iolist_to_binary([
        "midi-note ", D, " ",
        integer_to_binary(Ch), " ",
        integer_to_binary(Note), " ",
        integer_to_binary(Vel), " ",
        integer_to_binary(Dur)
    ]),
    ets:insert(?CHANNEL_ALIAS_ETS, {KV, A}),
    tidal_dispatcher:set_binding_from_spec(A, Spec),
    bump(drumKits, Acc);

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
