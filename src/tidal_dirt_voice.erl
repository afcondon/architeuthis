%% @doc A Tidal stream to SuperDirt: one process per `d1`..`d16`.
%%
%% Holds a `Tidal.DirtVoice.State` (opaque here) and a UDP socket. On each
%% `{compute_until, Window}` from tidal_clock it asks the PureScript side for
%% the `/dirt/play` messages that window holds and sends each as a bundle
%% timetagged at its onset (dirt_osc). The timing rules (arc from where the
%% last one ended, onsets only, snap on a clock jump) are in DirtVoice.purs.
%%
%% Registered as `tidal_dirt_d<N>`: a namespace of its own, so a `bind d1 …`
%% for the binding voices cannot redirect a Tidal stream.
%%
%% One more stream, `drums` (`tidal_dirt_drums`, the line `drums $ …`), is
%% timed the same way but plays drum hits instead (Tidal.DrumVoice): each
%% event names a lane of the drum kit, and reef_balistes_voice:play_hit sends
%% it down the drum routing table, as Balistes' own engines are sent.
%%
%% And one per FH-2 LFO bank with a reset pattern, `{retrig, Base}`
%% (`tidal_retrig_<Base>`, kept in step with the rack by selene_retrig): each
%% event names slots of the bank, and Tidal.RetrigVoice turns them into the
%% notes that reset those outputs' LFOs (channel 16, note = FH-2 output),
%% sent timetagged through Diaphus like any scheduled note.
%%
%% And one per Selene bank with a mute pattern, `{mutes, Socket, Bank}`
%% (kept in step with the rack by selene_mutes): Tidal.MuteVoice works out
%% each moment the set of muted slots changes, and selene_mutes is told at
%% that moment, to send the bank to its daemon with them silent.
%%
%% And one per Selene POLYVOLT bank with outputs that follow patterns of
%% voltages, `{volts, Socket, Bank}` (also kept by selene_mutes):
%% Tidal.VoltVoice works out each moment an output steps to a new voltage,
%% and selene_mutes is told then, to send the bank with those voltages.
-module(tidal_dirt_voice).
-behaviour(gen_server).

-export([start_link/1, set_pattern/2, registered_name/1, muted_now/2, volts_now/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% how long a mute or volt stream's first answer waits for a window (ticks are 50 ms)
-define(FIRST_WINDOW_MS, 250).

start_link(Stream) ->
    gen_server:start_link({local, registered_name(Stream)}, ?MODULE, Stream, []).

%% Install a ControlPattern on the stream; heard from the next arc. A volt
%% stream takes a PureScript array of {slot, pattern}, and anything else (a
%% hush's silence) as none.
set_pattern(Stream, Pattern) ->
    gen_server:call(registered_name(Stream), {set_pattern, Pattern}).

%% What Pattern mutes at this moment on a mute stream's clock, as a
%% PureScript array of slots. A stream just started has no clock until its
%% first window, a tick away, so the answer waits for it (AC, 2026-10-26: a
%% bank's first pattern, as when a bank is unmuted, went out unmuted); `none`
%% if no window comes (the clock paused).
muted_now(Stream = {mutes, _, _}, Pattern) ->
    gen_server:call(registered_name(Stream), {now, Pattern}).

%% What Patterns hold at this moment on a volt stream's clock, as a
%% PureScript array of {slot, volts}; waits for a first window as muted_now.
volts_now(Stream = {volts, _, _}, Patterns) ->
    gen_server:call(registered_name(Stream), {now, Patterns}).

registered_name(drums) -> tidal_dirt_drums;
registered_name({retrig, Base}) -> list_to_atom("tidal_retrig_" ++ integer_to_list(Base));
registered_name({mutes, Socket, Bank}) -> binary_to_atom(<<"tidal_mutes_", Socket/binary, "_", Bank/binary>>);
registered_name({volts, Socket, Bank}) -> binary_to_atom(<<"tidal_volts_", Socket/binary, "_", Bank/binary>>);
registered_name(Stream) when is_integer(Stream) ->
    list_to_atom("tidal_dirt_d" ++ integer_to_list(Stream)).

init(Stream = {mutes, _, _}) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    %% the stream's state, and the last window it saw (for muted_now)
    {ok, {Stream, {'tidal_muteVoice@ps':initialState(), none}, Sock}};
init(Stream = {volts, _, _}) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    {ok, {Stream, {'tidal_voltVoice@ps':initialState(), none}, Sock}};
init(Stream) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Id = case Stream of drums -> 0; {retrig, _} -> 0; _ -> Stream end,
    {ok, {Stream, 'tidal_dirtVoice@ps':initialState(Id), Sock}}.

handle_call({set_pattern, Pattern}, _From, {Stream = {mutes, _, _}, {Ps, W}, Sock}) ->
    {reply, ok, {Stream, {'tidal_muteVoice@ps':setPattern(Pattern, Ps), W}, Sock}};
handle_call({set_pattern, Patterns}, _From, {Stream = {volts, _, _}, {Ps, W}, Sock}) ->
    Ps1 = 'tidal_voltVoice@ps':setPatterns(case array:is_array(Patterns) of true -> Patterns; false -> array:new() end, Ps),
    {reply, ok, {Stream, {Ps1, W}, Sock}};
handle_call({now, Ask}, From, {Stream = {Kind, _, _}, {Ps, W}, Sock}) when (Kind =:= mutes orelse Kind =:= volts), not is_map(W) ->
    Waiting = case W of {waiting, Ws} -> Ws; none -> [] end,
    erlang:send_after(?FIRST_WINDOW_MS, self(), {no_window, From}),
    {noreply, {Stream, {Ps, {waiting, [{From, Ask} | Waiting]}}, Sock}};
handle_call({now, Ask}, _From, State = {{Kind, _, _}, {_, W}, _}) when Kind =:= mutes orelse Kind =:= volts ->
    {reply, now_at(Kind, Ask, W), State};
handle_call({set_pattern, Pattern}, _From, {Stream, Ps, Sock}) ->
    {reply, ok, {Stream, 'tidal_dirtVoice@ps':setPattern(Pattern, Ps), Sock}}.

handle_cast({compute_until, Window}, {drums, Ps, Sock}) ->
    #{newState := Ps1, hits := Hits} = 'tidal_drumVoice@ps':computeHits(Window, Ps),
    array:foldl(
      fun(_, #{atUnixUs := At, note := Note, velocity := Vel, durMs := Dur, spanMs := Span}, _) ->
              reef_balistes_voice:play_hit(Sock, Note, Vel, Dur, Span, round(At))
      end, ok, Hits),
    {noreply, {drums, Ps1, Sock}};
handle_cast({compute_until, Window}, {{retrig, Base} = Stream, Ps, Sock}) ->
    #{newState := Ps1, resets := Resets} = 'tidal_retrigVoice@ps':computeResets(Base, Window, Ps),
    Channel = 'tidal_retrigVoice@ps':resetChannel(),
    array:foldl(
      fun(_, #{atUnixUs := At, note := Note}, _) ->
              Send = 'tidal_mIDIBridge@foreign':scheduleNoteAt(
                       Sock, <<"FH-2">>, Channel, Note, 127, 5, round(At)),
              Send()
      end, ok, Resets),
    {noreply, {Stream, Ps1, Sock}};
handle_cast({compute_until, Window}, {{volts, Socket, Bank} = Stream, {Ps, W}, Sock}) ->
    answer_waiting(volts, W, Window),
    #{newState := Ps1, changes := Changes} = 'tidal_voltVoice@ps':computeVolts(Window, Ps),
    NowUs = erlang:system_time(microsecond),
    array:foldl(
      fun(_, #{atUnixUs := At, volts := Volts}, _) ->
              Delay = max(0, round((At - NowUs) / 1000)),
              timer:apply_after(Delay, selene_mutes, volts_change, [Socket, Bank, Volts])
      end, ok, Changes),
    {noreply, {Stream, {Ps1, Window}, Sock}};
handle_cast({compute_until, Window}, {{mutes, Socket, Bank} = Stream, {Ps, W}, Sock}) ->
    answer_waiting(mutes, W, Window),
    #{newState := Ps1, changes := Changes} = 'tidal_muteVoice@ps':computeMutes(Window, Ps),
    NowUs = erlang:system_time(microsecond),
    array:foldl(
      fun(_, #{atUnixUs := At, muted := Muted}, _) ->
              Delay = max(0, round((At - NowUs) / 1000)),
              timer:apply_after(Delay, selene_mutes, change, [Socket, Bank, Muted])
      end, ok, Changes),
    {noreply, {Stream, {Ps1, Window}, Sock}};
handle_cast({compute_until, Window}, {Stream, Ps, Sock}) ->
    #{newState := Ps1, messages := Messages} =
        'tidal_dirtVoice@ps':computeUntil(Window, Ps),
    %% PureScript arrays are Erlang `array`s; the args inside one too.
    array:foldl(
      fun(_, #{atUnixUs := At, args := Args}, _) ->
              Msg = dirt_osc:encode_msg(<<"/dirt/play">>, array:to_list(Args)),
              dirt_osc:send_at(Sock, round(At), Msg)
      end, ok, Messages),
    {noreply, {Stream, Ps1, Sock}};
handle_cast(_, State) ->
    {noreply, State}.

handle_info({no_window, From}, {Stream, {Ps, {waiting, Ws}}, Sock}) ->
    case lists:keymember(From, 1, Ws) of
        true -> gen_server:reply(From, none);
        false -> ok
    end,
    Ws1 = lists:keydelete(From, 1, Ws),
    {noreply, {Stream, {Ps, case Ws1 of [] -> none; _ -> {waiting, Ws1} end}, Sock}};
handle_info(_, State) ->
    {noreply, State}.

%% A first window come: those waiting for the stream's clock are answered.
answer_waiting(Kind, {waiting, Ws}, Window) -> [gen_server:reply(F, now_at(Kind, A, Window)) || {F, A} <- Ws], ok;
answer_waiting(_, _, _) -> ok.

%% What a mute pattern mutes, or volt patterns hold, now, on Window's clock.
now_at(Kind, Ask, #{currentCycle := C, nowUnixUs := At, cycleDurationMs := Dur}) ->
    Now = C + (erlang:system_time(microsecond) - At) / 1000 / Dur,
    case Kind of
        mutes -> 'tidal_muteVoice@ps':mutedAt(Ask, Now);
        volts -> 'tidal_voltVoice@ps':voltsAt(Ask, Now)
    end.

terminate(_Reason, {_, _, Sock}) ->
    gen_udp:close(Sock),
    ok.
