%% FFI shim for Tidal.Dispatcher.purs.
-module(tidal_dispatcher@foreign).

-export([nowUnixMicros/0]).

%% Wall clock as Unix microseconds. Used by the dispatcher to compute
%% per-event delays (delayMs = (wallTimeUs - nowUnixUs) / 1000).
nowUnixMicros() ->
    fun() ->
        float(erlang:system_time(microsecond))
    end.
