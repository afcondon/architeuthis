%% @doc Voice gen_server — one process per bound name.
%%
%% Holds a `Tidal.Voice.State` term and exposes the voice-message API
%% as gen_server calls/casts.
%%
%% The gen_server's State is `{Name, PsState}` — we keep Name at the
%% Erlang level for direct access (used when casting events to the
%% dispatcher) and pass PsState into PureScript helpers for all
%% mutations and queries. PsState is opaque to Erlang — never inspect
%% or pattern-match on it.
%%
%% On `compute_until` the voice calls into Tidal.Voice.computeUntil
%% (pure function returning {newState, events}) and casts each event
%% to tidal_dispatcher. Mute is honored inside computeUntil — events
%% are simply omitted from the result list when muted, so phase still
%% advances but nothing leaves the voice.
%%
%% See `docs/per-voice-refactor-plan.md`.
-module(tidal_voice).
-behaviour(gen_server).

-export([start_link/2,
         set_pattern/2,
         set_continuous_pattern/2,
         install_from_spec/3,
         clear_pattern/1,
         set_muted/2,
         reset_phase/1,
         get_state/1,
         compute_until/2,
         stop/1,
         registered_name/1]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

%% =========================================================================
%% Public API
%% =========================================================================

%% Start a voice. Name is the bound identifier (binary or string).
%% The second arg is a tagged kind:
%%   {discrete, Binding}  — Discrete voice carrying a Tidal.Binding.Binding
%%   {continuous, Dest}   — Continuous voice carrying a Tidal.Binding.ContDest
%%
%% The simple_one_for_one supervisor's start_child hands us the second
%% arg verbatim, so we keep the kind dispatch here on the gen_server's
%% side rather than in the supervisor.
start_link(Name, {discrete, Binding}) ->
    gen_server:start_link({local, registered_name(Name)},
                          ?MODULE, {discrete, Name, Binding}, []);
start_link(Name, {continuous, Dest}) ->
    gen_server:start_link({local, registered_name(Name)},
                          ?MODULE, {continuous, Name, Dest}, []).

set_pattern(Name, Pattern) ->
    gen_server:call(registered_name(Name), {set_pattern, Pattern}).

%% Set the Pattern Number on a Continuous voice. Silent no-op on a
%% Discrete voice — the supervisor's set_voice_cont_pat is the
%% canonical caller and creates Continuous voices via start_link_cont.
set_continuous_pattern(Name, Pattern) ->
    gen_server:call(registered_name(Name),
                    {set_continuous_pattern, Pattern}).

%% Parse a `<name> <pat>` body + its `# <key> <pat>` param segments
%% and install them atomically. ParamSpecs is an Erlang list of maps
%% (#{name => K, pat => P}) — list, NOT array, because the WS handler
%% builds it that way and Tidal.Voice.installFromSpec accepts
%% `Array { name, pat }` which decodes from either.
%%
%% Returns ok on success, {error, Reason} on parse failure of the
%% structure pattern. Param specs that fail to parse are silently
%% dropped (mirroring MIDIScheduler.PlayByName).
install_from_spec(Name, PatStr, ParamSpecs) ->
    gen_server:call(registered_name(Name),
                    {install_from_spec, PatStr, ParamSpecs}).

clear_pattern(Name) ->
    gen_server:call(registered_name(Name), clear_pattern).

set_muted(Name, Muted) ->
    gen_server:cast(registered_name(Name), {set_muted, Muted}).

reset_phase(Name) ->
    gen_server:cast(registered_name(Name), reset_phase).

get_state(Name) ->
    gen_server:call(registered_name(Name), get_state).

%% Window is a map: #{currentCycle, lookAheadCycle, cycleDurationMs,
%% nowUnixUs}. Sent by tidal_clock on each tick.
compute_until(Name, Window) ->
    gen_server:cast(registered_name(Name), {compute_until, Window}).

stop(Name) ->
    gen_server:stop(registered_name(Name)).

registered_name(Name) when is_binary(Name) ->
    list_to_atom("tidal_voice_" ++ binary_to_list(Name));
registered_name(Name) when is_list(Name) ->
    list_to_atom("tidal_voice_" ++ Name);
registered_name(Name) when is_atom(Name) ->
    list_to_atom("tidal_voice_" ++ atom_to_list(Name)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({discrete, Name, Binding}) ->
    PsState = 'tidal_voice@ps':initialState(Name, Binding),
    {ok, {Name, PsState}};
init({continuous, Name, Dest}) ->
    PsState = 'tidal_voice@ps':initialContinuousState(Name, Dest),
    {ok, {Name, PsState}}.

handle_call({set_pattern, P}, _From, {Name, PsState}) ->
    {reply, ok, {Name, 'tidal_voice@ps':setPattern(P, PsState)}};
handle_call({set_continuous_pattern, P}, _From, {Name, PsState}) ->
    {reply, ok, {Name, 'tidal_voice@ps':setContinuousPattern(P, PsState)}};
handle_call({install_from_spec, PatStr, ParamSpecs}, _From, {Name, PsState}) ->
    %% Tidal.Voice.installFromSpec :: String -> Array Spec -> State
    %%   -> Either String State.  PureScript Array compiles to
    %% Erlang's `array` module — convert the incoming list.
    SpecsArr = case ParamSpecs of
        L when is_list(L) -> array:from_list(L);
        A -> A  %% already an array
    end,
    case 'tidal_voice@ps':installFromSpec(PatStr, SpecsArr, PsState) of
        {right, NewPsState} ->
            {reply, ok, {Name, NewPsState}};
        {left, Err} ->
            {reply, {error, Err}, {Name, PsState}}
    end;
handle_call(clear_pattern, _From, {Name, PsState}) ->
    {reply, ok, {Name, 'tidal_voice@ps':clearPattern(PsState)}};
handle_call(get_state, _From, {Name, PsState}) ->
    {reply, 'tidal_voice@ps':snapshot(PsState), {Name, PsState}}.

handle_cast({set_muted, M}, {Name, PsState}) ->
    {noreply, {Name, 'tidal_voice@ps':setMuted(M, PsState)}};
handle_cast(reset_phase, {Name, PsState}) ->
    {noreply, {Name, 'tidal_voice@ps':resetPhase(PsState)}};
handle_cast({compute_until, Window}, {Name, PsState}) ->
    Result = 'tidal_voice@ps':computeUntil(Window, PsState),
    Events = maps:get(events, Result),
    NewPsState = maps:get(newState, Result),
    %% PureScript `Array a` compiles to Erlang's `array` module — not
    %% a plain list. Iterate side-effectingly via array:foldl/3 (the
    %% fold accumulator is unused; this is just a "for each element").
    %%
    %% EventToDispatch is a 2-constructor sum: `{discreteEvent, M}`
    %% or `{continuousEvent, M}`. The tag picks which dispatcher API
    %% to invoke.
    array:foldl(fun(_Idx, E, _) ->
                    case E of
                        {discreteEvent, M} ->
                            tidal_dispatcher:dispatch_event(
                              Name,
                              maps:get(token, M),
                              maps:get(wallTimeUs, M),
                              maps:get(params, M));
                        {continuousEvent, M} ->
                            tidal_dispatcher:dispatch_cont_event(
                              Name,
                              maps:get(value, M),
                              maps:get(wallTimeUs, M))
                    end
                end,
                ok, Events),
    {noreply, {Name, NewPsState}}.

terminate(_Reason, _State) ->
    ok.
