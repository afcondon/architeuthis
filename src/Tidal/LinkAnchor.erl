%% FFI bindings for Tidal.LinkAnchor — thin wrappers around the
%% standalone tidal_link_anchor module that own the actual UDP socket
%% and listener loop.

-module(tidal_linkAnchor@foreign).
-export([start/0, stop/0, info/0, cycleAt/1, beatAt/1, tempo/0,
         nowUnixUs/0, schedulerClock/1]).

start() ->
    fun() ->
        tidal_link_anchor:start(),
        unit
    end.

stop() ->
    fun() ->
        tidal_link_anchor:stop(),
        unit
    end.

info() ->
    fun() ->
        case tidal_link_anchor:info() of
            no_anchor ->
                {nothing};
            {anchor, UnixUs, Beat, Tempo, Quantum, LastRecvUs} ->
                {just,
                 #{ unixUs => float(UnixUs),
                    beat => Beat,
                    tempo => Tempo,
                    quantum => Quantum,
                    lastRecvUs => float(LastRecvUs) }}
        end
    end.

cycleAt(LocalUs) ->
    fun() ->
        %% PureScript Number → Erlang float; cycle_at expects integer microseconds.
        LocalUsInt = trunc(LocalUs),
        case tidal_link_anchor:cycle_at(LocalUsInt) of
            no_anchor ->
                {nothing};
            {ok, {Cycle, Tempo, Quantum}} ->
                {just,
                 #{ cycle => Cycle,
                    tempo => Tempo,
                    quantum => Quantum }}
        end
    end.

beatAt(LocalUs) ->
    fun() ->
        LocalUsInt = trunc(LocalUs),
        case tidal_link_anchor:beat_at(LocalUsInt) of
            no_anchor -> {nothing};
            {ok, Beat} -> {just, Beat}
        end
    end.

tempo() ->
    fun() ->
        case tidal_link_anchor:tempo() of
            no_anchor -> {nothing};
            {ok, T} -> {just, T}
        end
    end.

nowUnixUs() ->
    fun() ->
        float(erlang:system_time(microsecond))
    end.

schedulerClock(Args) ->
    fun() ->
        StartTimeMs = maps:get(startTimeMs, Args),
        FreeRunBpm = maps:get(freeRunBpm, Args),
        tidal_link_anchor:scheduler_clock(StartTimeMs, FreeRunBpm)
    end.
