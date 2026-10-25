%% @doc Selene's MIDI rows: their LFOs sent as control changes
%% (docs/kb/plans/selene-midi-signals.md).
%%
%% A MIDI row (`lfot midi1 ch "1 …" cc "74 …"`) lives in the rack on the
%% stage (`selene/rack`), written by the Selene page and by `selene $` lines
%% alike, as every Selene bank does. This process follows the rack as
%% selene_retrig does, and every ?TICK_MS works out each signal's value a
%% little ahead (?AHEAD_US), on the Link clock, with reef's own LFO
%% (Reef.Selene.Model.lfoAt, held to the browser's by Reef.Conformance), and
%% schedules a CC through Diaphus (Tidal.MIDIBridge) for that moment when the
%% value has changed. The rig sends; the page only draws.
%%
%% A tempo LFO (`lfot`) runs on the beat, so it lands on the bar however the
%% tempo moves; a free one (`lfo`, Hz) runs on the wall clock. A muted row or
%% signal sends nothing, and while Selene is stopped (`selene $ hush` or
%% `hush`, held by selene_keeper, which tells this process) they all are.
-module(selene_midi).
-behaviour(gen_server).

-export([start_link/0, hush/0, play/0, signals/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RACK, <<"selene/rack">>).
-define(TICK_MS, 10).
%% How far ahead a value is worked out and scheduled: past the jitter of
%% this process's own timer, well inside what a player hears as late.
-define(AHEAD_US, 30000).
%% With no Link anchor, the tempo a tempo LFO runs at.
-define(DEFAULT_BPM, 120.0).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

hush() -> cast(hush).
play() -> cast(play).

%% What is being sent, for inspection from a shell.
signals() -> gen_server:call(?MODULE, signals).

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
    {ok, Sock} = gen_udp:open(0, [binary]),
    erlang:send_after(?TICK_MS, self(), tick),
    %% stopped with the rest of Selene, if it is (selene_keeper holds that)
    {ok, #{rack => Rack, signals => signals_of(Rack), sent => #{}, hushed => not selene_keeper:running(), socket => Sock,
           port => 'reef_selene_model@ps':midiPort()}}.

handle_call(signals, _From, St = #{signals := S}) ->
    {reply, S, St};
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(hush, St) ->
    {noreply, St#{hushed := true}};
handle_cast(play, St) ->
    %% from silence, every value is said again
    {noreply, St#{hushed := false, sent := #{}}};
handle_cast(_Message, St) ->
    {noreply, St}.

handle_info(tick, St) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, send_due(St)};
handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := ?RACK, <<"text">> := T} when is_binary(T) ->
            {noreply, follow(T, St)};
        #{<<"key">> := ?RACK} ->
            {noreply, follow(<<>>, St)};
        _ ->
            {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, #{socket := Sock}) ->
    catch gen_udp:close(Sock),
    ok.

%% A new rack: its MIDI signals, read once here rather than every tick.
follow(Rack, St = #{rack := Rack}) -> St;
follow(Rack, St) -> St#{rack := Rack, signals := signals_of(Rack)}.

%% Each signal the rack's MIDI rows send, as reef says (midiSends): those
%% with a CC, their row and themselves not muted, the first on a channel
%% and CC only, so a controller is never fought over. Read once a rack.
signals_of(<<>>) -> [];
signals_of(Rack) ->
    case catch 'reef_selene_model@ps':midiSends('reef_selene_rack@ps':parseRack(Rack)) of
        Sends when is_tuple(Sends) -> array:to_list(Sends);
        Sends when is_list(Sends) -> Sends;
        _ -> []
    end.

%% Every signal's value ?AHEAD_US from now, scheduled for then when it has
%% changed since the last one sent on that channel and controller.
send_due(St = #{hushed := true}) -> St;
send_due(St = #{signals := []}) -> St;
send_due(St = #{signals := Signals, sent := Sent, socket := Sock, port := Port}) ->
    AtUs = erlang:system_time(microsecond) + ?AHEAD_US,
    Beat = beat_at(AtUs),
    Seconds = AtUs / 1000000.0,
    Tick = AtUs div (?TICK_MS * 1000),
    Sent2 = lists:foldl(
              fun(Send = #{tempo := Tempo, lfo := Slot, channel := Ch, cc := CC}, Acc) ->
                      Rate = maps:get(rate, Slot),
                      Cycles = case Tempo of
                                   true -> Beat * Rate;
                                   false -> Seconds * Rate
                               end,
                      %% within the signal's span (lo..hi, turned over when lo > hi)
                      V = 'reef_selene_model@ps':ccIn(Send, 'reef_selene_model@ps':lfoAt(Slot, Cycles, Tick)),
                      Key = {Ch, CC},
                      case maps:get(Key, Acc, undefined) of
                          V -> Acc;
                          _ ->
                              Schedule = 'tidal_mIDIBridge@foreign':scheduleCCAt(Sock, Port, Ch, CC, V, AtUs),
                              Schedule(),
                              Acc#{Key => V}
                      end
              end, Sent, Signals),
    St#{sent := Sent2}.

%% The beat at a moment: Link's when there is an anchor, else the wall clock
%% at ?DEFAULT_BPM, so a tempo LFO still moves with no Link.
beat_at(AtUs) ->
    case catch tidal_link_anchor:beat_at(AtUs) of
        {ok, Beat} -> Beat;
        _ -> AtUs / 1000000.0 * ?DEFAULT_BPM / 60.0
    end.
