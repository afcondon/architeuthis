%% @doc The stage — what each instrument on the rig has loaded now.
%%
%% The library (Amphora) holds what exists; the stage holds what is
%% playing, edits included, and tells every subscribed page when it
%% changes. A page is then a view of the stage rather than the owner of
%% its state: a tab opened mid-set shows what is playing, and two tabs of
%% one app stay in step. Design: docs/kb/plans/the-stage.md.
%%
%% One entry per slot (`conspicillum` today; one slot per app until a
%% second instance of one is wanted):
%%
%%   base    — the Amphora hash it was loaded from, or null
%%   edited  — whether it differs from base (the page knows; the rig
%%             never fetches from Amphora)
%%   page    — what the page needs to show it again: opaque to the rig
%%   playing — whether the slot's voice is running
%%   by      — the id of the page that last changed it
%%   at      — when, in ms since the epoch
%%
%% The scene the voice plays is NOT kept here or announced: pages rebuild
%% it from `page`, and it can be large (a whole corpus).
%%
%% Announcements are text frames `stage <json>`, the entry plus its
%% `slot`, sent to every subscriber except the page whose push caused it
%% (a page must only act on what it touched — memory
%% `two-surfaces-one-daemon`). A new subscriber is sent every slot at once.
%%
%% Held in memory: a BEAM restart empties the stage, as it stops the
%% voices. Keeping it across restarts is step 6 of the plan (`stage/last`).
-module(tidal_stage).
-behaviour(gen_server).

-export([start_link/0, subscribe/1, put/3, stopped/1, stopped_all/0, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% =========================================================================
%% Public API — every call is safe when the stage is not running, so a
%% missing stage can never break a push that would otherwise play.
%% =========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Register a WS handler pid; it receives {stage_broadcast, Bin} infos,
%% first one per slot as it stands, then one per change.
subscribe(Pid) -> cast({subscribe, Pid}).

%% A page pushed a slot's scene. Entry is a map with binary keys: base,
%% edited, page, by (any may be absent). From is the pushing handler.
put(Slot, Entry, From) -> cast({put, Slot, Entry, From}).

%% The slot's voice stopped (its stop verb, or hush).
stopped(Slot) -> cast({stopped, Slot}).
stopped_all() -> cast(stopped_all).

%% Every slot, for inspection from a shell.
snapshot() ->
    case whereis(?MODULE) of
        undefined -> #{};
        _ -> gen_server:call(?MODULE, snapshot)
    end.

cast(Message) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:cast(?MODULE, Message)
    end.

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init([]) ->
    {ok, #{slots => #{}, subscribers => #{}}}.

handle_call(snapshot, _From, State = #{slots := Slots}) ->
    {reply, Slots, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({subscribe, Pid}, State = #{slots := Slots, subscribers := Subscribers}) ->
    Subscribers1 = case maps:is_key(Pid, Subscribers) of
        true -> Subscribers;
        false -> Subscribers#{Pid => erlang:monitor(process, Pid)}
    end,
    maps:foreach(fun(Slot, Entry) -> Pid ! {stage_broadcast, frame(Slot, Entry)} end, Slots),
    {noreply, State#{subscribers := Subscribers1}};

handle_cast({put, Slot, Pushed, From}, State = #{slots := Slots}) ->
    Entry = #{base => maps:get(<<"base">>, Pushed, null),
              edited => maps:get(<<"edited">>, Pushed, false),
              page => maps:get(<<"page">>, Pushed, null),
              playing => true,
              by => maps:get(<<"by">>, Pushed, null),
              at => erlang:system_time(millisecond)},
    announce(Slot, Entry, From, State),
    {noreply, State#{slots := Slots#{Slot => Entry}}};

handle_cast({stopped, Slot}, State = #{slots := Slots}) ->
    case maps:find(Slot, Slots) of
        {ok, Entry = #{playing := true}} ->
            Stopped = Entry#{playing := false, at := erlang:system_time(millisecond)},
            announce(Slot, Stopped, none, State),
            {noreply, State#{slots := Slots#{Slot := Stopped}}};
        _ ->
            {noreply, State}
    end;

handle_cast(stopped_all, State = #{slots := Slots}) ->
    State1 = maps:fold(fun(Slot, _, Acc) ->
        {noreply, Next} = handle_cast({stopped, Slot}, Acc),
        Next
    end, State, Slots),
    {noreply, State1};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #{subscribers := Subscribers}) ->
    {noreply, State#{subscribers := maps:remove(Pid, Subscribers)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% =========================================================================
%% Internals
%% =========================================================================

announce(Slot, Entry, Except, #{subscribers := Subscribers}) ->
    Frame = frame(Slot, Entry),
    maps:foreach(fun(Pid, _) when Pid =/= Except -> Pid ! {stage_broadcast, Frame};
                    (_, _) -> ok
                 end, Subscribers).

frame(Slot, Entry) ->
    Json = iolist_to_binary(json:encode(Entry#{slot => atom_to_binary(Slot)})),
    <<"stage ", Json/binary>>.
