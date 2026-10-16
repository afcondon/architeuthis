%% @doc Selene's reset patterns, kept in step with the rack.
%%
%% An FH-2 LFO bank may carry `# retrig "<pattern>"` (a mini-notation pattern
%% of slots, 1..8 or `all`). The rack on the stage (`selene/rack`) is the one
%% place it lives, written by the Selene page and by `selene $` lines alike, so
%% this process subscribes to the stage and, on every rack, starts, changes or
%% silences one `{retrig, Base}` stream per bank (tidal_dirt_voice), reading
%% the patterns with reef (Reef.Selene.Line.retrigsOf) and each pattern as
%% `s "<pattern>"` with Littorina's line parser.
%%
%% `selene $ hush` silences them all and keeps them silent through later rack
%% writes; `selene $ play` brings them back from the rack as it then is. A
%% pattern that does not parse plays nothing and is logged; a `selene $` line
%% is checked before it is kept (check/1), so a line cannot leave one behind.
-module(selene_retrig).
-behaviour(gen_server).

-export([start_link/0, hush/0, play/0, check/1, running/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RACK, <<"selene/rack">>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

hush() -> cast(hush).
play() -> cast(play).

%% What is playing, Base => Pattern, for inspection from a shell.
running() -> gen_server:call(?MODULE, running).

%% Whether a rack's reset patterns all parse: ok, or {error, Why}.
check(Rack) ->
    Bad = [{B, P} || #{base := B, pattern := P} <- retrigs(Rack), parse(P) =:= error],
    case Bad of
        [] -> ok;
        [{_, P} | _] -> {error, <<"retrig: not a pattern: ", P/binary>>}
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
    {ok, reconcile(#{rack => Rack, running => #{}, hushed => false})}.

handle_call(running, _From, St = #{running := R}) ->
    {reply, R, St};
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(hush, St) ->
    {noreply, reconcile(St#{hushed := true})};
handle_cast(play, St) ->
    {noreply, reconcile(St#{hushed := false})};
handle_cast(_Message, St) ->
    {noreply, St}.

handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := ?RACK, <<"text">> := T} when is_binary(T) ->
            {noreply, reconcile(St#{rack := T})};
        #{<<"key">> := ?RACK} ->
            {noreply, reconcile(St#{rack := <<>>})};
        _ ->
            {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%% Make the running streams what the rack asks for (none while hushed).
reconcile(St = #{rack := Rack, running := Running, hushed := Hushed}) ->
    Wanted = case Hushed of
                 true -> #{};
                 false -> maps:from_list([{B, P} || #{base := B, pattern := P} <- retrigs(Rack)])
             end,
    Gone = [B || B <- maps:keys(Running), not maps:is_key(B, Wanted)],
    [set(B, 'tidal_pattern_types@ps':silence()) || B <- Gone],
    Now = maps:fold(
            fun(B, P, Acc) ->
                    case maps:get(B, Running, undefined) of
                        P -> Acc#{B => P};
                        _ ->
                            case parse(P) of
                                {ok, Pattern} -> set(B, Pattern), Acc#{B => P};
                                error ->
                                    tidal_log:err("selene_retrig: not a pattern on output ~p: ~ts~n", [B, P]),
                                    set(B, 'tidal_pattern_types@ps':silence()),
                                    Acc
                            end
                    end
            end, #{}, Wanted),
    St#{running := Now}.

set(Base, Pattern) ->
    catch tidal_dirt_voice_sup:set({retrig, Base}, Pattern).

retrigs(Rack) ->
    case catch 'reef_selene_line@ps':retrigsOf(Rack) of
        L when is_tuple(L) -> array:to_list(L);
        L when is_list(L) -> L;
        _ -> []
    end.

parse(P) ->
    case catch 'tidal_line@ps':parseLine(<<"d1 $ s \"", P/binary, "\"">>) of
        {right, {play, _, Pattern}} -> {ok, Pattern};
        _ -> error
    end.
