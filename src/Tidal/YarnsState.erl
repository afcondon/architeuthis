%% FFI bindings for Tidal.YarnsState — thin wrapper over the ETS-
%% backed allocator in `tidal_yarns_state`.
%%
%% `AllocResult` constructors map onto purs-backend-erl tagged
%% tuples:
%%
%%   AllocSingle Int          → {allocSingle, Idx}
%%   AllocBroadcast (Array)   → {allocBroadcast, ArrayValue}
%%   AllocFailed              → {allocFailed}
%%
%% Array values use the Erlang `array` module (matches the rest of
%% the purerl-tidal codebase — see reference_purerl_array_is_erlang
%% _array_module memory).

-module(tidal_yarnsState@foreign).
-export([installYarns/4, removeYarns/1, allocateVoice/2]).

installYarns(YarnsName, Mode, Alloc, VoiceCount) ->
    fun() ->
        tidal_yarns_state:install(YarnsName, Mode, Alloc, VoiceCount),
        unit
    end.

removeYarns(YarnsName) ->
    fun() ->
        tidal_yarns_state:remove(YarnsName),
        unit
    end.

allocateVoice(YarnsName, NowUs) ->
    fun() ->
        %% NowUs arrives as a PureScript Number (floating-point).
        %% Truncate to an integer for ETS storage — sub-microsecond
        %% precision is irrelevant for voice-allocation timestamps.
        case tidal_yarns_state:allocate_voice(YarnsName, trunc(NowUs)) of
            {ok, Idx} ->
                {allocSingle, Idx};
            {unison, IdxList} ->
                {allocBroadcast, array:from_list(IdxList)};
            _ ->
                {allocFailed}
        end
    end.
