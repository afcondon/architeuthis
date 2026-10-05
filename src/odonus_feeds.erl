%% @doc What feeds Odonus's two harmony inputs, kept true on the rig
%% (docs/kb/plans/matrix-router.md, slice 4).
%%
%% The harmony routes (`routing/harmony`, Reef.Route) say where each input
%% takes its notes from. A scale or a harmony pattern is all there in the
%% route; Vetula's two sources are not: `vetula key` needs Vetula's key (the
%% stage object `vetula/key`, written by the Vetula page) and `vetula N` the
%% chords of the card on channel N (`vetula/vK`, read with Tidal by
%% `Tidal.Vetula.Card.cardHarmony`). So this process subscribes to the
%% stage, holds the routes, the cards and the key, and whenever any of them
%% changes resolves what each input is fed (`Reef.Route.resolve`) and sends
%% the running Odonus voice the inputs that take it there
%% (`Reef.Route.feedInputs`), as one move, so the page follows in lockstep.
%% Editing a card under a route re-feeds Odonus as changing the route does.
%%
%% A card turning to `→ odo` routes `odonus.out <- vetula N` to its channel
%% (turning away clears that route if it still names the card). The other
%% way round went 2026-10-05 (docs/kb/plans/harmony-routes-coherent.md): a
%% route never rewrites a card, since a voice that sounds may also shape
%% Odonus (AC), and turning it to `→ odo` took it off MIDI.
%%
%% What it resolves it also publishes, as the stage object `odonus/feeds`
%% (Reef.Route.printFeeds), for a page that plays Odonus itself (Solo) and
%% has no rig voice to follow: the page applies the same `feedInputs`, and
%% never needs Tidal to read a card.
%%
%% Supervised after the stage, so a stage restart restarts this too and the
%% subscription is never lost.
-module(odonus_feeds).
-behaviour(gen_server).

-export([start_link/0, to_voice/1, feeds/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(ROUTES, <<"routing/harmony">>).
-define(KEY, <<"vetula/key">>).
-define(FEEDS, <<"odonus/feeds">>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A starting Odonus voice takes everything that feeds it now.
to_voice(Pid) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:cast(?MODULE, {to_voice, Pid})
    end.

%% What each input is fed, for inspection from a shell.
feeds() -> gen_server:call(?MODULE, feeds).

init([]) ->
    Table = tidal_stage:text_subscribe(self()),
    St0 = #{routes => array:new(), cards => #{}, key => {nothing}, applied => unfed(),
            published => none},
    St = maps:fold(fun(K, #{text := T}, Acc) -> take(K, T, Acc) end, St0, Table),
    %% a voice already running (this process restarted under it) is fed afresh
    {ok, feed(St)}.

handle_call(feeds, _From, St) ->
    {reply, current(St), St};
handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({to_voice, Pid}, St) ->
    Feeds = current(St),
    send(Pid, 'reef_route@ps':feedInputs(unfed(), Feeds)),
    {noreply, St#{applied => Feeds}};
handle_cast(_Message, St) ->
    {noreply, St}.

handle_info({stage_broadcast, <<"stage-text ", Json/binary>>}, St) ->
    case catch json:decode(Json) of
        #{<<"key">> := K, <<"text">> := T} ->
            St1 = take(K, T, St),
            St2 = shortcut(K, maps:get(cards, St), St1),
            {noreply, feed(St2)};
        _ ->
            {noreply, St}
    end;
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%% One stage object, written (or with null, deleted).
take(?ROUTES, T, St) ->
    Routes = case T of
        null -> array:new();
        _ -> case 'reef_route@ps':parse(T) of
                 {right, R} -> R;
                 _ -> maps:get(routes, St)   % the rig refuses a bad table before keeping it
             end
    end,
    St#{routes => Routes};
take(?KEY, T, St) ->
    Key = case T of
        null -> {nothing};
        _ -> case 'reef_route@ps':parseKey(T) of
                 {right, K} -> {just, K};
                 _ -> {nothing}
             end
    end,
    St#{key => Key};
take(<<"vetula/v", N/binary>> = K, T, St) ->
    Cards = maps:get(cards, St),
    Cards1 = case {string:to_integer(N), T} of
        {{_, <<>>}, null} -> maps:remove(K, Cards);
        {{_, <<>>}, _} ->
            case 'reef_vetula_lepidoptera@ps':parseCard(T) of
                {just, Spec} -> Cards#{K => Spec};
                _ -> maps:remove(K, Cards)
            end;
        _ -> Cards
    end,
    St#{cards => Cards1};
take(_, _, St) ->
    St.

%% `# out odo`: a card turning to `→ odo` routes odonus.out to it; turning
%% away (or going) clears the route if it names the card's channel. The
%% write comes back as a stage broadcast, which feeds Odonus.
shortcut(<<"vetula/v", _/binary>> = K, OldCards, St) ->
    Was = odo_channel(maps:get(K, OldCards, none)),
    Now = odo_channel(maps:get(K, maps:get(cards, St), none)),
    Routes = maps:get(routes, St),
    Out = 'reef_route@ps':sourceOf({odonusOut}, Routes),
    New = case {Was, Now} of
        {Same, Same} -> Routes;
        {_, {ch, Ch}} when Out =/= {just, {vetulaVoice, Ch}} ->
            'reef_route@ps':setRoute({odonusOut}, {vetulaVoice, Ch}, Routes);
        {{ch, Ch}, _} when Out =:= {just, {vetulaVoice, Ch}} ->
            array:from_list([R || R = #{input := I} <- array:to_list(Routes), I =/= {odonusOut}]);
        _ -> Routes
    end,
    case New =:= Routes of
        true -> St;
        false ->
            Text = case array:size(New) of
                       0 -> null;
                       _ -> 'reef_route@ps':print(New)
                   end,
            tidal_stage:put_text(?ROUTES, Text, rig),
            St#{routes => New}
    end;
shortcut(_, _, St) ->
    St.

odo_channel(#{term := {tOdo}, channel := Ch}) -> {ch, Ch};
odo_channel(_) -> none.

%% Send the running voice what moves it from the feeds it last took, and
%% publish them if they changed.
feed(St) ->
    Feeds = current(St),
    St1 = publish(Feeds, St),
    case whereis(reef_voice) of
        undefined ->
            %% nothing to feed; a voice that starts takes the lot (to_voice)
            St1#{applied => unfed()};
        Pid ->
            send(Pid, 'reef_route@ps':feedInputs(maps:get(applied, St1), Feeds)),
            St1#{applied => Feeds}
    end.

publish(Feeds, St) ->
    case maps:get(published, St) of
        Feeds -> St;
        _ ->
            Text = case 'reef_route@ps':printFeeds(Feeds) of
                       <<>> -> null;
                       T -> T
                   end,
            tidal_stage:put_text(?FEEDS, Text, rig),
            St#{published => Feeds}
    end.

send(Pid, Inputs) ->
    case array:size(Inputs) of
        0 -> ok;
        _ -> Pid ! {move, {gestures, Inputs}}, ok
    end.

current(St) ->
    'reef_route@ps':resolve(context(St), maps:get(routes, St)).

unfed() ->
    'reef_route@ps':resolve('reef_route@ps':noContext(), array:new()).

%% Vetula as reef sees it: the key, and each card's harmony by channel, the
%% lowest-numbered card first where two share one.
context(St) ->
    Cards = lists:sort(fun({A, _}, {B, _}) -> card_no(A) =< card_no(B) end,
                       maps:to_list(maps:get(cards, St))),
    Voices = lists:filtermap(
               fun({_, Spec}) ->
                       case 'tidal_vetula_card@ps':cardHarmony(Spec) of
                           {just, H} -> {true, #{channel => maps:get(channel, Spec), harmony => H}};
                           _ -> false
                       end
               end, Cards),
    #{key => maps:get(key, St), voices => array:from_list(Voices)}.

card_no(<<"vetula/v", N/binary>>) ->
    case string:to_integer(N) of
        {I, <<>>} -> I;
        _ -> 0
    end.
