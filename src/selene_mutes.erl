%% @doc Selene's mute patterns, kept in step with the rack.
%%
%% A bank may carry `# mute "<~ 1 [1,2] 2>"`: a mini-notation pattern of its
%% slots (1..8, or `all`), each silent while the pattern names it (AC,
%% 2026-10-26: "unmuting a modulation signal every few bars, muting first one
%% kick then the other"). The rack on the stage (`selene/rack`) is the one
%% place it lives, so this process subscribes to the stage, as selene_retrig
%% does, and keeps one `{mutes, Socket, Bank}` stream per pattern
%% (tidal_dirt_voice, Tidal.MuteVoice). The stream works out, a window ahead,
%% each moment the set of muted slots changes, and has this process told at
%% that moment; this process then sends the bank to its daemon with those
%% slots silent (reef's Reef.Selene.Line.mutedApply), on top of the rack's
%% own mutes.
%%
%% A pattern's mute is an act, not a setting: the rack is not changed, and
%% selene_keeper keeps the rack's version of the bank. So when the rack
%% changes (the page or a line applies the bank as the rack has it) the set
%% in force is sent again just after, and when a pattern goes the bank is
%% sent as the rack has it.
%%
%% Timing: a change is sent when it falls, and the daemon applies it on
%% arrival, so a mute lands as late as the daemon is slow: the FH-2's is
%% audible but stays in time (AC, 2026-10-26). Sending early by a measured
%% lead per daemon is the next step if it matters.
%%
%% Every page is told what each pattern is muting, when it changes, as
%% `muting selene {"banks":[{"socket","bank","pattern","muted":[1,2]}]}`, so
%% the page draws the pattern's mutes as they are heard; `selene-mutes` asks
%% for it (a page just opened).
%%
%% `selene $ hush` silences the patterns and play brings them back, as for
%% selene_retrig. A pattern that does not parse plays nothing and is logged;
%% a `selene $` line is checked before it is kept (check/1).
-module(selene_mutes).
-behaviour(gen_server).

-export([start_link/0, hush/0, play/0, check/1, running/0, change/3, state/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RACK, <<"selene/rack">>).
%% after a rack change, how long until the set in force is sent again, so it
%% lands after the rack's own apply of the bank
-define(AFTER_RACK_MS, 300).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

hush() -> cast(hush).
play() -> cast(play).

%% What is playing, {Socket, Bank} => Pattern, for inspection from a shell.
running() -> gen_server:call(?MODULE, running).

%% What every page is told: `muting selene <json>`.
state() ->
    case whereis(?MODULE) of
        undefined -> told(#{running => #{}, muted => #{}});
        _ -> gen_server:call(?MODULE, state)
    end.

%% From a mute stream: Muted (a PureScript array of slots) is in force from
%% now on that bank.
change(Socket, Bank, Muted) -> cast({change, Socket, Bank, Muted}).

%% Whether a rack's mute patterns all parse: ok, or {error, Why}.
check(Rack) ->
    Bad = [P || #{pattern := P} <- mutes(Rack), parse(P) =:= error],
    case Bad of
        [] -> ok;
        [P | _] -> {error, <<"mute: not a pattern: ", P/binary>>}
    end.

cast(Msg) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:cast(?MODULE, Msg)
    end.

init([]) ->
    Table = tidal_stage:text_subscribe(self()),
    Rack = case maps:get(?RACK, Table, undefined) of
               #{text := T} when is_binary(T) -> T;
               _ -> <<>>
           end,
    {ok, reconcile(#{rack => Rack, running => #{}, muted => #{},
                     hushed => not selene_keeper:running()})}.

handle_call(running, _From, St = #{running := R}) ->
    {reply, R, St};
handle_call(state, _From, St) ->
    {reply, told(St), St};
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(hush, St) ->
    {noreply, reconcile(St#{hushed := true})};
handle_cast(play, St) ->
    St1 = reconcile(St#{hushed := false}),
    %% selene_keeper has just sent every bank as the rack has it
    erlang:send_after(?AFTER_RACK_MS, self(), resend),
    {noreply, St1};
handle_cast({change, Socket, Bank, Muted}, St = #{running := R, muted := M, hushed := false}) ->
    Key = {Socket, Bank},
    case maps:is_key(Key, R) of
        true ->
            send(St, Key, Muted),
            {noreply, tell(St#{muted := M#{Key => Muted}})};
        false ->
            {noreply, St}
    end;
handle_cast(_Message, St) ->
    {noreply, St}.

handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := ?RACK, <<"text">> := T} when is_binary(T) ->
            erlang:send_after(?AFTER_RACK_MS, self(), resend),
            {noreply, reconcile(St#{rack := T})};
        #{<<"key">> := ?RACK} ->
            {noreply, reconcile(St#{rack := <<>>})};
        _ ->
            {noreply, St}
    end;
%% the rack's own apply of a bank undoes a pattern's mutes: put them back
handle_info(resend, St = #{muted := M, hushed := false}) ->
    [send(St, Key, Muted) || {Key, Muted} <- maps:to_list(M), array:size(Muted) > 0],
    {noreply, St};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%% Make the running streams what the rack asks for (none while hushed). A
%% bank whose pattern goes is sent as the rack has it.
reconcile(St = #{rack := Rack, running := Running, muted := M, hushed := Hushed}) ->
    Wanted = case Hushed of
                 true -> #{};
                 false -> maps:from_list([{{S, B}, P} || #{socket := S, bank := B, pattern := P} <- mutes(Rack)])
             end,
    Gone = [K || K <- maps:keys(Running), not maps:is_key(K, Wanted)],
    [set(K, 'tidal_pattern_types@ps':silence()) || K <- Gone],
    [send(St, K, array:new()) || K <- Gone, not Hushed, array:size(maps:get(K, M, array:new())) > 0],
    Now = maps:fold(
            fun(K, P, Acc) ->
                    case maps:get(K, Running, undefined) of
                        P -> Acc#{K => P};
                        _ ->
                            case parse(P) of
                                {ok, Pattern} -> set(K, Pattern), Acc#{K => P};
                                error ->
                                    tidal_log:err("selene_mutes: not a pattern on ~p: ~ts~n", [K, P]),
                                    set(K, 'tidal_pattern_types@ps':silence()),
                                    Acc
                            end
                    end
            end, #{}, Wanted),
    St1 = St#{running := Now, muted := maps:with(maps:keys(Now), M)},
    case St1 of
        #{running := Running, muted := M} -> St1;
        _ -> tell(St1)
    end.

%% Every page told what the patterns are muting.
tell(St) ->
    catch tidal_link_anchor:sync_broadcast(told(St)),
    St.

told(#{running := R, muted := M}) ->
    Banks = [#{socket => S, bank => B, pattern => P,
               muted => array:to_list(maps:get({S, B}, M, array:new()))}
             || {{S, B}, P} <- lists:sort(maps:to_list(R))],
    iolist_to_binary([<<"muting selene ">>, json:encode(#{banks => Banks})]).

set({Socket, Bank}, Pattern) ->
    catch tidal_dirt_voice_sup:set({mutes, Socket, Bank}, Pattern).

%% The bank to its daemon with Muted silent as well as the rack's own mutes.
send(#{rack := Rack}, {Socket, Bank}, Muted) ->
    case catch 'reef_selene_line@ps':mutedApply(Rack, Socket, Bank, Muted) of
        {just, #{command := Command}} ->
            case call(path(Socket), Command) of
                {ok, <<"OK", _/binary>>} -> ok;
                Other -> tidal_log:err("selene_mutes: ~ts ~ts: ~p~n", [Socket, Bank, Other])
            end;
        _ -> ok
    end.

mutes(Rack) ->
    case catch 'reef_selene_line@ps':mutesOf(Rack) of
        L when is_tuple(L) -> array:to_list(L);
        L when is_list(L) -> L;
        _ -> []
    end.

parse(P) ->
    case catch 'tidal_line@ps':parseLine(<<"d1 $ s \"", P/binary, "\"">>) of
        {right, {play, _, Pattern}} -> {ok, Pattern};
        _ -> error
    end.

path(<<"fh2">>) -> home(".fh2/control.sock", "/tmp/fh2-control.sock");
path(_) -> home(".es9/control.sock", "/tmp/es9-control.sock").

home(Rel, Fallback) ->
    case os:getenv("HOME") of
        false -> Fallback;
        Home -> filename:join(Home, Rel)
    end.

call(SockPath, Command) ->
    case gen_tcp:connect({local, SockPath}, 0, [{active, false}, binary, {packet, line}], 1000) of
        {ok, Sock} ->
            try
                ok = gen_tcp:send(Sock, [Command, $\n]),
                case gen_tcp:recv(Sock, 0, 5000) of
                    {ok, Reply} -> {ok, string:trim(Reply)};
                    E -> E
                end
            after gen_tcp:close(Sock)
            end;
        E -> E
    end.
