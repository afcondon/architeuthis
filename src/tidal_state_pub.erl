%% @doc State publisher — produces the JSON snapshot Calypso reads
%% via the `state` verb.
%%
%% Replaces `Tidal.MIDIScheduler.publishState` (PR1.7c). On a 100ms
%% timer (10 Hz) this gen_server gathers data from `tidal_clock`
%% (bpm / tickInterval / lookAhead) and `tidal_dispatcher` (bindings
%% / continuousBindings / midiDevices / fh2VoiceChannels / gate*),
%% feeds them to `Tidal.StatePublisher.serializeSnapshot`, and writes
%% the resulting JSON string to the StateBus ETS row Calypso reads.
%%
%% No state of its own — just a timer + two synchronous gen_server
%% calls per tick. Cheap.
%%
%% Snapshot is eventually consistent: the dispatcher and clock are
%% sampled separately, so a snapshot can show a clock-tick advance
%% without the dispatch state from that tick yet, or vice versa.
%% Acceptable for a debug-view JSON; documented in
%% `docs/per-voice-refactor-plan.md` §5.
-module(tidal_state_pub).
-behaviour(gen_server).

-export([start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-define(PUBLISH_INTERVAL_MS, 100).

%% =========================================================================
%% Public API
%% =========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:stop(?MODULE).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init([]) ->
    %% Idempotent — ETS table created here when MIDIScheduler used to
    %% own it; carried over so a single owner exists for the lifetime
    %% of the publisher. (The actual table is named, public, set —
    %% read by the WS handler's `state` verb.)
    ('tidal_stateBus@foreign':init())(),
    erlang:send_after(?PUBLISH_INTERVAL_MS, self(), publish),
    {ok, []}.

handle_info(publish, State) ->
    publish_now(),
    erlang:send_after(?PUBLISH_INTERVAL_MS, self(), publish),
    {noreply, State};
handle_info(_Other, State) ->
    {noreply, State}.

handle_call(_Msg, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

%% =========================================================================
%% Internal
%% =========================================================================

publish_now() ->
    %% gen_server / gen_statem calls — synchronous; serialise the
    %% reads but don't block dispatch (the dispatcher's call cost is
    %% trivial; clock's get_info ditto).
    ClockInfo = tidal_clock:get_info(),
    DispSnap = tidal_dispatcher:get_publisher_snapshot(),
    Inputs = #{clock => ClockInfo, dispatcher => DispSnap},
    Json = ('tidal_statePublisher@ps':serializeSnapshot(Inputs)),
    ('tidal_stateBus@foreign':write(Json))().
