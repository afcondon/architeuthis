%% @doc Vetula's cards, played by the rig (docs/kb/plans/gpl-boundary-review.md,
%% step 3).
%%
%% The cards are text objects on the stage (`vetula/v3`, written by the Vetula
%% page or by Limulus, `docs/kb/plans/text-on-the-stage.md`). This process
%% subscribes to the stage, keeps each card parsed (reef's
%% `Reef.Vetula.Lepidoptera.parseCard`), and while playing walks the Link
%% grid as reef_voice does: every 25 ms it reads the anchor and, for each
%% pulse (a sixteenth) up to 200 ms ahead, strikes what each card's pattern
%% gives (`Tidal.Vetula.Card.cardHits`, Tidal through Littorina), at the
%% pulse's wall time, down the card's legs in the routing table: the dashboard
%% writes them to the stage as `vetula/routing` (a `Reef.Routing.VoiceRouting`,
%% voice N-1 for channel N), and each note goes through `voiceRoutingSends`,
%% as Odonus's heads do. Until one is written, a card plays its channel of
%% `IAC Driver Tidal`, as it always did.
%% A card with a sequence plays one pattern cycle per bar (slots on the bar
%% line), a plain card one chord per beat, as the page did.
%%
%% The notes it plays are broadcast to the pages (`vetula-notes <json>`, Unix
%% microseconds) so Vetula's Review logbook still captures them.
%%
%% Started by `vetula-cards-play` (the page entering Rig), stopped by
%% `vetula-cards-stop` and by hush. Idle without a fresh Link anchor.
-module(vetula_cards).

-export([play/0, stop/0, cards/0, route_note/8]).

-define(PORT, <<"IAC Driver Tidal">>).
-define(POLL_MS, 25).
-define(LOOKAHEAD_MS, 200.0).
-define(STALE_ANCHOR_US, 2000000).   % as reef_voice
-define(SNAP_AHEAD, 8).              % as reef_voice
-define(PULSE_BEATS, 0.25).
-define(VELOCITY, 90).

%% Start playing (idempotent): spawn the player if it is not running.
play() ->
    case whereis(?MODULE) of
        undefined ->
            Pid = spawn(fun init/0),
            try register(?MODULE, Pid) of
                true -> ok
            catch error:badarg -> exit(Pid, kill), ok   % lost a race: one is running
            end;
        _ -> ok
    end.

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

%% The cards the player holds, by number, for inspection from a shell.
cards() ->
    case whereis(?MODULE) of
        undefined -> #{};
        Pid -> Pid ! {cards, self()}, receive {cards, C} -> C after 1000 -> timeout end
    end.

init() ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    Table = tidal_stage:text_subscribe(self()),
    Progs = maps:fold(fun(Key, #{text := T}, Acc) ->
                              case vetula_progressions:take(Key, T, Acc) of
                                  {changed, Acc1} -> Acc1;
                                  same -> Acc
                              end
                      end, #{}, Table),
    Texts = maps:fold(fun(Key, #{text := T}, Acc) -> put_text(Key, T, Acc) end, #{}, Table),
    Routing = case maps:find(<<"vetula/routing">>, Table) of
                  {ok, #{text := RT}} -> routing(RT, none);
                  error -> none
              end,
    erlang:send_after(?POLL_MS, self(), tick),
    loop(#{sock => Sock, texts => Texts, progs => Progs, cards => read_cards(Texts, Progs),
           routing => Routing, last_pulse => -1}).

%% The stage's routing text, decoded; one that does not decode leaves the last.
routing(null, _) -> none;
routing(Text, Old) ->
    case 'reef_routing@ps':decodeVoiceRouting(Text) of
        {right, R} -> R;
        _ -> Old
    end.

loop(St) ->
    receive
        stop ->
            gen_udp:close(maps:get(sock, St)),
            ok;
        tick ->
            St1 = tick(St),
            erlang:send_after(?POLL_MS, self(), tick),
            loop(St1);
        {cards, From} ->
            From ! {cards, maps:get(cards, St)},
            loop(St);
        {stage_broadcast, <<"stage-text ", Json/binary>>} ->
            case catch json:decode(Json) of
                #{<<"key">> := <<"vetula/routing">>, <<"text">> := T} ->
                    loop(St#{routing => routing(T, maps:get(routing, St))});
                #{<<"key">> := Key, <<"text">> := T} ->
                    Progs = maps:get(progs, St),
                    {Texts1, Progs1} = case vetula_progressions:take(Key, T, Progs) of
                                           {changed, P} -> {maps:get(texts, St), P};
                                           same -> {put_text(Key, T, maps:get(texts, St)), Progs}
                                       end,
                    loop(St#{texts => Texts1, progs => Progs1, cards => read_cards(Texts1, Progs1)});
                _ ->
                    loop(St)
            end;
        _ ->
            loop(St)
    end.

%% A card written (or, with null, deleted) on the stage. Only `vetula/v<N>`
%% keys are cards; their text is kept as written, and read (read_cards) with
%% the progressions it may name, so a progression saved again reaches it.
put_text(<<"vetula/v", N/binary>>, Text, Texts) ->
    case string:to_integer(N) of
        {Id, <<>>} ->
            case Text of
                null -> maps:remove(Id, Texts);
                _ -> Texts#{Id => Text}
            end;
        _ -> Texts
    end;
put_text(_, _, Texts) -> Texts.

%% The cards the texts make; a line the parser refuses is dropped (the page
%% rejects it).
read_cards(Texts, Progs) ->
    maps:filtermap(fun(Id, Text) ->
                           case vetula_progressions:parse(Progs, Id, Text) of
                               {just, Spec} -> {true, Spec};
                               _ -> false
                           end
                   end, Texts).

tick(St) ->
    NowUs = erlang:system_time(microsecond),
    case tidal_link_anchor:info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, _Quantum, LastRecvUs}
                when (NowUs - LastRecvUs) =< ?STALE_ANCHOR_US, Tempo > 0 ->
            BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
            NowPulse = trunc(BeatNow / ?PULSE_BEATS),
            Next0 = maps:get(last_pulse, St) + 1,
            %% never replay history; re-snap on a jump either way (as reef_voice)
            Next = if (Next0 < NowPulse) orelse (Next0 > NowPulse + ?SNAP_AHEAD) -> NowPulse;
                      true -> Next0
                   end,
            Horizon = BeatNow + ?LOOKAHEAD_MS / 1000.0 * Tempo / 60.0,
            {Last, Played} = pulses(St, Next, Horizon, AnchorUs, BeatAtAnchor, Tempo, []),
            case Played of
                [] -> ok;
                _ -> tidal_link_anchor:sync_broadcast(
                       <<"vetula-notes ", (iolist_to_binary(json:encode(lists:reverse(Played))))/binary>>),
                     %% the record buffer keeps what Vetula played, by voice
                     catch rig_loops:record(<<"vetula">>,
                             [{AtUs, P, V, G, C} || #{atUs := AtUs, pitch := P, vel := V, gateMs := G, ch := C} <- Played])
            end,
            St#{last_pulse => Last};
        _ ->
            St
    end.

%% Strike every pulse whose beat is within the horizon; return the last one
%% struck and the notes played (newest first).
pulses(St, P, Horizon, AnchorUs, BeatAtAnchor, Tempo, Played) ->
    case P * ?PULSE_BEATS =< Horizon of
        false -> {P - 1, Played};
        true ->
            Played1 = maps:fold(
                        fun(_Id, Spec, Acc) -> card_pulse(St, Spec, P, AnchorUs, BeatAtAnchor, Tempo, Acc) end,
                        Played, maps:get(cards, St)),
            pulses(St, P + 1, Horizon, AnchorUs, BeatAtAnchor, Tempo, Played1)
    end.

%% A card strikes on the pulses that begin its slots: every 16th pulse (a bar)
%% for a card with a sequence, every 4th (a beat) otherwise.
card_pulse(St, Spec, P, AnchorUs, BeatAtAnchor, Tempo, Acc) ->
    case 'tidal_vetula_card@ps':cardSounds(Spec) of
        false -> Acc;
        true ->
            SlotPulses = case 'tidal_vetula_card@ps':cardOnBar(Spec) of true -> 16; false -> 4 end,
            case P rem SlotPulses of
                0 -> strike(St, Spec, P div SlotPulses, SlotPulses * ?PULSE_BEATS,
                            AnchorUs, BeatAtAnchor, Tempo, Acc);
                _ -> Acc
            end
    end.

strike(St, Spec, Slot, SlotBeats, AnchorUs, BeatAtAnchor, Tempo, Acc) ->
    Ch = maps:get(channel, Spec),
    StrumMs = 'tidal_vetula_card@ps':cardStrumMs(Spec),
    SlotMs = SlotBeats * 60000.0 / Tempo,
    Hits = array:to_list('tidal_vetula_card@ps':cardHits(Spec, Slot)),
    lists:foldl(
      fun(Hit, Acc1) ->
          StartBeat = Slot * SlotBeats + maps:get(at, Hit) * SlotBeats,
          StartUs = AnchorUs + (StartBeat - BeatAtAnchor) * 60000000.0 / Tempo,
          DurMs = max(20.0, maps:get(len, Hit) * SlotMs * 0.9),
          Notes = array:to_list(maps:get(notes, Hit)),
          {_, Acc2} = lists:foldl(
                        fun(Note, {K, A}) ->
                            AtUs = round(StartUs + K * StrumMs * 1000.0),
                            play(St, Ch, Note, DurMs, SlotMs, AtUs),
                            {K + 1, [#{pitch => Note, ch => Ch, atUs => AtUs, vel => ?VELOCITY, gateMs => DurMs} | A]}
                        end, {0, Acc1}, Notes),
          Acc2
      end, Acc, Hits).

%% One note of the card on channel Ch: down its legs if the dashboard has
%% routed the cards, else on its own channel of the IAC bus.
play(St, Ch, Note, DurMs, SlotMs, AtUs) ->
    route_note(maps:get(sock, St), maps:get(routing, St), Ch, Note, ?VELOCITY, DurMs, SlotMs, AtUs).

%% One note on channel Ch, down its legs or on its own channel of the IAC
%% bus; a loop on the rig (rig_loops) plays Vetula's notes through it too.
route_note(Sock, none, Ch, Note, Vel, DurMs, _SlotMs, AtUs) ->
    Thunk = 'tidal_mIDIBridge@foreign':scheduleNoteAt(Sock, ?PORT, Ch, Note, Vel, DurMs, AtUs),
    Thunk();
route_note(Sock, Routing, Ch, Note, Vel, DurMs, SlotMs, AtUs) ->
    Sends = 'reef_routing@ps':voiceRoutingSends(Routing, Ch - 1,
              #{note => Note, velocity => Vel, atMs => 0.0,
                durMs => float(DurMs), stepMs => float(SlotMs)}),
    lists:foreach(fun(S) -> routing_out:send(Sock, S, AtUs) end, array:to_list(Sends)).
