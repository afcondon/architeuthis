%% @doc What Selene has applied to the modular, kept by the rig and applied
%% again when a daemon comes back (AC, 2026-10-04: "the Dashboard decides,
%% the rig remembers").
%%
%% Selene's polysignals live in the daemons' memory (es9-daemon, the FH-2's
%% fh2-daemon): a daemon restarted, or one that lost the ES-9 when the rack
%% was powered down and was replaced, comes back with nothing, and the page's
%% Apply had to be pressed again. So every apply that a daemon accepted is
%% kept here, per socket and bank, and on disk, and sent again:
%%
%%  * when a daemon that had stopped answering answers again (polled), and
%%  * on `selene-reapply <socket>`, which the Dashboard sends after it has
%%    asked Bosun to restart a daemon (a restart quicker than the poll).
%%
%% Hush silences, clear forgets: `selene $ hush` and `hush` mark the sockets
%% hushed, so a returning daemon is not given back what was silenced; the
%% next apply wakes them.
%%
%% The rack decides what is kept: this process follows the stage's
%% `selene/rack` (as selene_retrig does), and a bank it kept that the rack
%% no longer has is released in its daemon (`release-claim`, which silences
%% its jacks) and forgotten, however it left the rack. Kept, it would be
%% applied again on the daemon's return and take back jacks that something
%% else now has. A release the daemon does not take (it is down) is tried
%% again at the next rack and on the daemon's return. Until the stage has
%% given a rack, nothing is released. `off` also forgets at once (forget/2).
%%
%% The FH-2 voices the routing table plays (Triggerfish `DFh2Voice`) are kept
%% the same way, from the stage's `routing/fh2-voices`: the pitch jacks in use
%% (`1 3`). Each is a one-voice `apply-yarns` (pitch on the jack, gate on the
%% next, MIDI channel 10 + (jack+1)/2), applied when it appears and when the
%% daemon returns, released when it goes. The stage keeps the object on disk,
%% so it needs no file here.
-module(selene_keeper).
-behaviour(gen_server).

-export([start_link/0, record/3, forget/2, reapply/1, hushed/0, applied/0, resume/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(POLL_MS, 2000).
-define(SOCKETS, [<<"es9">>, <<"fh2">>]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A daemon accepted `apply-polysignal Json` for Bank: keep it.
record(Socket, Bank, Json) -> gen_server:cast(?MODULE, {record, Socket, Bank, Json}).

%% A daemon released Bank (`off`): stop keeping it.
forget(Socket, Bank) -> gen_server:cast(?MODULE, {forget, Socket, Bank}).

%% Send every kept apply for Socket again. Returns how many were sent.
reapply(Socket) -> gen_server:call(?MODULE, {reapply, Socket}, 15000).

%% What the modular has been given, for the Dashboard's chart: one map per
%% socket and bank, with its family, its slot count, and whether a hush has
%% silenced it since.
applied() -> gen_server:call(?MODULE, applied, 5000).

%% Everything was silenced: do not give it back on a daemon's return. The
%% ES-9's banks are stopped by es9-daemon's panic (the caller's); the FH-2
%% runs its banks on the module, where nothing stops them, so each is sent
%% again with every slot at depth 0 (AC, 2026-10-04, a stopgap: a `silence`
%% verb in the FH-2's daemon is the real fix). What was applied is kept.
hushed() -> gen_server:cast(?MODULE, hushed).

%% Undo a hush: give every daemon back what it was given. Returns how many
%% banks were sent.
resume() -> gen_server:call(?MODULE, resume, 15000).

-define(RACK, <<"selene/rack">>).
-define(VOICES, <<"routing/fh2-voices">>).
-define(VOICE_JACKS, [1, 3, 5, 7]).

init([]) ->
    erlang:send_after(?POLL_MS, self(), poll),
    Table = tidal_stage:text_subscribe(self()),
    Text = fun(Key) -> case maps:get(Key, Table, undefined) of
                           #{text := T} when is_binary(T) -> T;
                           _ -> undefined
                       end
           end,
    St = #{applied => load(), up => #{}, hushed => #{}, rack => Text(?RACK),
           voices => voice_jacks(Text(?VOICES)), voices_up => []},
    {ok, voices(follow(St))}.

handle_call({reapply, Socket}, _From, St) ->
    {N, St1} = send_all(Socket, St),
    {reply, {ok, N}, St1};
handle_call(resume, _From, St) ->
    St1 = St#{hushed := #{}},
    {N1, St2} = send_all(<<"es9">>, St1),
    {N2, St3} = send_all(<<"fh2">>, St2),
    {reply, {ok, N1 + N2}, St3};
handle_call(applied, _From, St = #{applied := A, hushed := H}) ->
    {reply, [describe(S, B, J, maps:get(S, H, false)) || {{S, B}, J} <- maps:to_list(A)], St};
handle_call(_, _From, St) -> {reply, {error, unknown}, St}.

%% A bank with every slot's depth at 0: the same claim, no output.
silent(Json) ->
    case catch json:decode(Json) of
        M = #{<<"slots">> := Slots} when is_list(Slots) ->
            iolist_to_binary(json:encode(M#{<<"slots">> := [quiet(S) || S <- Slots]}));
        _ -> Json
    end.

quiet(S) when is_map(S) -> S#{<<"depth">> => 0};
quiet(S) -> S.

describe(Socket, Bank, Json, Hushed) ->
    D = case catch json:decode(Json) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    Slots = case maps:get(<<"slots">>, D, []) of
                L when is_list(L) -> length(L);
                _ -> 0
            end,
    #{socket => Socket, bank => Bank, family => maps:get(<<"family">>, D, <<>>),
      slots => Slots, hushed => Hushed}.

handle_cast({record, Socket, Bank, Json}, St = #{applied := A, hushed := H}) ->
    A1 = A#{{Socket, Bank} => Json},
    save(A1),
    {noreply, St#{applied := A1, hushed := maps:remove(Socket, H)}};
handle_cast({forget, Socket, Bank}, St = #{applied := A}) ->
    A1 = maps:remove({Socket, Bank}, A),
    save(A1),
    {noreply, St#{applied := A1}};
handle_cast(hushed, St = #{applied := A}) ->
    [call(path(<<"fh2">>), <<"apply-polysignal ", (silent(J))/binary>>)
     || {{<<"fh2">>, _B}, J} <- maps:to_list(A)],
    {noreply, St#{hushed := maps:from_list([{S, true} || S <- ?SOCKETS])}};
handle_cast(_, St) -> {noreply, St}.

handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := ?RACK, <<"text">> := T} when is_binary(T) ->
            {noreply, follow(St#{rack := T})};
        #{<<"key">> := ?RACK} ->
            {noreply, follow(St#{rack := <<>>})};
        #{<<"key">> := ?VOICES} = M ->
            {noreply, voices(St#{voices := voice_jacks(maps:get(<<"text">>, M, <<>>))})};
        _ ->
            {noreply, St}
    end;
%% A daemon that answers after not answering has come back with nothing.
%% The first answer after the rig starts is taken as it stands.
handle_info(poll, St = #{up := Up}) ->
    erlang:send_after(?POLL_MS, self(), poll),
    St1 = lists:foldl(
            fun(S, Acc = #{up := U}) ->
                    Now = answers(S),
                    Acc1 = Acc#{up := U#{S => Now}},
                    case {maps:get(S, Up, unknown), Now} of
                        {false, true} when S =:= <<"fh2">> ->
                            voices((element(2, send_all(S, Acc1)))#{voices_up := []});
                        {false, true} -> element(2, send_all(S, Acc1));
                        _ -> Acc1
                    end
            end, St, ?SOCKETS),
    {noreply, St1};
handle_info(_, St) -> {noreply, St}.

%% The pitch jacks named by `routing/fh2-voices`; undefined until the stage
%% has said (then nothing is applied or released).
voice_jacks(undefined) -> undefined;
voice_jacks(Text) ->
    Js = [catch binary_to_integer(W) || W <- binary:split(Text, <<" ">>, [global, trim_all])],
    lists:usort([J || J <- Js, lists:member(J, ?VOICE_JACKS)]).

%% Apply the voices the table plays that the FH-2 does not have yet, and
%% release the others. Before anything is known to be applied (at start, or
%% after the daemon came back) every jack is settled, so a voice dropped
%% while the rig was down is released too.
voices(St = #{voices := undefined}) -> St;
voices(St = #{voices := Want, voices_up := Have}) ->
    Settle = case Have of [] -> ?VOICE_JACKS; _ -> lists:usort(Want ++ Have) end,
    Up = lists:foldl(
           fun(J, Acc) ->
                   case {lists:member(J, Want), lists:member(J, Acc)} of
                       {true, false} -> case voice_call(apply, J) of ok -> [J | Acc]; error -> Acc end;
                       {false, _} -> _ = voice_call(release, J), lists:delete(J, Acc);
                       {true, true} -> Acc
                   end
           end, Have, Settle),
    St#{voices_up := lists:usort(Up)}.

voice_call(What, J) ->
    Name = <<"fh2voice-", (integer_to_binary(J))/binary>>,
    Cmd = case What of
              apply ->
                  Voice = #{<<"name">> => Name, <<"channel">> => 10 + (J + 1) div 2,
                            <<"pitchBank">> => <<"main">>, <<"pitchSlot">> => J - 1,
                            <<"gateBank">> => <<"main">>, <<"gateSlot">> => J},
                  <<"apply-yarns ", (iolist_to_binary(json:encode(#{<<"name">> => Name, <<"voices">> => [Voice]})))/binary>>;
              release -> <<"release-claim yarns ", Name/binary>>
          end,
    case call(path(<<"fh2">>), Cmd) of
        {ok, <<"OK", _/binary>> = R} ->
            _ = What =:= apply andalso logger:notice("selene_keeper: FH-2 voice on jack ~p: ~s", [J, R]),
            ok;
        Other ->
            _ = What =:= apply andalso logger:warning("selene_keeper: FH-2 voice on jack ~p not applied: ~p", [J, Other]),
            error
    end.

%% Release and forget every kept bank the rack does not hold.
follow(St = #{rack := undefined}) -> St;
follow(St = #{rack := Rack, applied := A}) ->
    Held = [{S, B} || #{socket := S, bank := B} <- banks(Rack)],
    Gone = [K || K <- maps:keys(A), not lists:member(K, Held)],
    A1 = lists:foldl(fun release/2, A, Gone),
    _ = A1 =/= A andalso save(A1),
    St#{applied := A1}.

release(K = {Socket, Bank}, A) ->
    Owner = owner(maps:get(K, A), Socket, Bank),
    case call(path(Socket), <<"release-claim polysignal ", Owner/binary>>) of
        {ok, <<"OK", _/binary>>} ->
            logger:notice("selene_keeper: ~s ~s left the rack: released ~s", [Socket, Bank, Owner]),
            maps:remove(K, A);
        _ -> A
    end.

%% The claim's name, as the apply gave it (Reef.Selene.Wire.ownerOf).
owner(Json, Socket, Bank) ->
    case catch json:decode(Json) of
        #{<<"alias">> := Alias} when is_binary(Alias), Alias =/= <<>> -> Alias;
        _ -> <<"selene:", Socket/binary, ":", Bank/binary>>
    end.

banks(Rack) ->
    case catch 'reef_selene_line@ps':banksOf(Rack) of
        L when is_tuple(L) -> array:to_list(L);
        L when is_list(L) -> L;
        _ -> []
    end.

send_all(Socket, St0) ->
    %% what the rack has lost is released first, not given back
    St = #{applied := A, hushed := H} = follow(St0),
    case maps:get(Socket, H, false) of
        true -> {0, St};
        false ->
            Mine = [J || {{S, _B}, J} <- maps:to_list(A), S =:= Socket],
            [call(path(Socket), <<"apply-polysignal ", J/binary>>) || J <- Mine],
            case Mine of
                [] -> ok;
                _ -> logger:notice("selene_keeper: re-applied ~p bank(s) to ~s", [length(Mine), Socket])
            end,
            {length(Mine), St}
    end.

answers(Socket) ->
    case call(path(Socket), <<"ping">>) of
        {ok, <<"OK", _/binary>>} -> true;
        _ -> false
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

%% On disk, so the rig remembers across its own restarts too.
file() -> home(".architeuthis/selene-applied.term", "/tmp/selene-applied.term").

load() ->
    case file:read_file(file()) of
        {ok, Bin} -> try binary_to_term(Bin) of M when is_map(M) -> M; _ -> #{} catch _:_ -> #{} end;
        _ -> #{}
    end.

save(A) ->
    F = file(),
    _ = filelib:ensure_dir(F),
    _ = file:write_file(F, term_to_binary(A)),
    ok.
