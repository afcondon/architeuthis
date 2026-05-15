%% @doc Walks the typeful-cues baseline module (Calypso.Generated.Session)
%% after a hot reload, registering devices and bindings into the existing
%% tidal_dispatcher so that arming a cue against a typeful tvoice (e.g.
%% `bass1`) finds the binding without the user having to fire Level-2
%% wire commands separately.
%%
%% The PureScript newtypes (MidiDevice, MidiNote, Cue, Session) compile
%% down to bare Erlang maps with no constructor tag, so dispatch happens
%% by keys-present rather than by atom tag. Distinct key sets:
%%
%%   device:    #{name, latency}
%%   midi-note: #{device, channel, note, velocity, duration}
%%   cue:       #{destination, body}              — skipped here
%%   session:   #{devices, bindings, cues}        — skipped (we walk
%%                                                  exports directly)
%%
%% Devices register first; bindings second so device-content-to-alias
%% lookup is populated. We reuse `set_binding_from_spec` by synthesising
%% the same Level-2 `midi-note <alias> <ch> <note> <vel> <dur>` strings
%% the parser already handles — no new code path on the PS side.
%%
%% New binding kinds (Cv, Gate, MidiCc, …) get added as additional
%% classify/1 arms when they land in Calypso.Prelude.
-module(tidal_session_walker).

-export([walk_baseline/0]).

-define(BASELINE_MODULE, 'calypso_generated_session@ps').

walk_baseline() ->
    Module = ?BASELINE_MODULE,
    case erlang:module_loaded(Module) of
        false ->
            {error, not_loaded};
        true ->
            Exports = Module:module_info(exports),
            %% Only 0-arity user functions — module_info is BEAM bookkeeping.
            Zeros =
                [Name
                 || {Name, 0} <- Exports,
                    Name =/= module_info],
            Values = [{N, safe_call(Module, N)} || N <- Zeros],
            DeviceContentToAlias = register_devices(Values),
            register_bindings(Values, DeviceContentToAlias),
            {ok, #{devices => maps:size(DeviceContentToAlias),
                   bindings => count_kind(Values, midi_note)}}
    end.

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
                    DevName = maps:get(name, V),
                    Lat = trunc(maps:get(latency, V, 0)),
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

register_bindings(Values, DeviceContentToAlias) ->
    lists:foreach(
        fun({Name, V}) ->
            case classify(V) of
                midi_note ->
                    Device = maps:get(device, V),
                    case maps:find(Device, DeviceContentToAlias) of
                        {ok, Alias} ->
                            Ch  = maps:get(channel, V),
                            N   = maps:get(note, V),
                            Vel = maps:get(velocity, V),
                            Dur = maps:get(duration, V),
                            Spec = iolist_to_binary([
                                "midi-note ", Alias, " ",
                                integer_to_binary(Ch), " ",
                                integer_to_binary(N), " ",
                                integer_to_binary(Vel), " ",
                                integer_to_binary(Dur)
                            ]),
                            BindName = atom_to_binary(Name, utf8),
                            tidal_dispatcher:set_binding_from_spec(
                                BindName, Spec);
                        error ->
                            tidal_log:debug(
                                "session_walker: binding ~p references "
                                "unknown device map ~p~n",
                                [Name, Device])
                    end;
                _ ->
                    ok
            end
        end,
        Values).

count_kind(Values, Kind) ->
    length([V || {_, V} <- Values, classify(V) =:= Kind]).

classify(V) when is_map(V) ->
    Keys = maps:keys(V),
    Has = fun(K) -> lists:member(K, Keys) end,
    case {Has(devices) andalso Has(bindings) andalso Has(cues),
          Has(destination) andalso Has(body),
          Has(device) andalso Has(channel) andalso Has(note),
          Has(name) andalso Has(latency) andalso not Has(channel)} of
        {true,  _, _, _} -> session;
        {_, true, _, _}  -> cue;
        {_, _, true, _}  -> midi_note;
        {_, _, _, true}  -> device;
        _                -> unknown
    end;
classify(_) ->
    unknown.
