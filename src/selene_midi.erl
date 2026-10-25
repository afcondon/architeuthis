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
%%
%% Learn (`selene $ learn midi1 3`): one signal is learned, and while it is
%% the rig sends no other MIDI at all (the gate in Tidal.MIDIBridge), so an
%% instrument's MIDI map hears that controller alone. This process holds
%% which signal it is and keeps the gate on its channel and CC as the rack
%% changes. `selene $ unlearn` ends it, as a stop of Selene does (a learn
%% left on would silence the whole rig's MIDI), and a restart forgets it.
%% Every page is told: `learning selene midi1 3`, `unlearned selene`.
%%
%% A throw (`throw midi4`) rests at the bottom of its span until fired
%% (`selene $ fire midi4 2`, or the page's fire button), then plays its
%% attack, hold and decay once (reef's throwAt). The fire begins at once or
%% on the next beat or bar, as the throw says, so a riser in bars lands on a
%% downbeat. A fire while one plays starts it again. Every page is told,
%% `fired selene midi4 2`.
-module(selene_midi).
-behaviour(gen_server).

-export([start_link/0, hush/0, play/0, signals/0, learn/2, unlearn/0, learning/0, fire/2, changes/0]).
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

%% Learn MIDI row `Row`'s signal `Slot` (from 1): {ok, Reply} or {error, Why}.
learn(Row, Slot) -> gen_server:call(?MODULE, {learn, Row, Slot}).

%% End learn: `ok`, or `none` when nothing was learned.
unlearn() -> gen_server:call(?MODULE, unlearn).

%% What is learned: `none` or {Row, Slot}.
learning() -> gen_server:call(?MODULE, learning).

%% Fire MIDI row `Row`'s throw `Slot` (from 1): {ok, Reply} or {error, Why}.
fire(Row, Slot) -> gen_server:call(?MODULE, {fire, Row, Slot}).

%% When each channel and CC last changed, #{{Ch, CC} => Us} (the moment it
%% was scheduled for): selene_ableton reads it to tell a parameter that does
%% not follow its CC from one whose CC is still.
changes() -> gen_server:call(?MODULE, changes).

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
    %% a learn does not outlive the process that kept it
    'tidal_mIDIBridge@foreign':learn_gate(off),
    erlang:send_after(?TICK_MS, self(), tick),
    %% stopped with the rest of Selene, if it is (selene_keeper holds that)
    {ok, #{rack => Rack, signals => signals_of(Rack), sent => #{}, hushed => not selene_keeper:running(), socket => Sock, learn => none, fired => #{}, changed => #{},
           port => 'reef_selene_model@ps':midiPort()}}.

handle_call(signals, _From, St = #{signals := S}) ->
    {reply, S, St};
handle_call(changes, _From, St = #{changed := C}) ->
    {reply, C, St};
handle_call({learn, _Row, _Slot}, _From, St = #{hushed := true}) ->
    {reply, {error, <<"Selene is stopped, and a stopped signal can't be learned: selene $ play first">>}, St};
handle_call({learn, Row, Slot}, _From, St = #{rack := Rack}) ->
    case 'reef_selene_model@ps':midiLearn(Row, Slot, parsed(Rack)) of
        {left, Why} -> {reply, {error, Why}, St};
        {right, #{channel := Ch, cc := CC, sending := Sending}} ->
            St1 = gate(St#{learn := {Row, Slot}, sent := #{}}),
            catch tidal_link_anchor:sync_broadcast(learning_text(Row, Slot)),
            Muted = case Sending of
                        true -> <<>>;
                        false -> <<"; it is muted, so nothing is sent until it is unmuted">>
                    end,
            {reply, {ok, iolist_to_binary(
                           [<<"learning MIDI ">>, integer_to_binary(Row), <<" signal ">>, integer_to_binary(Slot),
                            <<": channel ">>, integer_to_binary(Ch), <<" CC ">>, integer_to_binary(CC),
                            <<" is all the MIDI the rig sends until selene $ unlearn">>, Muted])}, St1}
    end;
handle_call(unlearn, _From, St = #{learn := none}) ->
    {reply, none, St};
handle_call(unlearn, _From, St) ->
    {reply, ok, unlearned(St)};
handle_call(learning, _From, St = #{learn := L}) ->
    {reply, L, St};
handle_call({fire, _Row, _Slot}, _From, St = #{hushed := true}) ->
    {reply, {error, <<"Selene is stopped, so a throw can't be fired: selene $ play first">>}, St};
handle_call({fire, Row, Slot}, _From, St = #{signals := Signals, rack := Rack, fired := Fired}) ->
    Name = [<<"MIDI ">>, integer_to_binary(Row), <<" signal ">>, integer_to_binary(Slot)],
    case [S || S = #{row := R, slot := K} <- Signals, R == Row, K == Slot] of
        [#{signal := {throwSignal, Throw}}] ->
            Now = beat_at(erlang:system_time(microsecond)),
            Start = 'reef_selene_model@ps':throwStartAt(maps:get(start, Throw), Now),
            catch tidal_link_anchor:sync_broadcast(
                    <<"fired selene midi", (integer_to_binary(Row))/binary, " ", (integer_to_binary(Slot))/binary>>),
            When = case Start - Now of
                       Wait when Wait > 0.001 -> io_lib:format(" (it begins in ~.2f beats)", [Wait]);
                       _ -> <<>>
                   end,
            {reply, {ok, iolist_to_binary([<<"fired ">>, Name, When])}, St#{fired := Fired#{{Row, Slot} => Start}}};
        [_] ->
            {reply, {error, iolist_to_binary([Name, <<" is an LFO: only a throw is fired">>])}, St};
        [] ->
            %% not sending: why, as learn says it (no row, no signal, no CC), else muted
            Why = case 'reef_selene_model@ps':midiLearn(Row, Slot, parsed(Rack)) of
                      {left, W} -> W;
                      {right, _} -> iolist_to_binary([Name, <<" is muted">>])
                  end,
            {reply, {error, Why}, St}
    end;
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(hush, St = #{learn := none}) ->
    {noreply, St#{hushed := true}};
handle_cast(hush, St) ->
    %% a stop ends a learn: left on, it would hold back all the rig's MIDI
    {noreply, (unlearned(St))#{hushed := true}};
handle_cast(play, St) ->
    %% from silence, every value is said again, and no throw is mid-flight
    {noreply, St#{hushed := false, sent := #{}, fired := #{}}};
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
    catch 'tidal_mIDIBridge@foreign':learn_gate(off),
    catch gen_udp:close(Sock),
    ok.

%% A new rack: its MIDI signals, read once here rather than every tick.
follow(Rack, St = #{rack := Rack}) -> St;
follow(Rack, St) -> gate(St#{rack := Rack, signals := signals_of(Rack)}).

%% The gate on the learned signal's channel and CC as the rack has them now:
%% shut, passing nothing, while it has none or is gone from the rack (the
%% learn stays, and picks the signal up again when it comes back).
gate(St = #{learn := none}) -> St;
gate(St = #{learn := {Row, Slot}, rack := Rack, port := Port}) ->
    Gate = case 'reef_selene_model@ps':midiLearn(Row, Slot, parsed(Rack)) of
               {right, #{channel := Ch, cc := CC}} -> {to_binary(Port), Ch, CC};
               _ -> shut
           end,
    'tidal_mIDIBridge@foreign':learn_gate(Gate),
    St.

%% Learn ended: the gate opens, and every value is said again, since those
%% held back are not what the instruments last heard.
unlearned(St) ->
    'tidal_mIDIBridge@foreign':learn_gate(off),
    catch tidal_link_anchor:sync_broadcast(<<"unlearned selene">>),
    St#{learn := none, sent := #{}}.

learning_text(Row, Slot) ->
    <<"learning selene midi", (integer_to_binary(Row))/binary, " ", (integer_to_binary(Slot))/binary>>.

parsed(Rack) -> 'reef_selene_rack@ps':parseRack(Rack).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).

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
send_due(St = #{signals := Signals, sent := Sent, socket := Sock, port := Port, fired := Fired, changed := Changed}) ->
    AtUs = erlang:system_time(microsecond) + ?AHEAD_US,
    Moment = #{beat => beat_at(AtUs), seconds => AtUs / 1000000.0, tick => AtUs div (?TICK_MS * 1000),
               bpm => bpm(), fired => {nothing}},
    {Sent2, Changed2} = lists:foldl(
              fun(Send = #{row := Row, slot := Slot, channel := Ch, cc := CC}, {Acc, Ch0}) ->
                      At = case maps:get({Row, Slot}, Fired, none) of
                               none -> Moment;
                               Start -> Moment#{fired := {just, Start}}
                           end,
                      %% an LFO's swing or a throw's rise and fall, within the
                      %% signal's span (lo..hi, turned over when lo > hi)
                      V = 'reef_selene_model@ps':midiValueAt(Send, At),
                      Key = {Ch, CC},
                      case maps:get(Key, Acc, undefined) of
                          V -> {Acc, Ch0};
                          _ ->
                              Schedule = 'tidal_mIDIBridge@foreign':scheduleCCAt(Sock, Port, Ch, CC, V, AtUs),
                              Schedule(),
                              {Acc#{Key => V}, Ch0#{Key => AtUs}}
                      end
              end, {Sent, Changed}, Signals),
    St#{sent := Sent2, changed := Changed2}.

%% The tempo: Link's, else ?DEFAULT_BPM, as beat_at assumes.
bpm() ->
    case catch tidal_link_anchor:tempo() of
        {ok, Bpm} -> float(Bpm);
        _ -> ?DEFAULT_BPM
    end.

%% The beat at a moment: Link's when there is an anchor, else the wall clock
%% at ?DEFAULT_BPM, so a tempo LFO still moves with no Link.
beat_at(AtUs) ->
    case catch tidal_link_anchor:beat_at(AtUs) of
        {ok, Beat} -> Beat;
        _ -> AtUs / 1000000.0 * ?DEFAULT_BPM / 60.0
    end.
