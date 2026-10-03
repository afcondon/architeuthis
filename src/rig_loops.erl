%% @doc The record buffer, its marks, and the loops that play them, on the rig
%% (docs/kb/plans/the-deck.md, step 3b; words as in
%% docs/kb/reference/atlantis-vocabulary.md).
%%
%% The record buffer is each machine's MIDI notes for the session (pitch,
%% velocity, gate and the voice that made each one), timed in Link beats. The
%% rig records what its own voices send (reef_voice for Odonus, vetula_cards
%% for Vetula); a page playing in Solo uploads what it plays (`loops-record`).
%% Session-only: it is gone when the rig restarts or the machine is cleared
%% (`odonus $ clear`), and notes older than ?RETAIN_MIN minutes go unless a
%% mark's window holds them.
%%
%% A mark is a point in the record buffer. Marks are numbered by position
%% among those there now, from 1, oldest first (AC, 2026-10-03), so after a
%% delete or a clear the numbers close up; inside, each keeps an id, which
%% its loop and its window patterns follow. Its window (the stretch a loop on
%% it plays) starts as the bar the mark falls in and the bar before it, and
%% moves with slide / widen / narrow, by hand on the Review surface or by a
%% pattern (window_patterns).
%%
%% A loop plays its mark's window here, on Link time, through the machine's
%% routes, beside live play; several can sound at once. It starts on the next
%% downbeat and plays in beats, so it follows the tempo. Loops are never
%% recorded: they send straight to the routes, not through the voices.
%%
%% A run is a stretch a machine's transport played, start to stop, told by
%% its page (`loops-run`) or by `<machine> $ hush`: the Review surface draws
%% only time inside runs, so a pause leaves no gap, as on a tape stopped and
%% started again (AC, 2026-10-03).
%%
%% Pages are told the marks and loops whenever they change
%% (`loops {"machine", "marks": [...]}`), and draw them; they hold no loop of
%% their own while the rig is there. A clear also says `loops-clear`.
-module(rig_loops).
-behaviour(gen_server).

-export([start_link/0, record/2, mark/1, play/2, hush/2, hush_all/0,
         nudge/3, place/4, reset/2, set_window/4, delete/2, target/2,
         follow/4, clear/1, run/2, sync/0, state/0, notes_json/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(NOTES, rig_loops_notes).
-define(POLL_MS, 25).
-define(LOOKAHEAD_MS, 200.0).
-define(STALE_ANCHOR_US, 2000000).
-define(BAR, 4.0).
-define(RETAIN_MIN, 90).
-define(PRUNE_MS, 30000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Every N below is a mark's number (its position, from 1); 0 asks for the
%% default. Replies give the number acted on: {ok, N} or {error, Why}.

%% Notes a voice (or a Solo page) has sent: [{AtUs, Pitch, Vel, DurMs, Voice}].
record(_Machine, []) -> ok;
record(Machine, Notes) -> gen_server:cast(?MODULE, {record, Machine, Notes}).

%% A mark now.
mark(Machine) -> call({mark, Machine}).

%% Loop mark N (0: the latest) from the next downbeat.
play(Machine, N) -> call({play, Machine, N}).

%% Stop loop N, or with `all` every loop of the machine.
hush(Machine, Which) -> call({hush, Machine, Which}).
hush_all() -> call(hush_all).

%% Move loop N's window by bars: {slide, Bars} or {widen, Bars}.
nudge(Machine, N, Move) -> call({nudge, Machine, N, Move}).

%% From window_patterns: place mark `Id`'s window from where it was made,
%% Bars bars on: Kind is <<"slide">> (the start) or <<"widen">> (the length
%% beyond the original).
place(Machine, Id, Kind, Bars) -> gen_server:cast(?MODULE, {place, Machine, Id, Kind, Bars}).

%% Loop N's window back where its mark made it, its patterns dropped.
reset(Machine, N) -> call({reset, Machine, N}).

%% Mark N's window, in beats, as a page drew it.
set_window(Machine, N, From, To) -> call({set_window, Machine, N, From, To}).

delete(Machine, N) -> call({delete, Machine, N}).

%% Which mark a window cue with no number acts on: the loop started last, else
%% the latest mark. 0 asks for that; any other N is itself, if it exists.
target(Machine, N) -> call({target, Machine, N}).

%% Loop N's window follows a pattern (Kind <<"slide">> | <<"widen">>), or
%% with `off` stops following one.
follow(Machine, N, Kind, Text) -> call({follow, Machine, N, Kind, Text}).

%% Empty a machine's record buffer: its notes, marks, loops, patterns and
%% runs (a run still going starts again now).
clear(Machine) -> call({clear, Machine}).

%% The machine's transport started (true) or stopped (false), now.
run(Machine, Playing) -> gen_server:cast(?MODULE, {run, Machine, Playing}).

%% Tell every page the marks and loops of every machine.
sync() -> gen_server:cast(?MODULE, sync).

%% For inspection from a shell.
state() -> call(state).

%% A machine's whole record buffer, for a page that opens after the notes
%% were played: `loops-notes {"machine", "notes": [[beat, pitch, vel,
%% durBeats, voice], ...], "runs": [[from, to | null], ...]}`, oldest first.
notes_json(M) ->
    Notes = case ets:whereis(?NOTES) of
                undefined -> [];
                _ -> ets:select(?NOTES, [{{{M, '$1', '_'}, '$2', '$3', '$4', '$5'}, [],
                                          [['$1', '$2', '$3', '$4', '$5']]}])
            end,
    Runs = case call({runs, M}) of
               Rs when is_list(Rs) -> [[F, case T of open -> null; _ -> T end] || {F, T} <- lists:reverse(Rs)];
               _ -> []
           end,
    Json = iolist_to_binary(json:encode(#{machine => M, notes => Notes, runs => Runs})),
    <<"loops-notes ", Json/binary>>.

call(Msg) ->
    case whereis(?MODULE) of
        undefined -> {error, <<"the record buffer is not running">>};
        _ -> gen_server:call(?MODULE, Msg)
    end.

%% ---------------------------------------------------------------------------

init([]) ->
    ets:new(?NOTES, [ordered_set, named_table, protected]),
    {ok, Sock} = gen_udp:open(0, [binary]),
    Table = tidal_stage:text_subscribe(self()),
    VRouting = case maps:find(<<"vetula/routing">>, Table) of
                   {ok, #{text := T}} -> vetula_routing(T, none);
                   error -> none
               end,
    Self = self(),
    %% the CV routes' calibration tables, fetched once, off the hot path
    spawn(fun() -> Self ! {cv, catch reef_voice:init_cv()} end),
    erlang:send_after(?POLL_MS, self(), tick),
    erlang:send_after(?PRUNE_MS, self(), prune),
    {ok, #{sock => Sock, marks => #{}, loops => #{}, focus => #{},
           next => 1, cv => undefined, vrouting => VRouting, runs => #{}}}.

handle_call({mark, M}, _From, St) ->
    case now_beat() of
        {ok, B, _} ->
            Id = maps:get(next, St),
            Bar = floor(B / ?BAR) * ?BAR,
            Mk = #{id => Id, beat => B, us => erlang:system_time(microsecond),
                   from => Bar - ?BAR, to => Bar + ?BAR,
                   origin => {Bar - ?BAR, Bar + ?BAR}},
            St1 = put_mark(M, Mk, St#{next := Id + 1}),
            announce(M, St1),
            {reply, {ok, number(M, Id, St1)}, St1};
        Err -> {reply, Err, St}
    end;
handle_call({play, M, N0}, _From, St) ->
    case {resolve(M, N0, St, latest), now_beat()} of
        {{ok, Id}, {ok, B, _}} ->
            Key = {M, Id},
            Loops = maps:get(loops, St),
            St1 = case maps:is_key(Key, Loops) of
                      true -> St;
                      false ->
                          Start = ceil(B / ?BAR) * ?BAR,
                          St#{loops := Loops#{Key => #{start => Start, until => Start}}}
                  end,
            St2 = St1#{focus := (maps:get(focus, St1))#{M => Id}},
            announce(M, St2),
            {reply, {ok, number(M, Id, St2)}, St2};
        {{ok, _}, Err} -> {reply, Err, St};
        {Err, _} -> {reply, Err, St}
    end;
handle_call({hush, M, all}, _From, St) ->
    St1 = drop_loops(M, St),
    announce(M, St1),
    {reply, ok, St1};
handle_call({hush, M, N0}, _From, St) ->
    case resolve(M, N0, St, focus) of
        {ok, Id} ->
            catch window_patterns:clear({M, Id}),
            St1 = unfocus(M, Id, St#{loops := maps:remove({M, Id}, maps:get(loops, St))}),
            announce(M, St1),
            {reply, {ok, number(M, Id, St1)}, St1};
        Err -> {reply, Err, St}
    end;
handle_call(hush_all, _From, St) ->
    Machines = lists:usort([M || {M, _} <- maps:keys(maps:get(loops, St))]),
    St1 = St#{loops := #{}, focus := #{}},
    [announce(M, St1) || M <- Machines],
    {reply, ok, St1};
handle_call({nudge, M, N0, Move}, _From, St) ->
    with_mark(M, N0, St, fun(Mk) ->
        #{from := F, to := T} = Mk,
        case Move of
            {slide, Bars} -> Mk#{from := F + Bars * ?BAR, to := T + Bars * ?BAR};
            {widen, Bars} -> Mk#{to := max(F + 1.0, T + Bars * ?BAR)}
        end
    end);
handle_call({reset, M, N0}, _From, St) ->
    case resolve(M, N0, St, focus) of
        {ok, Id} -> catch window_patterns:clear({M, Id});
        _ -> ok
    end,
    with_mark(M, N0, St, fun(Mk = #{origin := {F, T}}) -> Mk#{from := F, to := T} end);
handle_call({set_window, M, N, F, T}, _From, St) when T > F ->
    with_mark(M, N, St, fun(Mk) -> Mk#{from := F, to := T} end);
handle_call({set_window, _, _, _, _}, _From, St) ->
    {reply, {error, <<"a window must end after it starts">>}, St};
handle_call({delete, M, N}, _From, St) ->
    case resolve(M, N, St, focus) of
        {ok, Id} ->
            Marks = [Mk || Mk = #{id := K} <- marks_of(M, St), K =/= Id],
            St1 = unfocus(M, Id, St#{marks := (maps:get(marks, St))#{M => Marks},
                                     loops := maps:remove({M, Id}, maps:get(loops, St))}),
            catch window_patterns:clear({M, Id}),
            announce(M, St1),
            {reply, {ok, N}, St1};
        Err -> {reply, Err, St}
    end;
handle_call({target, M, N}, _From, St) ->
    case resolve(M, N, St, focus) of
        {ok, Id} -> {reply, {ok, number(M, Id, St)}, St};
        Err -> {reply, Err, St}
    end;
handle_call({follow, M, N0, Kind, Text}, _From, St) ->
    case resolve(M, N0, St, focus) of
        {ok, Id} ->
            window_patterns:set({M, Id}, Kind, Text),
            {reply, {ok, number(M, Id, St)}, St};
        Err -> {reply, Err, St}
    end;
handle_call({clear, M}, _From, St) ->
    ets:select_delete(?NOTES, [{{{M, '_', '_'}, '_', '_', '_', '_'}, [], [true]}]),
    St1 = drop_loops(M, St),
    Runs = maps:get(runs, St1),
    Again = case {maps:get(M, Runs, []), now_beat()} of
                {[{_, open} | _], {ok, B, _}} -> [{B, open}];
                _ -> []
            end,
    St2 = St1#{marks := maps:remove(M, maps:get(marks, St1)), runs := Runs#{M => Again}},
    Json = iolist_to_binary(json:encode(#{machine => M})),
    tidal_link_anchor:sync_broadcast(<<"loops-clear ", Json/binary>>),
    announce(M, St2),
    {reply, ok, St2};
handle_call({runs, M}, _From, St) ->
    {reply, maps:get(M, maps:get(runs, St), []), St};
handle_call(state, _From, St) ->
    {reply, maps:remove(sock, St#{notes => ets:info(?NOTES, size)}), St};
handle_call(_Msg, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({record, M, Notes}, St) ->
    case tidal_link_anchor:info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, _Q, _Recv} when Tempo > 0 ->
            lists:foreach(
              fun({AtUs, Pitch, Vel, DurMs, Voice}) ->
                      Beat = BeatAtAnchor + (AtUs - AnchorUs) * Tempo / 60000000.0,
                      DurBeats = DurMs * Tempo / 60000.0,
                      ets:insert(?NOTES, {{M, Beat, erlang:unique_integer([monotonic])},
                                          Pitch, Vel, DurBeats, Voice})
              end, Notes);
        _ -> ok   % no Link, no beats to keep them by
    end,
    {noreply, St};
handle_cast({place, M, Id, Kind, Bars}, St) ->
    case [Mk || Mk = #{id := K} <- marks_of(M, St), K =:= Id] of
        [Mk = #{from := F, to := T, origin := {OF, OT}}] ->
            Mk1 = case Kind of
                      <<"slide">> -> Start = OF + Bars * ?BAR, Mk#{from := Start, to := Start + (T - F)};
                      <<"widen">> -> Mk#{to := F + max(1.0, (OT - OF) + Bars * ?BAR)}
                  end,
            St1 = put_mark(M, Mk1, St),
            announce(M, St1),
            {noreply, St1};
        _ -> {noreply, St}   % a pattern on a mark since deleted
    end;
handle_cast({run, M, Playing}, St) ->
    Runs = maps:get(runs, St),
    Old = maps:get(M, Runs, []),
    New = case {Playing, Old, now_beat()} of
              {true, [{_, open} | _], _} -> Old;
              {true, _, {ok, B, _}} -> [{B, open} | Old];
              {false, [{F, open} | Rest], {ok, B, _}} -> [{F, B} | Rest];
              _ -> Old
          end,
    {noreply, St#{runs := Runs#{M => New}}};
handle_cast(sync, St) ->
    %% the two machines with a Review surface always, so a page learns the
    %% rig keeps its loops before it has a mark
    Machines = lists:usort([<<"odonus">>, <<"vetula">> | maps:keys(maps:get(marks, St))]),
    [announce(M, St) || M <- Machines],
    {noreply, St};
handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info(tick, St) ->
    St1 = case tidal_link_anchor:info() of
              {anchor, AnchorUs, BeatAtAnchor, Tempo, _Q, Recv}
                when Tempo > 0 ->
                  NowUs = erlang:system_time(microsecond),
                  case NowUs - Recv =< ?STALE_ANCHOR_US of
                      true ->
                          BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
                          Horizon = BeatNow + ?LOOKAHEAD_MS / 1000.0 * Tempo / 60.0,
                          play_loops(St, Horizon, {AnchorUs, BeatAtAnchor, Tempo});
                      false -> St
                  end;
              _ -> St
          end,
    erlang:send_after(?POLL_MS, self(), tick),
    {noreply, St1};
handle_info(prune, St) ->
    prune(St),
    erlang:send_after(?PRUNE_MS, self(), prune),
    {noreply, St};
handle_info({cv, Cv}, St) when is_map(Cv) ->
    {noreply, St#{cv := Cv}};
handle_info({cv, _}, St) ->
    {noreply, St};
handle_info({emit_cv, Bus, Value}, St) ->
    %% a loop's pitch CV, deferred to its onset (reef_voice:maybe_schedule_cv)
    es9_cv:send_cv(maps:get(sock, St), Bus, Value),
    {noreply, St};
handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := <<"vetula/routing">>, <<"text">> := T} ->
            {noreply, St#{vrouting := vetula_routing(T, maps:get(vrouting, St))}};
        _ -> {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%% ---------------------------------------------------------------------------

now_beat() ->
    Now = erlang:system_time(microsecond),
    case {tidal_link_anchor:beat_at(Now), tidal_link_anchor:tempo()} of
        {{ok, B}, {ok, T}} -> {ok, B, T};
        _ -> {error, <<"no Link: the rig keeps time by it">>}
    end.

marks_of(M, St) -> maps:get(M, maps:get(marks, St), []).

%% A mark's number: its position among the machine's marks, oldest first.
number(M, Id, St) ->
    Ids = lists:sort([K || #{id := K} <- marks_of(M, St)]),
    length(lists:takewhile(fun(K) -> K =/= Id end, Ids)) + 1.

put_mark(M, Mk = #{id := Id}, St) ->
    Others = [O || O = #{id := K} <- marks_of(M, St), K =/= Id],
    Marks = lists:sort(fun(#{id := A}, #{id := B}) -> A >= B end, [Mk | Others]),
    St#{marks := (maps:get(marks, St))#{M => Marks}}.

%% The id of mark N as asked: 0 is the latest (Default = latest) or the loop
%% started last, else the latest (Default = focus).
resolve(M, 0, St, Default) ->
    Focus = case Default of
                focus -> maps:find(M, maps:get(focus, St));
                latest -> error
            end,
    case {Focus, marks_of(M, St)} of
        {{ok, Id}, _} -> {ok, Id};
        {error, [#{id := Id} | _]} -> {ok, Id};
        {error, []} -> {error, <<"no marks yet: mark one first">>}
    end;
resolve(M, N, St, _) when is_integer(N), N > 0 ->
    Ids = lists:sort([K || #{id := K} <- marks_of(M, St)]),
    case N =< length(Ids) of
        true -> {ok, lists:nth(N, Ids)};
        false -> {error, iolist_to_binary(io_lib:format("there is no mark ~p (~p marked)", [N, length(Ids)]))}
    end;
resolve(_, N, _, _) ->
    {error, iolist_to_binary(io_lib:format("there is no mark ~p", [N]))}.

with_mark(M, N0, St, F) ->
    case resolve(M, N0, St, focus) of
        {ok, Id} ->
            [Mk] = [X || X = #{id := K} <- marks_of(M, St), K =:= Id],
            St1 = put_mark(M, F(Mk), St),
            announce(M, St1),
            {reply, {ok, number(M, Id, St1)}, St1};
        Err -> {reply, Err, St}
    end.

%% Stop every loop of a machine, and its window patterns.
drop_loops(M, St) ->
    catch window_patterns:clear(M),
    Loops = maps:filter(fun({Mc, _}, _) -> Mc =/= M end, maps:get(loops, St)),
    St#{loops := Loops, focus := maps:remove(M, maps:get(focus, St))}.

unfocus(M, Id, St) ->
    Focus = maps:get(focus, St),
    case maps:find(M, Focus) of
        {ok, Id} ->
            %% the focus falls to another loop of the machine still playing
            case [K || {Mc, K} <- maps:keys(maps:get(loops, St)), Mc =:= M] of
                [] -> St#{focus := maps:remove(M, Focus)};
                Ks -> St#{focus := Focus#{M => lists:max(Ks)}}
            end;
        _ -> St
    end.

%% `loops {"machine": M, "marks": [...]}`, newest first, to every page: each
%% with its number (`n`) and its id, which a page follows it by.
announce(M, St) ->
    Loops = maps:get(loops, St),
    Marks = [begin
                 {OF, OT} = maps:get(origin, Mk),
                 Base = #{id => Id, n => number(M, Id, St), beat => B, us => maps:get(us, Mk),
                          from => maps:get(from, Mk), to => maps:get(to, Mk),
                          originFrom => OF, originTo => OT},
                 case maps:find({M, Id}, Loops) of
                     {ok, #{start := S}} -> Base#{playing => true, start => S};
                     error -> Base#{playing => false, start => null}
                 end
             end || Mk = #{id := Id, beat := B} <- marks_of(M, St)],
    Json = iolist_to_binary(json:encode(#{machine => M, marks => Marks})),
    tidal_link_anchor:sync_broadcast(<<"loops ", Json/binary>>).

%% Each playing loop sends what falls between where it got to and the
%% horizon. Link beat L of a loop that started at S plays material beat
%% From + ((L - S) mod Len), its window as it stands now.
play_loops(St, Horizon, Anchor) ->
    Loops = maps:map(
              fun({M, Id}, L = #{start := S, until := U}) ->
                      case [Mk || Mk = #{id := K} <- marks_of(M, St), K =:= Id] of
                          [#{from := F, to := T}] when Horizon > S, Horizon > U ->
                              Lo = max(U, S),
                              Len = T - F,
                              K0 = floor((Lo - S) / Len),
                              K1 = floor((Horizon - S) / Len),
                              lists:foreach(
                                fun(K) ->
                                        C = S + K * Len,
                                        A = max(Lo, C),
                                        B = min(Horizon, C + Len),
                                        case B > A of
                                            true -> send_range(M, F + (A - C), F + (B - C), C - F, St, Anchor);
                                            false -> ok
                                        end
                                end, lists:seq(K0, K1)),
                              L#{until := Horizon};
                          _ -> L
                      end
              end, maps:get(loops, St)),
    St#{loops := Loops}.

%% The notes with material beats in [A, B), sent at material beat + Shift.
send_range(M, A, B, Shift, St, {AnchorUs, BeatAtAnchor, Tempo}) ->
    Notes = ets:select(?NOTES, [{{{M, '$1', '_'}, '$2', '$3', '$4', '$5'},
                                 [{'>=', '$1', A}, {'<', '$1', B}],
                                 [{{'$1', '$2', '$3', '$4', '$5'}}]}]),
    lists:foreach(
      fun({Beat, Pitch, Vel, DurBeats, Voice}) ->
              AtUs = round(AnchorUs + (Beat + Shift - BeatAtAnchor) * 60000000.0 / Tempo),
              DurMs = DurBeats * 60000.0 / Tempo,
              send_note(M, Voice, Pitch, Vel, DurMs, Tempo, AtUs, St)
      end, Notes).

send_note(<<"odonus">>, Head, Pitch, Vel, DurMs, Tempo, AtUs, St) ->
    Sock = maps:get(sock, St),
    reef_voice:maybe_schedule_cv(Sock, maps:get(cv, St), Head, Pitch, AtUs),
    reef_voice:route_note(Sock, Head, Pitch, Vel, DurMs, 15000.0 / Tempo, AtUs);
send_note(<<"vetula">>, Ch, Pitch, Vel, DurMs, Tempo, AtUs, St) ->
    vetula_cards:route_note(maps:get(sock, St), maps:get(vrouting, St), Ch, Pitch, Vel,
                            DurMs, 60000.0 / Tempo, AtUs);
send_note(_, _, _, _, _, _, _, _) -> ok.

vetula_routing(null, _) -> none;
vetula_routing(Text, Old) ->
    case 'reef_routing@ps':decodeVoiceRouting(Text) of
        {right, R} -> R;
        _ -> Old
    end.

%% Drop notes older than ?RETAIN_MIN minutes, unless a mark's window (and a
%% bar either side) holds them.
prune(St) ->
    case now_beat() of
        {ok, B, Tempo} when Tempo > 0 ->
            Cutoff = B - ?RETAIN_MIN * Tempo,
            Kept = maps:map(fun(_M, Marks) ->
                                    [{F - ?BAR, T + ?BAR} || #{from := F, to := T} <- Marks]
                            end, maps:get(marks, St)),
            Old = ets:select(?NOTES, [{{{'$1', '$2', '$3'}, '_', '_', '_', '_'},
                                       [{'<', '$2', Cutoff}],
                                       [{{'$1', '$2', '$3'}}]}]),
            lists:foreach(
              fun({M, Beat, _} = Key) ->
                      Ranges = maps:get(M, Kept, []),
                      case lists:any(fun({F, T}) -> Beat >= F andalso Beat < T end, Ranges) of
                          true -> ok;
                          false -> ets:delete(?NOTES, Key)
                      end
              end, Old);
        _ -> ok
    end.
