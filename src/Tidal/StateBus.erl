%% Tiny ETS-backed state mirror — see Tidal.StateBus.purs.
-module(tidal_stateBus@foreign).

-export([init/0, write/1, read/0]).

%% Idempotent table creation.  ETS exit:badarg when re-creating an
%% existing named table; catch and treat as success.
init() ->
    fun() ->
        try ets:new(tidal_state_bus, [named_table, public, set]) of
            _ -> {}
        catch
            error:badarg -> {}
        end
    end.

%% Write the JSON snapshot.  Single-row table keyed on the atom
%% `current` so reads find it without scanning.
write(Json) ->
    fun() ->
        ets:insert(tidal_state_bus, {current, Json}),
        {}
    end.

%% Read the latest snapshot, or empty-object JSON if nothing has
%% been written yet (or the table doesn't exist for some reason).
read() ->
    fun() ->
        try ets:lookup(tidal_state_bus, current) of
            [{current, Json}] -> Json;
            [] -> <<"{}">>
        catch
            error:badarg -> <<"{}">>
        end
    end.
