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
         clear_except/1,
         set/2,
         get/2,
         snapshot/0,
         version/0,
         clear/0]).

-define(TABLE, tidal_control_bus).
%% Special ETS row holding the monotonic version counter.  Bumped on
%% every `set/2` / `clear/0`.  Voices read it to decide whether the
%% cached ControlMap is still valid; see [[reference_purerl_tidal_live_control_substrate]]
%% and the F1 ControlMap cache work.  An atom key won't collide with
%% the binary control-name keys, and `snapshot/0` filters it out.
-define(VERSION_KEY, '$version').

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
    ets:update_counter(?TABLE, ?VERSION_KEY, 1, {?VERSION_KEY, 0}),
    ok.

%% Monotonic version counter.  Bumped on every write or clear.
%% Voices compare against a cached version to decide whether to
%% reuse a previously-built ControlMap or rebuild from the snapshot.
version() ->
    init(),
    case ets:lookup(?TABLE, ?VERSION_KEY) of
        [{_, V}] -> V;
        []       -> 0
    end.

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
    [Pair || Pair = {K, _} <- ets:tab2list(?TABLE), K =/= ?VERSION_KEY].

%% Clear all controls.  Useful for tests and for resetting the
%% rig to a clean state.  Bumps the version counter so any cached
%% ControlMap in a voice is invalidated.
clear() ->
    init(),
    ets:delete_all_objects(?TABLE),
    ets:update_counter(?TABLE, ?VERSION_KEY, 1, {?VERSION_KEY, 0}),
    ok.

%% Clear all controls *except* keys matching one of the given
%% prefixes.  Used by the L-mid Globals "clear-controls" button to
%% wipe knob-improv state while keeping audible-performance state
%% (the `odonus.mute*` keys: a user who explicitly un-muted a
%% playhead expects it to stay un-muted across a knob reset).
clear_except(PreservePrefixes) when is_list(PreservePrefixes) ->
    init(),
    All = ets:tab2list(?TABLE),
    Keep =
        [E || {K, _V} = E <- All,
              K =/= version,
              lists:any(fun(P) -> starts_with(K, P) end, PreservePrefixes)],
    ets:delete_all_objects(?TABLE),
    lists:foreach(fun(E) -> ets:insert(?TABLE, E) end, Keep),
    ets:update_counter(?TABLE, ?VERSION_KEY, 1, {?VERSION_KEY, 0}),
    ok.

starts_with(B, P) when is_binary(B), is_binary(P), byte_size(B) >= byte_size(P) ->
    binary:part(B, 0, byte_size(P)) =:= P;
starts_with(_, _) ->
    false.
