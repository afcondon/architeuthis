-module(tidal_log@foreign).
-export([debug/1, info/1, err/1]).

%% Thin FFI wrapper over the standalone tidal_log module.
%% PureScript Effect Unit → fun() -> ..., unit end.

debug(Msg) ->
    fun() ->
        tidal_log:debug("~s~n", [Msg]),
        unit
    end.

info(Msg) ->
    fun() ->
        tidal_log:info("~s~n", [Msg]),
        unit
    end.

err(Msg) ->
    fun() ->
        tidal_log:err("~s~n", [Msg]),
        unit
    end.
