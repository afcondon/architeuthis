%% @doc Loop windows driven by patterns (docs/kb/plans/the-deck.md, step 3a).
%%
%% `odonus $ loop 2 # slide "<0 -1 -2 -3>"` and `widen "<0 1>"` from
%% Limulus: this process keeps each loop's two patterns, samples them on
%% every Link beat with Littorina (`Tidal.Window.windowSampler`, a cycle
%% being a bar), and when a value changes places the loop's window that many
%% bars from where its mark made it (rig_loops:place/4). The page never reads
%% Tidal. A rest holds the last value; `slide off` drops the pattern and
%% leaves the window where it is.
-module(window_patterns).
-behaviour(gen_server).

-export([start_link/0, set/3, clear/1, patterns/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Follow `Text` for `Kind` (<<"slide">> | <<"widen">>) on loop `{Slot, N}`,
%% or with `off` stop following it.
set(Loop, Kind, Text) ->
    gen_server:call(?MODULE, {set, Loop, Kind, Text}).

%% Stop following the patterns of loop `{Slot, N}`, of every loop of a
%% machine `Slot`, or with `all` of every loop: what `hush`, `loop hush` and
%% `reset` do. The windows stay where they are.
clear(Slot) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:call(?MODULE, {clear, Slot})
    end.

%% What is followed, for inspection from a shell.
patterns() -> gen_server:call(?MODULE, patterns).

init([]) ->
    self() ! tick,
    {ok, #{patterns => #{}, last => #{}}}.

handle_call({set, Loop, Kind, off}, _From, St = #{patterns := Ps, last := L}) ->
    {reply, ok, St#{patterns := maps:remove({Loop, Kind}, Ps), last := maps:remove({Loop, Kind}, L)}};
handle_call({set, Loop, Kind, Text}, _From, St = #{patterns := Ps, last := L}) ->
    %% a new pattern is heard at once, even if its first value equals the last
    {reply, ok, St#{patterns := Ps#{{Loop, Kind} => Text}, last := maps:remove({Loop, Kind}, L)}};
handle_call({clear, all}, _From, St) ->
    {reply, ok, St#{patterns := #{}, last := #{}}};
handle_call({clear, Which}, _From, St = #{patterns := Ps, last := L}) ->
    Keep = fun({{S, _} = Loop, _}, _) -> Loop =/= Which andalso S =/= Which end,
    {reply, ok, St#{patterns := maps:filter(Keep, Ps), last := maps:filter(Keep, L)}};
handle_call(patterns, _From, St = #{patterns := Ps}) ->
    {reply, Ps, St};
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_Message, St) ->
    {noreply, St}.

%% On each beat, sample every pattern at that beat (four to the bar) and
%% send what changed; then wait for the next beat.
handle_info(tick, St = #{patterns := Ps}) ->
    Now = erlang:system_time(microsecond),
    case {maps:size(Ps), tidal_link_anchor:beat_at(Now), tidal_link_anchor:tempo()} of
        {0, _, _} ->
            erlang:send_after(250, self(), tick),
            {noreply, St};
        {_, {ok, Beat}, {ok, Tempo}} when Tempo > 0 ->
            B = round(Beat),
            St1 = sample(B, St),
            Next = floor(Beat) + 1,
            Ms = max(1, round((Next - Beat) * 60000 / Tempo)),
            erlang:send_after(Ms, self(), tick),
            {noreply, St1};
        _ ->
            %% no Link: nothing to keep time by
            erlang:send_after(500, self(), tick),
            {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

sample(B, St = #{patterns := Ps, last := L}) ->
    L1 = maps:fold(
           fun({{Slot, N}, Kind} = K, Text, Acc) ->
                   case 'tidal_window@ps':windowSampler(B, 4, Text) of
                       {just, V} ->
                           case maps:get(K, Acc, none) of
                               V -> Acc;
                               _ ->
                                   rig_loops:place(Slot, N, Kind, V),
                                   Acc#{K => V}
                           end;
                       _ -> Acc   % a rest holds the last value
                   end
           end, L, Ps),
    St#{last := L1}.
