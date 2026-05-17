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
-define(STUDIO_STATE_ETS,  tidal_studio_state).

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
                #{devices => 0, instruments => 0,
                  drumKits => 0, claimErrors => 0},
                Events),
            %% Capture a Studio-pane snapshot from the raw event list so
            %% `get-studio` (and any future Studio-state queries) can
            %% read it without re-walking the PureScript modules.
            ensure_studio_state_table(),
            ets:insert(?STUDIO_STATE_ETS, {events, Events}),
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

ensure_studio_state_table() ->
    case ets:info(?STUDIO_STATE_ETS) of
        undefined ->
            ets:new(?STUDIO_STATE_ETS,
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
    case ets:info(?STUDIO_STATE_ETS) of
        undefined -> [];
        _ ->
            case ets:lookup(?STUDIO_STATE_ETS, events) of
                [{_, Events}] ->
                    lists:filtermap(fun event_to_line/1, Events);
                _ -> []
            end
    end.

event_to_line({registerMidiDevice,
               #{alias := A, name := N, latencyMs := L}}) ->
    {true,
     iolist_to_binary([<<"device\t">>, A, <<"\t">>, N, <<"\t">>,
                       integer_to_binary(L)])};
event_to_line({registerMidiInstrument,
               #{alias := A, deviceAlias := D, channel := Ch,
                 defNote := Note, defVel := Vel, defDurMs := Dur}}) ->
    {true,
     iolist_to_binary([<<"instrument\t">>, A, <<"\t">>, D, <<"\t">>,
                       integer_to_binary(Ch), <<"\t">>,
                       integer_to_binary(Note), <<"\t">>,
                       integer_to_binary(Vel), <<"\t">>,
                       integer_to_binary(Dur)])};
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
