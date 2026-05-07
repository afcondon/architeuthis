%% @doc Voice gen_server — one process per bound name.
%%
%% Holds a `Tidal.Voice.State` term and exposes the voice-message API as
%% gen_server calls/casts.
%%
%% PR1.2 introduces this module as scaffolding only. State-mutation
%% messages work; `compute_until` is a no-op until PR1.4 wires the
%% pattern-query + dispatch loop migrating from MIDIScheduler. See
%% `docs/per-voice-refactor-plan.md`.
%%
%% Process registration: each voice registers as `tidal_voice_<name>`.
%% Bound names come from the user (`bind bass ...`); atom-creation cost
%% is bounded by the binding count, not request volume — atom-table
%% pressure isn't a concern at the rig's scale.
-module(tidal_voice).
-behaviour(gen_server).

-export([start_link/2,
         set_pattern/2,
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
%% Binding is a `Tidal.Binding.Binding` term (an array of PrimAction
%% tuples).
start_link(Name, Binding) ->
    gen_server:start_link({local, registered_name(Name)},
                          ?MODULE, {Name, Binding}, []).

set_pattern(Name, Pattern) ->
    gen_server:call(registered_name(Name), {set_pattern, Pattern}).

clear_pattern(Name) ->
    gen_server:call(registered_name(Name), clear_pattern).

set_muted(Name, Muted) ->
    gen_server:cast(registered_name(Name), {set_muted, Muted}).

reset_phase(Name) ->
    gen_server:cast(registered_name(Name), reset_phase).

get_state(Name) ->
    gen_server:call(registered_name(Name), get_state).

compute_until(Name, T) ->
    gen_server:cast(registered_name(Name), {compute_until, T}).

stop(Name) ->
    gen_server:stop(registered_name(Name)).

%% Build the registered atom for a voice name. Exported because
%% tidal_voice_sup needs the same mapping.
registered_name(Name) when is_binary(Name) ->
    list_to_atom("tidal_voice_" ++ binary_to_list(Name));
registered_name(Name) when is_list(Name) ->
    list_to_atom("tidal_voice_" ++ Name);
registered_name(Name) when is_atom(Name) ->
    list_to_atom("tidal_voice_" ++ atom_to_list(Name)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({Name, Binding}) ->
    State = 'tidal_voice@ps':initialState(Name, Binding),
    {ok, State}.

handle_call({set_pattern, P}, _From, State) ->
    {reply, ok, 'tidal_voice@ps':setPattern(P, State)};
handle_call(clear_pattern, _From, State) ->
    {reply, ok, 'tidal_voice@ps':clearPattern(State)};
handle_call(get_state, _From, State) ->
    {reply, 'tidal_voice@ps':snapshot(State), State}.

handle_cast({set_muted, M}, State) ->
    {noreply, 'tidal_voice@ps':setMuted(M, State)};
handle_cast(reset_phase, State) ->
    {noreply, 'tidal_voice@ps':resetPhase(State)};
%% compute_until is a no-op at PR1.2. The pattern query + event dispatch
%% loop migrates from MIDIScheduler in PR1.4. The cast is accepted now so
%% the clock can broadcast unconditionally once it exists in PR1.3.
handle_cast({compute_until, _T}, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
