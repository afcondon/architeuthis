%% @doc Dispatcher — gen_server owning OSC output for voice events.
%%
%% Voices push events here as `{event, BindingName, Token, WallTimeUs}`
%% casts. The dispatcher looks up the binding's destination(s), formats
%% the OSC payload(s), and sends to link-spike / cv-router.
%%
%% PR1.3: scaffolding only. The state holds a counter; events are
%% accepted and logged via `tidal_log`. The bridge_client / osc_client
%% handles, the binding registry, and the per-PrimAction format/send
%% code all migrate from MIDIScheduler in PR1.4 — that's where
%% MIDIScheduler is dismantled. See `docs/per-voice-refactor-plan.md`.
%%
%% Why a dedicated dispatcher process: it owns the OSC sockets. Erlang
%% UDP ports are linked to their owning process and close when that
%% process exits — so socket lifetime tracks dispatcher lifetime, which
%% is supervised. (Same reason the existing socket-open code lives
%% inside MIDIScheduler's spawn closure.) Concentrating OSC sends in
%% one process also gives the option later to add per-destination
%% pacing / throttling without touching voices.
-module(tidal_dispatcher).
-behaviour(gen_server).

-export([start_link/0,
         dispatch_event/3,
         get_info/0,
         stop/0]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

%% =========================================================================
%% Public API
%% =========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Voices cast events here. PR1.3: just counts; PR1.4 routes.
dispatch_event(BindingName, Token, WallTimeUs) ->
    gen_server:cast(?MODULE, {event, BindingName, Token, WallTimeUs}).

get_info() ->
    gen_server:call(?MODULE, get_info).

stop() ->
    gen_server:stop(?MODULE).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init([]) ->
    {ok, 'tidal_dispatcher@ps':initialState()}.

handle_call(get_info, _From, State) ->
    {reply, 'tidal_dispatcher@ps':snapshot(State), State}.

handle_cast({event, BindingName, Token, WallTimeUs}, State) ->
    %% PR1.3: log the event for verification, increment counter.
    %% PR1.4 replaces this with the real route+format+send pipeline.
    tidal_log:debug("dispatcher: ~s/~s @ ~p~n",
                    [BindingName, Token, WallTimeUs]),
    {noreply, 'tidal_dispatcher@ps':recordEvent(State)}.

terminate(_Reason, _State) -> ok.
