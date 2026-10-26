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
%% **Selene runs or is stopped, as a whole** (CR-11, AC 2026-10-25: "every
%% signal should be running if Selene is running but some may be muted").
%% This process holds that one state, kept on disk with what was applied, so
%% it outlives a rig restart. stop/0 (`selene $ hush`, and `hush`) silences
%% every part: the ES-9 (es9-daemon's panic), the FH-2 (each bank sent again
%% at depth 0), the MIDI rows (selene_midi) and the reset patterns
%% (selene_retrig). play/0 gives them all back. While stopped, an edit is
%% kept here and in the rack but not sent (`running/0` tells the caller), so
%% play brings back exactly what the page shows; a returning daemon is not
%% given anything either.
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
%% FH-2 voices are Selene voice layouts (POLYVOICE, family `polyvoice`), kept
%% like any Selene bank. Until 2026-10-19 this process built the routing
%% table's voices itself, from the stage's `routing/fh2-voices`, as one-voice
%% `apply-yarns` converters named fh2voice-1/3/5/7; one left from then would
%% hold jacks a layout wants, so each is released when the FH-2 answers (a
%% release of what is not held does nothing).
-module(selene_keeper).
-behaviour(gen_server).

-export([start_link/0, record/3, forget/2, reapply/1, stop/0, play/0, running/0, applied/0, snapshot/0, restore/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(POLL_MS, 2000).
-define(SOCKETS, [<<"es9">>, <<"fh2">>]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A daemon accepted `apply-polysignal Json` for Bank: keep it.
record(Socket, Bank, Json) -> gen_server:cast(?MODULE, {record, Socket, Bank, Json}).

%% A daemon released Bank (`off`): stop keeping it.
forget(Socket, Bank) -> gen_server:cast(?MODULE, {forget, Socket, Bank}).

%% What is kept, before a `selene $` line changes the rack: a line the daemon
%% refuses part-way (a split or swap whose release went through) is undone by
%% `restore`, which puts this back with the rack it went with and gives
%% Socket's daemon its banks again. The keeper follows the new rack as soon
%% as it is on the stage, before the line's commands run, so the old record
%% has to be taken first; it cannot be recovered afterwards.
snapshot() -> gen_server:call(?MODULE, snapshot, 5000).
restore(Socket, Snapshot, Rack) -> gen_server:call(?MODULE, {restore, Socket, Snapshot, Rack}, 15000).

%% Send every kept apply for Socket again. Returns how many were sent.
reapply(Socket) -> gen_server:call(?MODULE, {reapply, Socket}, 15000).

%% What the modular has been given, for the Dashboard's chart: one map per
%% socket and bank, with its family, its slot count, and whether Selene is
%% stopped (`hushed`).
applied() -> gen_server:call(?MODULE, applied, 5000).

%% Stop Selene: every part silenced, what was applied kept. The ES-9's banks
%% are stopped by es9-daemon's panic; the FH-2 runs its banks on the module,
%% where nothing stops them, so each is sent again with every slot at depth 0
%% (AC, 2026-10-04, a stopgap: a `silence` verb in the FH-2's daemon is the
%% real fix). Every page is told (`hushed selene`).
stop() -> gen_server:call(?MODULE, stop, 15000).

%% Play Selene: give every part back what the rack holds. Returns how many
%% banks were sent to the daemons. Every page is told (`played selene`).
play() -> gen_server:call(?MODULE, play, 15000).

%% Whether Selene is running. True when this process is not (yet) running:
%% selene_midi and selene_retrig start before it, and it tells them at start.
running() ->
    case whereis(?MODULE) of
        undefined -> true;
        _ -> case catch gen_server:call(?MODULE, running, 5000) of
                 R when is_boolean(R) -> R;
                 _ -> true
             end
    end.

-define(RACK, <<"selene/rack">>).

init([]) ->
    erlang:send_after(?POLL_MS, self(), poll),
    Table = tidal_stage:text_subscribe(self()),
    Text = fun(Key) -> case maps:get(Key, Table, undefined) of
                           #{text := T} when is_binary(T) -> T;
                           _ -> undefined
                       end
           end,
    Running = load_running(),
    St = #{applied => load(), up => #{}, running => Running, rack => Text(?RACK)},
    _ = release_old_voices(),
    %% the MIDI rows and reset patterns started before this, running
    _ = Running orelse quiet_parts(),
    {ok, follow(St)}.

handle_call(snapshot, _From, St = #{applied := A}) ->
    {reply, A, St};
handle_call({restore, Socket, A, Rack}, _From, St) when is_map(A) ->
    _ = save(A),
    {N, St1} = send_all(Socket, St#{applied := A, rack := Rack}),
    {reply, {ok, N}, St1};
handle_call({reapply, Socket}, _From, St) ->
    {N, St1} = send_all(Socket, St),
    {reply, {ok, N}, St1};
handle_call(play, _From, St) ->
    St1 = St#{running := true},
    save_running(true),
    {N1, St2} = send_all(<<"es9">>, St1),
    {N2, St3} = send_all(<<"fh2">>, St2),
    catch selene_retrig:play(),
    catch selene_mutes:play(),
    catch selene_midi:play(),
    catch tidal_link_anchor:sync_broadcast(<<"played selene">>),
    {reply, {ok, N1 + N2}, St3};
handle_call(stop, _From, St = #{applied := A}) ->
    save_running(false),
    _ = call(path(<<"es9">>), <<"panic">>),
    [call(path(<<"fh2">>), <<"apply-polysignal ", (silent(J))/binary>>)
     || {{<<"fh2">>, _B}, J} <- maps:to_list(A)],
    quiet_parts(),
    catch tidal_stage:stopped(selene),
    catch tidal_link_anchor:sync_broadcast(<<"hushed selene">>),
    {reply, ok, St#{running := false}};
handle_call(running, _From, St = #{running := R}) ->
    {reply, R, St};
handle_call(applied, _From, St = #{applied := A, running := R}) ->
    {reply, [describe(S, B, J, not R) || {{S, B}, J} <- maps:to_list(A)], St};
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

handle_cast({record, Socket, Bank, Json}, St = #{applied := A}) ->
    A1 = A#{{Socket, Bank} => Json},
    save(A1),
    {noreply, St#{applied := A1}};
handle_cast({forget, Socket, Bank}, St = #{applied := A}) ->
    A1 = maps:remove({Socket, Bank}, A),
    save(A1),
    {noreply, St#{applied := A1}};
handle_cast(_, St) -> {noreply, St}.

handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := ?RACK, <<"text">> := T} when is_binary(T) ->
            {noreply, follow(St#{rack := T})};
        #{<<"key">> := ?RACK} ->
            {noreply, follow(St#{rack := <<>>})};
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
                            _ = release_old_voices(),
                            element(2, send_all(S, Acc1));
                        {false, true} -> element(2, send_all(S, Acc1));
                        _ -> Acc1
                    end
            end, St, ?SOCKETS),
    {noreply, St1};
handle_info(_, St) -> {noreply, St}.

%% The converters this process used to build for the routing table's FH-2
%% voices, released (see the module doc).
release_old_voices() ->
    [call(path(<<"fh2">>), <<"release-claim yarns fh2voice-", (integer_to_binary(J))/binary>>)
     || J <- [1, 3, 5, 7]].

%% Release and forget every kept bank the rack does not hold.
follow(St = #{rack := undefined}) -> St;
follow(St = #{rack := Rack, applied := A}) ->
    case banks(Rack) of
        %% a rack that cannot be read says nothing about what has left it:
        %% releasing every kept bank on both daemons would be the wrong answer
        unreadable -> St;
        Banks ->
            Held = [{S, B} || #{socket := S, bank := B} <- Banks],
            Gone = [K || K <- maps:keys(A), not lists:member(K, Held)],
            A1 = lists:foldl(fun release/2, A, Gone),
            _ = A1 =/= A andalso save(A1),
            St#{applied := A1}
    end.

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
        Other ->
            logger:warning("selene_keeper: could not read the rack's banks (~p); keeping what is applied", [Other]),
            unreadable
    end.

send_all(Socket, St0) ->
    %% what the rack has lost is released first, not given back
    St = #{applied := A, running := Running} = follow(St0),
    case Running of
        false -> {0, St};
        true ->
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

%% The parts this process does not send itself, silenced.
quiet_parts() ->
    catch selene_retrig:hush(),
    catch selene_mutes:hush(),
    catch selene_midi:hush(),
    ok.

%% On disk, so the rig remembers across its own restarts too.
file() -> home(".architeuthis/selene-applied.term", "/tmp/selene-applied.term").
running_file() -> home(".architeuthis/selene-running.term", "/tmp/selene-running.term").

load_running() ->
    case file:read_file(running_file()) of
        {ok, <<"stopped">>} -> false;
        _ -> true
    end.

save_running(R) ->
    F = running_file(),
    _ = filelib:ensure_dir(F),
    _ = file:write_file(F, case R of true -> <<"running">>; false -> <<"stopped">> end),
    ok.

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
