%% @doc Selene's MIDI signals bound to parameters in Ableton Live
%% (docs/kb/plans/selene-ableton-destinations.md).
%%
%% A signal of a MIDI row may name the parameter it moves in Live, by Live's
%% own names, on its slot line in the rack: `÷4 @0 tri 1  to "Bass/Auto
%% Filter/Frequency"`. The binding itself is made in Live by the Selene
%% control surface (ableton/Selene, chosen in Live's MIDI preferences with
%% the IAC Tidal bus as its input), with Live's own MIDI map, so a mapped
%% parameter moves as a hand mapping does. The rack is the truth and the
%% script holds nothing: every ?EVERY_MS this process sends it the rack's
%% bindings (reef's midiBindings) over UDP, and it binds each by name in
%% whatever Set is open and says how each went. So a Set loaded, or a track
%% renamed back, is picked up within a second, and a name the Set lacks is
%% said, never guessed.
%%
%% What the page shows under each signal comes from here, told to every
%% page as `destinations selene <json>` when it changes:
%%   bound     Live has it, and the parameter follows;
%%   unbound   no parameter of that name in this Set;
%%   ambiguous more than one;
%%   shadowed  the rig has been changing its CC through two reports and the
%%             parameter has not moved: a hand mapping on that CC wins in
%%             Live, silently (found in the first test, 2026-10-25);
%%   refused   another signal holds its CC or its parameter;
%% and `live` false when the script has not answered for ?SILENT_MS.
%%
%% `selene $ map midi1 1` binds signal 1 of MIDI row 1 to the parameter last
%% clicked in Live (asked of the script), giving it a free CC if it had
%% none; `selene $ unmap midi1 1` unbinds it. Both put the rack on the
%% stage, so the page and selene_midi follow, as a line does.
%%
%% Nothing here may take the rig down: a bad datagram is dropped, and a
%% failure to read the rack sends no bindings.
-module(selene_ableton).
-behaviour(gen_server).

-export([start_link/0, map/2, unmap/2, destinations/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RACK, <<"selene/rack">>).
%% The Selene control surface's port (ableton/Selene/__init__.py), unless
%% the app's `ableton_port` says otherwise (a test against a fake Live).
-define(LIVE, {127, 0, 0, 1}).
-define(LIVE_PORT, application:get_env(purerl_tidal, ableton_port, 57140)).
-define(EVERY_MS, 1000).
%% Live is not answering after this long without a report.
-define(SILENT_MS, 3000).
%% How long a map waits for Live to say what is selected.
-define(ASK_MS, 1500).
%% Reports running in which the CC changed and the parameter did not.
-define(SHADOWED_AFTER, 2).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Bind MIDI row `Row`'s signal `Slot` (from 1) to Live's selected
%% parameter: {ok, Said} or {error, Why}.
map(Row, Slot) -> gen_server:call(?MODULE, {map, Row, Slot}, ?ASK_MS + 1000).

%% Unbind it: {ok, Said} or {error, Why}.
unmap(Row, Slot) -> gen_server:call(?MODULE, {unmap, Row, Slot}).

%% What every page is told, as its text.
destinations() -> gen_server:call(?MODULE, destinations).

init([]) ->
    Table = tidal_stage:text_subscribe(self()),
    Rack = case maps:get(?RACK, Table, undefined) of
               #{text := T} when is_binary(T) -> T;
               _ -> <<>>
           end,
    {ok, Sock} = gen_udp:open(0, [binary, {ip, ?LIVE}, {active, true}]),
    self() ! tick,
    {ok, #{socket => Sock, rack => Rack, bindings => bindings_of(Rack),
           %% the last report from Live: when, and each binding's state
           heard => never, reports => #{},
           %% when the last bindings went, and the one before (a report's window)
           sent_at => erlang:system_time(microsecond), window_from => erlang:system_time(microsecond),
           stills => #{}, asking => none, told => <<>>}}.

handle_call(destinations, _From, St) ->
    {reply, text_of(St), St};
handle_call({map, _Row, _Slot}, _From, St = #{asking := {_, _, _, _}}) ->
    {reply, {error, <<"a map is already asking Live what is selected">>}, St};
handle_call({map, Row, Slot}, From, St = #{socket := Sock}) ->
    %% the answer comes as a datagram: the call is answered from there, or
    %% by the timer when Live is silent
    catch gen_udp:send(Sock, ?LIVE, ?LIVE_PORT, <<"selected">>),
    Timer = erlang:send_after(?ASK_MS, self(), {asked_too_long, From}),
    {noreply, St#{asking := {From, Row, Slot, Timer}}};
handle_call({unmap, Row, Slot}, _From, St) ->
    Rack = rack_now(),
    case catch 'reef_selene_model@ps':midiUnmap(Row, Slot, parsed(Rack)) of
        {left, Why} -> {reply, {error, Why}, St};
        {right, Sel} ->
            St1 = put_rack('reef_selene_rack@ps':printRack(Sel), St),
            {reply, {ok, iolist_to_binary([signal_name(Row, Slot), <<" is unmapped (its CC is kept)">>])}, St1};
        Other -> {reply, {error, iolist_to_binary(io_lib:format("~p", [Other]))}, St}
    end;
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_Message, St) ->
    {noreply, St}.

handle_info(tick, St) ->
    erlang:send_after(?EVERY_MS, self(), tick),
    {noreply, tell(send_bindings(St))};
handle_info({udp, Sock, _Ip, _Port, Data}, St = #{socket := Sock}) ->
    {noreply, tell(heard(Data, St))};
handle_info({asked_too_long, From}, St = #{asking := {From, _, _, _}}) ->
    gen_server:reply(From, {error, not_answering()}),
    {noreply, St#{asking := none}};
handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := ?RACK, <<"text">> := T} when is_binary(T) -> {noreply, follow(T, St)};
        #{<<"key">> := ?RACK} -> {noreply, follow(<<>>, St)};
        _ -> {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, #{socket := Sock}) ->
    catch gen_udp:close(Sock),
    ok.

%% A new rack: its bindings, sent at once, so a map is seen in Live now
%% rather than at the next tick.
follow(Rack, St = #{rack := Rack}) -> St;
follow(Rack, St) -> tell(send_bindings(St#{rack := Rack, bindings := bindings_of(Rack)})).

%% The bindings to Live, those not refused; the window of the report it
%% answers with runs from the last send to this one.
send_bindings(St = #{socket := Sock, bindings := Bindings, sent_at := Last}) ->
    Wanted = [#{key => key(B), channel => Ch, cc => CC, to => To}
              || B = #{channel := Ch, cc := CC, to := To, refused := {nothing}} <- Bindings],
    catch gen_udp:send(Sock, ?LIVE, ?LIVE_PORT, iolist_to_binary([<<"bindings ">>, json:encode(Wanted)])),
    St#{sent_at := erlang:system_time(microsecond), window_from := Last}.

%% A datagram from Live: a report on the bindings, or what is selected.
heard(<<"report ", Json/binary>>, St = #{bindings := Bindings, stills := Stills, window_from := From}) ->
    case catch json:decode(Json) of
        Reports when is_list(Reports) ->
            ByKey = maps:from_list([{K, R} || R = #{<<"key">> := K} <- Reports, is_map(R)]),
            Changes = case catch selene_midi:changes() of
                          C when is_map(C) -> C;
                          _ -> #{}
                      end,
            %% a binding whose CC changed in the window and whose parameter
            %% did not move is one step nearer shadowed; one that moved, or
            %% whose CC was still, is not
            Stills1 = maps:from_list(
                        [{key(B), still(B, ByKey, Changes, From, Stills)} || B <- Bindings]),
            St#{heard := erlang:monotonic_time(millisecond), reports := ByKey, stills := Stills1};
        _ -> St
    end;
heard(<<"selected ", Json/binary>>, St = #{asking := {From, Row, Slot, Timer}}) ->
    erlang:cancel_timer(Timer),
    {Reply, St1} = mapped(catch json:decode(Json), Row, Slot, St),
    gen_server:reply(From, Reply),
    St1#{asking := none, heard := erlang:monotonic_time(millisecond)};
heard(_Data, St) ->
    St.

still(B = #{channel := Ch, cc := CC}, ByKey, Changes, From, Stills) ->
    Was = maps:get(key(B), Stills, 0),
    case maps:get(key(B), ByKey, undefined) of
        #{<<"state">> := <<"bound">>, <<"moved">> := false} ->
            case maps:get({Ch, CC}, Changes, 0) >= From of
                true -> Was + 1;
                false -> Was
            end;
        _ -> 0
    end.

%% Live's selected parameter, bound to the signal: reef's midiMap on the
%% rack, which goes back on the stage.
mapped(#{<<"path">> := null}, _Row, _Slot, St) ->
    {{error, <<"nothing is selected in Live: click the parameter there first, then map">>}, St};
mapped(#{<<"path">> := Path, <<"count">> := Count}, _Row, _Slot, St) when Count > 1 ->
    {{error, iolist_to_binary([integer_to_binary(Count), <<" parameters in this Set are called ">>, Path,
                               <<": rename a track or device so the name says which">>])}, St};
mapped(#{<<"path">> := Path}, Row, Slot, St) when is_binary(Path) ->
    case catch 'reef_selene_model@ps':midiMap(Row, Slot, Path, parsed(rack_now())) of
        {left, Why} -> {{error, Why}, St};
        {right, #{rack := Sel, channel := Ch, cc := CC, given := Given}} ->
            St1 = put_rack('reef_selene_rack@ps':printRack(Sel), St),
            How = case Given of
                      true -> <<" (given channel ">>;
                      false -> <<" (channel ">>
                  end,
            {{ok, iolist_to_binary([signal_name(Row, Slot), <<" moves ">>, Path, How,
                                    integer_to_binary(Ch), <<" CC ">>, integer_to_binary(CC), <<")">>])}, St1};
        Other -> {{error, iolist_to_binary(io_lib:format("~p", [Other]))}, St}
    end;
mapped(_, _Row, _Slot, St) ->
    {{error, <<"Live's answer about what is selected could not be read">>}, St}.

%% Every page told what each binding is doing, when that has changed.
tell(St = #{told := Told}) ->
    case text_of(St) of
        Told -> St;
        Text ->
            catch tidal_link_anchor:sync_broadcast(Text),
            St#{told := Text}
    end.

text_of(St = #{bindings := Bindings}) ->
    Live = live(St),
    Signals = [destination(B, Live, St) || B <- Bindings],
    iolist_to_binary([<<"destinations selene ">>, json:encode(#{live => Live, signals => Signals})]).

destination(B = #{row := Row, slot := Slot, to := To, refused := Refused}, Live, #{reports := Reports, stills := Stills}) ->
    {State, Said} =
        case {Refused, Live, maps:get(key(B), Reports, undefined)} of
            {{just, Why}, _, _} -> {<<"refused">>, Why};
            {_, false, _} -> {<<"waiting">>, not_answering()};
            {_, true, undefined} -> {<<"waiting">>, <<"not yet reported by Live">>};
            {_, true, #{<<"state">> := <<"bound">>}} ->
                case maps:get(key(B), Stills, 0) >= ?SHADOWED_AFTER of
                    true -> {<<"shadowed">>, <<"Live isn't following this CC: a hand mapping on it in Live wins (\x{2318}M to find it)"/utf8>>};
                    false -> {<<"bound">>, <<>>}
                end;
            {_, true, #{<<"state">> := S} = R} -> {S, maps:get(<<"said">>, R, <<>>)};
            _ -> {<<"waiting">>, <<>>}
        end,
    #{row => Row, slot => Slot, to => To, state => State, said => Said}.

live(#{heard := never}) -> false;
live(#{heard := At}) -> erlang:monotonic_time(millisecond) - At < ?SILENT_MS.

not_answering() ->
    <<"Live isn't answering: is Selene chosen as a control surface in Live's MIDI preferences (input IAC Driver Tidal)?">>.

put_rack(Text, St) ->
    _ = tidal_stage:put_text(?RACK, Text, nobody),
    follow(Text, St).

rack_now() ->
    case tidal_stage:get_text(?RACK) of
        T when is_binary(T) -> T;
        _ -> <<>>
    end.

bindings_of(<<>>) -> [];
bindings_of(Rack) ->
    case catch 'reef_selene_model@ps':midiBindings(parsed(Rack)) of
        Bs when is_tuple(Bs) -> array:to_list(Bs);
        Bs when is_list(Bs) -> Bs;
        _ -> []
    end.

parsed(Rack) -> 'reef_selene_rack@ps':parseRack(Rack).

key(#{row := Row, slot := Slot}) ->
    <<"midi", (integer_to_binary(Row))/binary, " ", (integer_to_binary(Slot))/binary>>.

signal_name(Row, Slot) ->
    [<<"MIDI ">>, integer_to_binary(Row), <<" signal ">>, integer_to_binary(Slot)].
