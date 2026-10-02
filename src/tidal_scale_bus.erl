%% @doc Active-scale slot for the live-render path.
%%
%% A single mutable slot holding the active `Tidal.Scale` value (or
%% `nothing`).  Mutated by the `set-scale` wire verb; read by
%% `tidal_clock` at every tick and pushed into every voice's
%% `Window.activeScale`.  Voices then render `Degree` pitches against
%% this scale at emit time — so a single `set-scale c-mixolydian` at
%% the wire re-renders every running degree pattern on the next tick.
%%
%% Separate from `tidal_control_bus` because the bus carries only
%% Numbers (knob values), and Scale is a richer record.  The two
%% buses both flow into the voice's Window — controls via
%% `controlPairs`, scale via `activeScale`.
%%
%% Storage: a `set`-typed ETS table holding the single key `scale`
%% with the purerl-encoded Scale value (a `{scale, #{root, intervals,
%% name}}` tuple).  Absent key (initial state) maps to PS `Nothing`.
-module(tidal_scale_bus).

-export([start_link/0,
         set_scale/1,
         clear_scale/0,
         current_scale/0,
         current_scale_name/0]).

-define(TABLE, ?MODULE).
-define(KEY, scale).

%% Owner process for the ETS table — simple, blocking-free, just
%% holds the table alive.  Spawned at boot from
%% `purerl_tidal_app:start/2`; if this module is invoked before the
%% owner exists the table is created lazily (handy for tests that
%% reach in without booting the full app).
start_link() ->
    Pid = spawn_link(fun owner_loop/0),
    register_owner(Pid),
    {ok, Pid}.

register_owner(Pid) ->
    ensure_table(),
    Pid.

owner_loop() ->
    ensure_table(),
    receive
        stop -> ok
    end.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, set, public, {read_concurrency, true}]);
        _ ->
            ok
    end.

%% Set the active scale by name.  `Name` is a kebab-case scale name
%% like `<<"c-mixolydian">>`; the PS-side `lookupScaleByName/1`
%% resolves it to a Scale value.  Returns `{ok, ScaleNameBinary}` on
%% success or `{error, unknown_scale}` if the name doesn't match any
%% registered scale.
set_scale(Name) when is_binary(Name) ->
    ensure_table(),
    case ('tidal_substrate_scales@ps':lookupScaleByName())(Name) of
        {just, ScaleVal} ->
            ets:insert(?TABLE, {?KEY, ScaleVal, Name}),
            {ok, Name};
        {nothing} ->
            {error, unknown_scale}
    end.

%% Clear the active scale.  Subsequent ticks see `activeScale =
%% Nothing`; Degree pitches drop until a new `set-scale` arrives.
clear_scale() ->
    ensure_table(),
    ets:delete(?TABLE, ?KEY),
    ok.

%% Return the active scale as a purerl-encoded `Maybe Scale`.  Pushed
%% into the per-tick `Window.activeScale` by `tidal_clock`.
current_scale() ->
    ensure_table(),
    case ets:lookup(?TABLE, ?KEY) of
        [{?KEY, ScaleVal, _Name}] -> {just, ScaleVal};
        [] -> {nothing}
    end.

%% Return the active scale's wire-side name as a binary, or
%% `undefined` if no scale is set.  Used by the `state` verb to
%% report what's active.
current_scale_name() ->
    ensure_table(),
    case ets:lookup(?TABLE, ?KEY) of
        [{?KEY, _ScaleVal, Name}] -> Name;
        [] -> undefined
    end.
