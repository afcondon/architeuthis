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
%% next apply wakes them. Nothing here forgets an apply.
-module(selene_keeper).
-behaviour(gen_server).

-export([start_link/0, record/3, reapply/1, hushed/0, applied/0, resume/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(POLL_MS, 2000).
-define(SOCKETS, [<<"es9">>, <<"fh2">>]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A daemon accepted `apply-polysignal Json` for Bank: keep it.
record(Socket, Bank, Json) -> gen_server:cast(?MODULE, {record, Socket, Bank, Json}).

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

init([]) ->
    erlang:send_after(?POLL_MS, self(), poll),
    {ok, #{applied => load(), up => #{}, hushed => #{}}}.

handle_call({reapply, Socket}, _From, St) ->
    {N, St1} = send_all(Socket, St),
    {reply, {ok, N}, St1};
handle_call(resume, _From, St) ->
    St1 = St#{hushed := #{}},
    {N1, _} = send_all(<<"es9">>, St1),
    {N2, _} = send_all(<<"fh2">>, St1),
    {reply, {ok, N1 + N2}, St1};
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
handle_cast(hushed, St = #{applied := A}) ->
    [call(path(<<"fh2">>), <<"apply-polysignal ", (silent(J))/binary>>)
     || {{<<"fh2">>, _B}, J} <- maps:to_list(A)],
    {noreply, St#{hushed := maps:from_list([{S, true} || S <- ?SOCKETS])}};
handle_cast(_, St) -> {noreply, St}.

%% A daemon that answers after not answering has come back with nothing.
%% The first answer after the rig starts is taken as it stands.
handle_info(poll, St = #{up := Up}) ->
    erlang:send_after(?POLL_MS, self(), poll),
    St1 = lists:foldl(
            fun(S, Acc = #{up := U}) ->
                    Now = answers(S),
                    Acc1 = Acc#{up := U#{S => Now}},
                    case {maps:get(S, Up, unknown), Now} of
                        {false, true} -> element(2, send_all(S, Acc1));
                        _ -> Acc1
                    end
            end, St, ?SOCKETS),
    {noreply, St1};
handle_info(_, St) -> {noreply, St}.

send_all(Socket, St = #{applied := A, hushed := H}) ->
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
