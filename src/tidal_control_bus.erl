%% @doc Live control bus — named ETS table holding {Name, Float}
%% rows that the scheduler reads on every tick to populate the
%% `State.controls` map threaded through pattern queries.
%%
%% Distinct from `tidal_state_bus`, which holds a JSON snapshot of
%% scheduler internals for the WebSocket `state` debug verb.  Two
%% tables, two purposes:
%%
%%   * `tidal_state_bus`  — debug surface, JSON, slow-changing
%%   * `tidal_control_bus` — live control plane, native floats,
%%                           changes per knob movement
%%
%% Pattern of use:
%%
%%   * On boot, `init/0` creates the table (idempotent — calling
%%     it again is a no-op).
%%   * The WebSocket `set-control` verb writes via `set/2`.
%%   * On each clock tick, the scheduler calls `snapshot/0` and
%%     ships the result to voices as part of their compute Window.
%%
%% The "many readers, occasional writers" pattern that Erlang's
%% ETS handles especially well: writes are infrequent (knob
%% movements) and reads are concurrent across all voice
%% gen_servers, lock-free at O(1).
-module(tidal_control_bus).

-export([init/0,
         set/2,
         get/2,
         snapshot/0,
         clear/0]).

-define(TABLE, tidal_control_bus).

%% =========================================================================
%% Public API
%% =========================================================================

%% Create the ETS table.  Idempotent: returns ok whether the table
%% already exists or not.
init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set,
                             {read_concurrency, true},
                             {write_concurrency, true}]),
            ok;
        _Info ->
            ok
    end.

%% Set a control value.  Name is a binary; Value is a number
%% (typically a float in [0.0, 1.0] for knob-style controls,
%% but the bus doesn't enforce a range — that's the cell's
%% interpretation).  Auto-inits the table if not yet created.
set(Name, Value) when is_binary(Name), is_number(Value) ->
    init(),
    ets:insert(?TABLE, {Name, float(Value)}),
    ok.

%% Read a single control value, returning Default if not set.
%% Used as a smoke-test entry point; production reads go through
%% snapshot/0 because they batch across many controls per tick.
get(Name, Default) when is_binary(Name) ->
    init(),
    case ets:lookup(?TABLE, Name) of
        [{_, V}] -> V;
        [] -> Default
    end.

%% Take a snapshot of all currently-set controls.  Returns a list
%% of `{Name, Float}` tuples in unspecified order.  Lock-free
%% under read_concurrency.
%%
%% On each clock tick this list gets reshaped into a list of
%% `#{name => K, value => V}` maps (so PureScript receives an
%% Array of records, which is what the Window's controlPairs
%% field expects).
snapshot() ->
    init(),
    ets:tab2list(?TABLE).

%% Clear all controls.  Useful for tests and for resetting the
%% rig to a clean state.
clear() ->
    init(),
    ets:delete_all_objects(?TABLE),
    ok.
