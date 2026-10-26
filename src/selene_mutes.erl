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
%% Patterns of voltages are kept the same way (AC, 2026-10-26: to step
%% Obsidian's MODEL from Selene). A POLYVOLT output may follow
%% `# volts 3 "<0 1.2 2.5>"`; each bank with any gets one `{volts, Socket,
%% Bank}` stream (Tidal.VoltVoice) holding them all, which has this process
%% told the voltages at each step, and every send of the bank carries both
%% its mutes and its voltages (reef's Reef.Selene.Line.heldApply). The page
%% is told the voltages too, in the same message, as
%% `"volts":[{"socket","bank","slot","pattern","volts"}]`.
%%
%% `selene $ hush` silences the patterns and play brings them back, as for
%% selene_retrig. A pattern that does not parse plays nothing and is logged;
%% a `selene $` line is checked before it is kept (check/1).
-module(selene_mutes).
-behaviour(gen_server).

-export([start_link/0, hush/0, play/0, check/1, running/0, change/3, volts_change/3, state/0, command_for/4]).
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

%% The daemon command that sends Bank as Rack has it, with the mutes its
%% pattern holds at this moment on top, so a bank with a mute pattern is never
%% sent unmuted (AC, 2026-10-26: every evaluation of a `# mute` line let the
%% other voices leak for about a beat, between the line's own apply and the
%% pattern's mutes 300 ms later). A pattern new to Rack is worked out now, on
%% its stream's clock, and started. Command is returned unchanged when the
%% bank has no pattern, Selene is stopped, or Command is not one apply.
command_for(Rack, Socket, Bank, Command) ->
    case {whereis(?MODULE), binary:match(Command, <<"\n">>), Command} of
        {Pid, nomatch, <<"apply-polysignal ", _/binary>>} when is_pid(Pid) ->
            case catch gen_server:call(?MODULE, {command_for, Rack, Socket, Bank}, 5000) of
                C when is_binary(C) -> C;
                _ -> Command
            end;
        _ -> Command
    end.

%% What every page is told: `muting selene <json>`.
state() ->
    case whereis(?MODULE) of
        undefined -> told(#{running => #{}, muted => #{}});
        _ -> gen_server:call(?MODULE, state)
    end.

%% From a mute stream: Muted (a PureScript array of slots) is in force from
%% now on that bank.
change(Socket, Bank, Muted) -> cast({change, Socket, Bank, Muted}).

%% From a volt stream: Volts (a PureScript array of {slot, volts}) are held
%% from now on that bank.
volts_change(Socket, Bank, Volts) -> cast({volts_change, Socket, Bank, Volts}).

%% Whether a rack's mute patterns and patterns of voltages all parse: ok, or
%% {error, Why}.
check(Rack) ->
    BadMute = [P || #{pattern := P} <- mutes(Rack), parse(P) =:= error],
    BadVolts = [P || #{pattern := P} <- volt_patterns(Rack), parse_volts(P) =:= error],
    case {BadMute, BadVolts} of
        {[P | _], _} -> {error, <<"mute: not a pattern: ", P/binary>>};
        {[], [P | _]} -> {error, <<"volts: not a pattern of voltages: ", P/binary>>};
        _ -> ok
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
                     vrunning => #{}, volts => #{},
                     hushed => not selene_keeper:running()})}.

handle_call(running, _From, St = #{running := R}) ->
    {reply, R, St};
handle_call(state, _From, St) ->
    {reply, told(St), St};
handle_call({command_for, _, _, _}, _From, St = #{hushed := true}) ->
    {reply, none, St};
handle_call({command_for, Rack, Socket, Bank}, _From, St = #{running := R, muted := M, vrunning := VR, volts := V}) ->
    Key = {Socket, Bank},
    MuteP = [P || #{socket := S, bank := B, pattern := P} <- mutes(Rack), {S, B} =:= Key],
    VoltP = volts_wanted(Rack, Key),
    case {MuteP, VoltP} of
        {[], []} -> {reply, none, St};
        _ ->
            {R1, M1} = case MuteP of
                           [P | _] ->
                               %% asked of the stream, not taken from what this
                                               %% process last heard: a change can fall while
                                               %% a new stream waits for its clock
                               Muted = case maps:get(Key, R, undefined) of
                                           P -> ask_muted(Key, P, maps:get(Key, M, array:new()));
                                           _ -> now_muted(Key, P, maps:get(Key, M, array:new()))
                                       end,
                               {R#{Key => P}, M#{Key => Muted}};
                           [] -> {R, M}
                       end,
            {VR1, V1} = case VoltP of
                            [] -> {VR, V};
                            _ ->
                                Held = case maps:get(Key, VR, undefined) of
                                           VoltP -> ask_volts(Key, VoltP, maps:get(Key, V, array:new()));
                                           _ -> now_volts(Key, VoltP, maps:get(Key, V, array:new()))
                                       end,
                                {VR#{Key => VoltP}, V#{Key => Held}}
                        end,
            St1 = St#{running := R1, muted := M1, vrunning := VR1, volts := V1},
            case held_apply(St1#{rack := Rack}, Key) of
                {just, #{command := C}} -> {reply, C, tell(St1)};
                _ -> {reply, none, St}
            end
    end;
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(hush, St) ->
    {noreply, reconcile(St#{hushed := true})};
handle_cast(play, St) ->
    St1 = reconcile(St#{hushed := false}),
    %% selene_keeper sends every bank next, through command_for; this resend
    %% is a backstop
    erlang:send_after(?AFTER_RACK_MS, self(), resend),
    {noreply, St1};
handle_cast({change, Socket, Bank, Muted}, St = #{running := R, muted := M, hushed := false}) ->
    Key = {Socket, Bank},
    case {maps:is_key(Key, R), maps:get(Key, M, undefined)} of
        %% already in force (the line that set the pattern sent it): nothing
        {true, Muted} -> {noreply, St};
        {true, _} ->
            St1 = St#{muted := M#{Key => Muted}},
            send(St1, Key),
            {noreply, tell(St1)};
        _ ->
            {noreply, St}
    end;
handle_cast({volts_change, Socket, Bank, Volts}, St = #{vrunning := VR, volts := V, hushed := false}) ->
    Key = {Socket, Bank},
    case {maps:is_key(Key, VR), maps:get(Key, V, undefined)} of
        {true, Volts} -> {noreply, St};
        {true, _} ->
            St1 = St#{volts := V#{Key => Volts}},
            send(St1, Key),
            {noreply, tell(St1)};
        _ ->
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
handle_info(resend, St = #{muted := M, volts := V, hushed := false}) ->
    Keys = lists:usort([K || {K, Muted} <- maps:to_list(M), array:size(Muted) > 0] ++ maps:keys(V)),
    [send(St, Key) || Key <- Keys],
    {noreply, St};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%% Make the running streams what the rack asks for (none while hushed). A
%% bank whose pattern goes is sent as the rack has it.
reconcile(St0) ->
    reconcile_volts(reconcile_mutes(St0)).

reconcile_mutes(St = #{rack := Rack, running := Running, muted := M, hushed := Hushed}) ->
    Wanted = case Hushed of
                 true -> #{};
                 false -> maps:from_list([{{S, B}, P} || #{socket := S, bank := B, pattern := P} <- mutes(Rack)])
             end,
    Gone = [K || K <- maps:keys(Running), not maps:is_key(K, Wanted)],
    [set(K, 'tidal_pattern_types@ps':silence()) || K <- Gone],
    [send(St#{muted := maps:remove(K, M)}, K) || K <- Gone, not Hushed, array:size(maps:get(K, M, array:new())) > 0],
    %% a pattern new or changed is worked out now, so what it mutes is known
    %% before the line that wrote it sends its bank (command_for)
    {Now, M2} = maps:fold(
            fun(K, P, {Acc, MAcc}) ->
                    case maps:get(K, Running, undefined) of
                        P -> {Acc#{K => P}, MAcc};
                        _ ->
                            case parse(P) of
                                {ok, _} ->
                                    {Acc#{K => P}, MAcc#{K => now_muted(K, P, maps:get(K, MAcc, array:new()))}};
                                error ->
                                    tidal_log:err("selene_mutes: not a pattern on ~p: ~ts~n", [K, P]),
                                    set(K, 'tidal_pattern_types@ps':silence()),
                                    {Acc, MAcc}
                            end
                    end
            end, {#{}, M}, Wanted),
    St1 = St#{running := Now, muted := maps:with(maps:keys(Now), M2)},
    case St1 of
        #{running := Running, muted := M} -> St1;
        _ -> tell(St1)
    end.

%% The same for patterns of voltages: a stream a bank, holding every
%% patterned output's pattern. A bank whose patterns all go is sent with the
%% voltages the rack has.
reconcile_volts(St = #{rack := Rack, vrunning := Running, volts := V, hushed := Hushed}) ->
    Wanted = case Hushed of
                 true -> #{};
                 false -> maps:from_list([{K, volts_wanted(Rack, K)} || K <- lists:usort([{S, B} || #{socket := S, bank := B} <- volt_patterns(Rack)])])
             end,
    Gone = [K || K <- maps:keys(Running), not maps:is_key(K, Wanted)],
    [set_volts(K, array:new()) || K <- Gone],
    [send(St#{volts := maps:remove(K, V)}, K) || K <- Gone, not Hushed],
    {Now, V2} = maps:fold(
            fun(K, Ps, {Acc, VAcc}) ->
                    case maps:get(K, Running, undefined) of
                        Ps -> {Acc#{K => Ps}, VAcc};
                        _ ->
                            case [P || {_, P} <- Ps, parse_volts(P) =:= error] of
                                [] ->
                                    {Acc#{K => Ps}, VAcc#{K => now_volts(K, Ps, maps:get(K, VAcc, array:new()))}};
                                [Bad | _] ->
                                    tidal_log:err("selene_mutes: not a pattern of voltages on ~p: ~ts~n", [K, Bad]),
                                    set_volts(K, array:new()),
                                    {Acc, VAcc}
                            end
                    end
            end, {#{}, V}, Wanted),
    St1 = St#{vrunning := Now, volts := maps:with(maps:keys(Now), V2)},
    case St1 of
        #{vrunning := Running, volts := V} -> St1;
        _ -> tell(St1)
    end.

%% A bank's patterned outputs on a rack, [{Slot, Pattern}] by slot.
volts_wanted(Rack, Key) ->
    lists:sort([{Slot, P} || #{socket := S, bank := B, slot := Slot, pattern := P} <- volt_patterns(Rack), {S, B} =:= Key]).

%% Every page told what the patterns are muting.
tell(St) ->
    catch tidal_link_anchor:sync_broadcast(told(St)),
    St.

told(St = #{running := R, muted := M}) ->
    Banks = [#{socket => S, bank => B, pattern => P,
               muted => array:to_list(maps:get({S, B}, M, array:new()))}
             || {{S, B}, P} <- lists:sort(maps:to_list(R))],
    VR = maps:get(vrunning, St, #{}),
    V = maps:get(volts, St, #{}),
    Volts = [#{socket => S, bank => B, slot => Slot, pattern => P,
               volts => held_volts(Slot, maps:get({S, B}, V, array:new()))}
             || {{S, B}, Ps} <- lists:sort(maps:to_list(VR)), {Slot, P} <- Ps],
    iolist_to_binary([<<"muting selene ">>, json:encode(#{banks => Banks, volts => Volts})]).

held_volts(Slot, Held) ->
    case [Vs || #{slot := K, volts := Vs} <- array:to_list(Held), K =:= Slot] of
        [Vs | _] -> Vs;
        [] -> null
    end.

%% What a pattern new to the rack mutes now: started on its stream, and asked
%% on the stream's clock; what was muted before while the stream has no clock.
now_muted(Key, P, Before) ->
    case parse(P) of
        {ok, Pattern} ->
            set(Key, Pattern),
            ask_muted(Key, P, Before);
        error -> Before
    end.

%% What a running mute pattern mutes now, asked on its stream's clock.
ask_muted({Socket, Bank}, P, Before) ->
    case parse(P) of
        {ok, Pattern} ->
            case catch tidal_dirt_voice:muted_now({mutes, Socket, Bank}, Pattern) of
                A when is_tuple(A) -> A;
                _ -> Before
            end;
        error -> Before
    end.

%% What a bank's patterns of voltages hold now: started on its stream, and
%% asked on the stream's clock; what was held before while it has no clock.
now_volts(Key, Ps, Before) ->
    set_volts(Key, volt_array(Ps)),
    ask_volts(Key, Ps, Before).

%% What running patterns of voltages hold now, asked on their stream's clock.
ask_volts({Socket, Bank}, Ps, Before) ->
    case catch tidal_dirt_voice:volts_now({volts, Socket, Bank}, volt_array(Ps)) of
        A when is_tuple(A) -> A;
        _ -> Before
    end.

volt_array(Ps) ->
    array:from_list([#{slot => Slot, pattern => Pat} || {Slot, P} <- Ps, {ok, Pat} <- [parse_volts(P)]]).

set({Socket, Bank}, Pattern) ->
    catch tidal_dirt_voice_sup:set({mutes, Socket, Bank}, Pattern).

set_volts({Socket, Bank}, Patterns) ->
    catch tidal_dirt_voice_sup:set({volts, Socket, Bank}, Patterns).

%% The apply for a bank with the mutes and voltages its patterns hold now.
held_apply(#{rack := Rack, muted := M, volts := V}, Key = {Socket, Bank}) ->
    catch 'reef_selene_line@ps':heldApply(Rack, Socket, Bank, maps:get(Key, M, array:new()), maps:get(Key, V, array:new())).

%% The bank to its daemon with its patterns' mutes and voltages on top of the
%% rack's own.
send(St, Key = {Socket, Bank}) ->
    case held_apply(St, Key) of
        {just, #{command := Command}} ->
            case call(path(Socket), Command) of
                {ok, <<"OK", _/binary>>} -> ok;
                Other -> tidal_log:err("selene_mutes: ~ts ~ts: ~p~n", [Socket, Bank, Other])
            end;
        _ -> ok
    end.

volt_patterns(Rack) ->
    case catch 'reef_selene_line@ps':voltPatternsOf(Rack) of
        L when is_tuple(L) -> array:to_list(L);
        L when is_list(L) -> L;
        _ -> []
    end.

%% A pattern of voltages, read as `n`: a trailing V on a value is taken off.
parse_volts(P) ->
    Plain = binary:replace(P, [<<"V">>, <<"v">>], <<>>, [global]),
    case catch 'tidal_line@ps':parseLine(<<"d1 $ n \"", Plain/binary, "\"">>) of
        {right, {play, _, Pattern}} -> {ok, Pattern};
        _ -> error
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
