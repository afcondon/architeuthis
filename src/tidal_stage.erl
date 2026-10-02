%% @doc The stage — what each instrument on the rig has loaded now.
%%
%% The library (Amphora) holds what exists; the stage holds what is
%% playing, edits included, and tells every subscribed page when it
%% changes. A page is then a view of the stage rather than the owner of
%% its state: a tab opened mid-set shows what is playing, and two tabs of
%% one app stay in step. Design: docs/kb/plans/the-stage.md.
%%
%% One entry per slot (`conspicillum`, `odonus`, `vetula`, `balistes`,
%% `selene`; one slot per app until a second instance of one is wanted):
%%
%%   base    — the Amphora hash it was loaded from, or null
%%   alias   — the Rebus alias of what is loaded ("cow-ambulance"), or null:
%%             enough for any page to draw its chip
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
%% **Text objects** (docs/kb/plans/text-on-the-stage.md). Beside the
%% slots, the stage holds addressable text: `<slot>/<name>` keys
%% (`vetula/v3`, one Vetula card) to `#{text, ver, at}`, the object's
%% Lepidoptera form. Any page may write one (`put_text`); `ver` counts
%% writes so a view can tell its copy is stale; writing `null` deletes.
%% Text subscribers (`text_subscribe`, a call that returns the whole table)
%% are told of every write by another page as `stage-text <json>`, and of
%% two relayed requests: `stage-open` (show this object, to an editor such
%% as Limulus) and `stage-reject` (the owner could not read a write). The
%% rig never reads the text: the owning page validates it.
%%
%% The slots are held in memory: a BEAM restart empties them, as it stops
%% the voices. The **text objects are kept on disk** (`~/.atlantis/
%% stage-texts.json`, rewritten on every write and read back at start), so
%% what pages and Limulus wrote outlives a restart, and so does what the rig
%% keeps there itself: `balistes/routing`, the drum routing table last
%% pushed, which is handed back to the drum voice at start (restore/2).
-module(tidal_stage).
-behaviour(gen_server).

-export([start_link/0, subscribe/1, put/3, set/3, stopped/1, stopped_all/0, snapshot/0]).
-export([text_subscribe/1, put_text/3, relay/3, valid_key/1]).
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

%% A page recorded its machine's slot directly (stage-put): the same fields,
%% plus `playing` as the page says, since no scene push started a voice.
set(Slot, Entry, From) -> cast({set, Slot, Entry, From}).

%% The slot's voice stopped (its stop verb, or hush).
stopped(Slot) -> cast({stopped, Slot}).
stopped_all() -> cast(stopped_all).

%% Every slot, for inspection from a shell.
snapshot() ->
    case whereis(?MODULE) of
        undefined -> #{};
        _ -> gen_server:call(?MODULE, snapshot)
    end.

%% Subscribe to the text objects; returns every one now, as a map from key
%% to #{text, ver}. Later writes by other pages arrive as {stage_broadcast, Bin}.
text_subscribe(Pid) -> call({text_subscribe, Pid}, #{}).

%% Write (or, with null, delete) a text object. Returns the new version.
put_text(Key, Text, From) -> call({put_text, Key, Text, From}, 0).

%% Relay a request about an object to every other text subscriber:
%% Kind is <<"stage-open">> or <<"stage-reject">>, Fields a map.
relay(Kind, Fields, From) -> cast({relay, Kind, Fields, From}).

%% `<slot>/<name>`: a known slot, then letters, digits and `/_-.`.
valid_key(Key) ->
    case binary:split(Key, <<"/">>) of
        [Slot, Name] when Name =/= <<>> ->
            lists:member(Slot, [<<"odonus">>, <<"vetula">>, <<"balistes">>, <<"selene">>, <<"conspicillum">>])
                andalso lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
                                             orelse (C >= $0 andalso C =< $9) orelse lists:member(C, "/_-.")
                                  end, binary_to_list(Name));
        _ -> false
    end.

call(Message, Default) ->
    case whereis(?MODULE) of
        undefined -> Default;
        _ -> gen_server:call(?MODULE, Message)
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
    Texts = load_texts(),
    maps:foreach(fun(Key, #{text := T}) -> restore(Key, T) end, Texts),
    {ok, #{slots => #{}, subscribers => #{}, texts => Texts, text_subscribers => #{}}}.

%% Rig state kept as a text object, handed back at start.
restore(<<"balistes/routing">>, Json) -> catch reef_balistes_voice:set_routing_json(Json);
restore(_, _) -> ok.

texts_file() ->
    case os:getenv("HOME") of
        false -> "/tmp/atlantis-stage-texts.json";
        Home -> filename:join([Home, ".atlantis", "stage-texts.json"])
    end.

load_texts() ->
    try
        {ok, Bin} = file:read_file(texts_file()),
        maps:fold(fun(Key, #{<<"text">> := T, <<"ver">> := V} = E, Acc) when is_binary(T), is_integer(V) ->
                          Acc#{Key => #{text => T, ver => V, at => maps:get(<<"at">>, E, 0)}};
                     (_, _, Acc) -> Acc
                  end, #{}, json:decode(Bin))
    catch _:_ -> #{}
    end.

%% Written whole, to a temporary file then renamed, so a crash mid-write
%% leaves the previous table rather than half of one.
save_texts(Texts) ->
    File = texts_file(),
    try
        ok = filelib:ensure_dir(File),
        Tmp = File ++ ".tmp",
        ok = file:write_file(Tmp, json:encode(Texts)),
        ok = file:rename(Tmp, File)
    catch Class:Why -> logger:warning("tidal_stage: could not save texts: ~p:~p", [Class, Why])
    end.

handle_call(snapshot, _From, State = #{slots := Slots}) ->
    {reply, Slots, State};
handle_call({text_subscribe, Pid}, _From, State = #{texts := Texts, text_subscribers := Subs}) ->
    Subs1 = case maps:is_key(Pid, Subs) of
        true -> Subs;
        false -> Subs#{Pid => erlang:monitor(process, Pid)}
    end,
    Table = maps:map(fun(_, #{text := T, ver := V}) -> #{text => T, ver => V} end, Texts),
    {reply, Table, State#{text_subscribers := Subs1}};
handle_call({put_text, Key, Text, From}, _From, State = #{texts := Texts}) ->
    Ver = case maps:find(Key, Texts) of
        {ok, #{ver := V}} -> V + 1;
        error -> 1
    end,
    Texts1 = case Text of
        null -> maps:remove(Key, Texts);
        _ -> Texts#{Key => #{text => Text, ver => Ver, at => erlang:system_time(millisecond)}}
    end,
    text_announce(<<"stage-text">>, #{key => Key, text => Text, ver => Ver}, From, State),
    save_texts(Texts1),
    {reply, Ver, State#{texts := Texts1}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({subscribe, Pid}, State = #{slots := Slots, subscribers := Subscribers}) ->
    Subscribers1 = case maps:is_key(Pid, Subscribers) of
        true -> Subscribers;
        false -> Subscribers#{Pid => erlang:monitor(process, Pid)}
    end,
    maps:foreach(fun(Slot, Entry) -> Pid ! {stage_broadcast, frame(Slot, Entry)} end, Slots),
    {noreply, State#{subscribers := Subscribers1}};

handle_cast({put, Slot, Pushed, From}, State) ->
    record(Slot, entry(Pushed, true), From, State);

handle_cast({set, Slot, Pushed, From}, State) ->
    record(Slot, entry(Pushed, maps:get(<<"playing">>, Pushed, false) =:= true), From, State);

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

handle_cast({relay, Kind, Fields, From}, State) ->
    text_announce(Kind, Fields, From, State),
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #{subscribers := Subscribers, text_subscribers := Subs}) ->
    {noreply, State#{subscribers := maps:remove(Pid, Subscribers), text_subscribers := maps:remove(Pid, Subs)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% =========================================================================
%% Internals
%% =========================================================================

entry(Pushed, Playing) ->
    #{base => maps:get(<<"base">>, Pushed, null),
      alias => maps:get(<<"alias">>, Pushed, null),
      edited => maps:get(<<"edited">>, Pushed, false),
      page => maps:get(<<"page">>, Pushed, null),
      playing => Playing,
      by => maps:get(<<"by">>, Pushed, null),
      at => erlang:system_time(millisecond)}.

record(Slot, Entry, From, State = #{slots := Slots}) ->
    announce(Slot, Entry, From, State),
    {noreply, State#{slots := Slots#{Slot => Entry}}}.

announce(Slot, Entry, Except, #{subscribers := Subscribers}) ->
    Frame = frame(Slot, Entry),
    maps:foreach(fun(Pid, _) when Pid =/= Except -> Pid ! {stage_broadcast, Frame};
                    (_, _) -> ok
                 end, Subscribers).

text_announce(Kind, Fields, Except, #{text_subscribers := Subs}) ->
    Json = iolist_to_binary(json:encode(Fields)),
    Frame = <<Kind/binary, " ", Json/binary>>,
    maps:foreach(fun(Pid, _) when Pid =/= Except -> Pid ! {stage_broadcast, Frame};
                    (_, _) -> ok
                 end, Subs).

frame(Slot, Entry) ->
    Json = iolist_to_binary(json:encode(Entry#{slot => atom_to_binary(Slot)})),
    <<"stage ", Json/binary>>.
