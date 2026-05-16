%% @doc Walks the typeful-cues baseline module (Calypso.Generated.Session)
%% after a hot reload, registering devices and channels into the existing
%% tidal_dispatcher so that arming a cue against a typeful tvoice (e.g.
%% `bass1`) finds the binding without the user having to fire Level-2
%% wire commands separately.
%%
%% purs-backend-erl encoding:
%%   data MidiDevice = MidiDevice String Int
%%     → {midiDevice, NameBin, LatencyInt}
%%   data Channel = Channel MidiDevice Int Int Int Int
%%     → {channel, DeviceTuple, Ch, Note, Vel, Dur}
%%   newtype Cue (mvoice :: Symbol) = Cue { destination, body }
%%     → #{destination => …, body => …}        (newtype elision)
%%   newtype Session = Session { devices, channels, cues }
%%     → #{devices => …, channels => …, cues => …}
%%
%% We classify by:
%%   - constructor tag (first element) for tuple-encoded data
%%   - keys-present for newtype-elided record maps
%%
%% Devices register first (builds a content→alias map keyed by the
%% device tuple); channels register second, looking up their embedded
%% device tuple to recover the alias.  We reuse `set_binding_from_spec`
%% by synthesising the same Level-2 `midi-note <alias> <ch> <note>
%% <vel> <dur>` strings the parser already handles — no new code path
%% on the PS side.
%%
%% Future binding kinds (Cv, Gate, Cc) become additional Channel
%% constructors and additional classify/1 + register arms here.
-module(tidal_session_walker).

-export([walk_baseline/0,
         lookup_channel_alias/1]).

-define(BASELINE_MODULE,    'calypso_generated_session@ps').
-define(STUDIO_MODULE,      'studio@ps').
-define(CHANNEL_ALIAS_ETS,  tidal_channel_aliases).

%% Resolve a Channel tuple (the AnyCue.destination value) back to the
%% binding name it was registered under by `register_channels/2` (the
%% PureScript identifier — `bass1`, `qd1`, …).  Used by tidal_conductor
%% to find the right dispatcher binding for a section-fired arm.
%% Returns `{just, BinName}` or `nothing`.
lookup_channel_alias(Channel) ->
    case ets:info(?CHANNEL_ALIAS_ETS) of
        undefined -> nothing;
        _ ->
            case ets:lookup(?CHANNEL_ALIAS_ETS, Channel) of
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

walk_baseline() ->
    case erlang:module_loaded(?BASELINE_MODULE) of
        false ->
            {error, not_loaded};
        true ->
            %% Walk Studio (rig declarations: devices + channels) and
            %% Session (the user's cues, which may also redeclare devices
            %% if running standalone) together.  Studio is optional —
            %% Session.purs can stand alone if the user prefers.
            StudioVals = module_values(?STUDIO_MODULE),
            SessionVals = module_values(?BASELINE_MODULE),
            AllVals = StudioVals ++ SessionVals,
            DeviceContentToAlias = register_devices(AllVals),
            register_channels(AllVals, DeviceContentToAlias),
            {ok, #{devices => maps:size(DeviceContentToAlias),
                   channels => count_kind(AllVals, channel)}}
    end.

module_values(Module) ->
    case erlang:module_loaded(Module) of
        true ->
            walk_loaded_module(Module);
        false ->
            %% BEAM lazy-loads modules on first reference.  The walker
            %% iterates exports without crossing into Studio, so the
            %% module never gets implicitly loaded — try explicit load
            %% before giving up.  Studio is optional: a missing .beam
            %% is fine, the user may declare devices in Session directly.
            case code:load_file(Module) of
                {module, _} -> walk_loaded_module(Module);
                {error, _}  -> []
            end
    end.

walk_loaded_module(Module) ->
    Exports = Module:module_info(exports),
    Zeros =
        [Name
         || {Name, 0} <- Exports,
            Name =/= module_info],
    [{N, safe_call(Module, N)} || N <- Zeros].

safe_call(Module, Name) ->
    try Module:Name() of
        V -> V
    catch
        Class:What ->
            tidal_log:debug(
                "session_walker: ~p:~p/0 raised ~p:~p~n",
                [Module, Name, Class, What]),
            undefined
    end.

register_devices(Values) ->
    lists:foldl(
        fun({Name, V}, Acc) ->
            case classify(V) of
                device ->
                    DevName = element(2, V),
                    Lat = element(3, V),
                    AliasBin = atom_to_binary(Name, utf8),
                    tidal_dispatcher:register_midi_device(
                        AliasBin, DevName, Lat),
                    Acc#{V => AliasBin};
                _ ->
                    Acc
            end
        end,
        #{},
        Values).

register_channels(Values, DeviceContentToAlias) ->
    ensure_channel_alias_table(),
    %% Drop any aliases from a previous walk: a re-fire could rename
    %% a channel, and stale entries would point conductor arms at the
    %% wrong binding.
    ets:delete_all_objects(?CHANNEL_ALIAS_ETS),
    lists:foreach(
        fun({Name, V}) ->
            case classify(V) of
                channel ->
                    Device = element(2, V),
                    case maps:find(Device, DeviceContentToAlias) of
                        {ok, Alias} ->
                            Ch  = element(3, V),
                            N   = element(4, V),
                            Vel = element(5, V),
                            Dur = element(6, V),
                            Spec = iolist_to_binary([
                                "midi-note ", Alias, " ",
                                integer_to_binary(Ch), " ",
                                integer_to_binary(N), " ",
                                integer_to_binary(Vel), " ",
                                integer_to_binary(Dur)
                            ]),
                            BindName = atom_to_binary(Name, utf8),
                            %% Record the Channel-value → BindName map
                            %% so the conductor can resolve arm targets
                            %% from cue destinations.
                            ets:insert(?CHANNEL_ALIAS_ETS, {V, BindName}),
                            tidal_dispatcher:set_binding_from_spec(
                                BindName, Spec);
                        error ->
                            tidal_log:debug(
                                "session_walker: channel ~p references "
                                "unknown device tuple ~p~n",
                                [Name, Device])
                    end;
                _ ->
                    ok
            end
        end,
        Values).

count_kind(Values, Kind) ->
    length([V || {_, V} <- Values, classify(V) =:= Kind]).

classify(V) when is_tuple(V), tuple_size(V) >= 1 ->
    case element(1, V) of
        midiDevice -> device;
        channel    -> channel;
        _          -> unknown
    end;
classify(V) when is_map(V) ->
    Keys = maps:keys(V),
    Has = fun(K) -> lists:member(K, Keys) end,
    case {Has(devices) andalso Has(channels) andalso Has(cues),
          Has(destination) andalso Has(body)} of
        {true, _} -> session;
        {_, true} -> cue;
        _         -> unknown
    end;
classify(_) ->
    unknown.
