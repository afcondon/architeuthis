%%%-------------------------------------------------------------------
%%% @doc Replays the /link/anchor conformance vectors against
%%% tidal_link_anchor.
%%%
%%% The declaration is binnacle/conformance/LINK-ANCHOR.md and the vector
%%% file beside it is generated from the PureScript reference. Every
%%% program on the rig that reads or writes an anchor replays the same
%%% file, which is what keeps them from drifting apart again: before
%%% 2026-11-10 there were seven hand-written copies and four different
%%% validity rules.
%%%
%%% Sections replayed: `osc`, `beatAt`, `fresh`. The `text` section is for
%%% READERS of the text frame; this module WRITES it, so what is held here
%%% instead is that every accepted anchor is written as a line the
%%% declared grammar admits and that reads back to the same values.
%%%
%%% The vector file is found in $BINNACLE_DIR, or in the sibling checkout.
%%% Not finding it is a failure, not a skip.
%%%
%%% Run: make test-erl
%%% @end
%%%-------------------------------------------------------------------
-module(tidal_link_anchor_tests).

-include_lib("eunit/include/eunit.hrl").

vectors() ->
    Dir = case os:getenv("BINNACLE_DIR") of
              false -> "../binnacle";
              Given -> Given
          end,
    Path = filename:join(Dir, "conformance/vectors/link-anchor.json"),
    {ok, Text} = file:read_file(Path),
    Json = json:decode(Text),
    %% The one vector format this replayer understands.
    1 = maps:get(<<"link-anchor-vectors">>, Json),
    Json.

section(Name) ->
    Cases = maps:get(Name, vectors()),
    %% An empty section would pass every test while testing nothing.
    true = length(Cases) > 0,
    Cases.

constant(Name) ->
    maps:get(Name, maps:get(<<"constants">>, vectors())).

held(Anchor) ->
    {maps:get(<<"unixMicros">>, Anchor),
     maps:get(<<"beat">>, Anchor),
     maps:get(<<"tempo">>, Anchor),
     maps:get(<<"quantum">>, Anchor)}.

verdict({ok, _}) -> <<"accept">>;
verdict(refuse)  -> <<"refuse">>;
verdict(other)   -> <<"other">>.

osc_cases_decode_to_their_declared_verdict_test_() ->
    [{binary_to_list(maps:get(<<"name">>, Case)),
      fun() ->
              Packet = binary:decode_hex(maps:get(<<"hex">>, Case)),
              Got = tidal_link_anchor:decode(Packet),
              ?assertEqual(maps:get(<<"expect">>, Case), verdict(Got)),
              case Got of
                  {ok, {UnixUs, Beat, Tempo, Quantum}} ->
                      {WantUs, WantBeat, WantTempo, WantQuantum} =
                          held(maps:get(<<"anchor">>, Case)),
                      %% `==`, not `=:=`: the file writes 120 where the
                      %% wire carries 120.0.
                      ?assert(UnixUs == WantUs),
                      ?assert(Beat == WantBeat),
                      ?assert(Tempo == WantTempo),
                      ?assert(Quantum == WantQuantum);
                  _ ->
                      ok
              end
      end}
     || Case <- section(<<"osc">>)].

beat_at_cases_agree_within_tolerance_test_() ->
    Tolerance = constant(<<"beatTolerance">>),
    [{binary_to_list(maps:get(<<"name">>, Case)),
      fun() ->
              Got = tidal_link_anchor:beat_from(
                      held(maps:get(<<"anchor">>, Case)),
                      maps:get(<<"atUnixMicros">>, Case)),
              ?assert(abs(Got - maps:get(<<"beat">>, Case)) =< Tolerance)
      end}
     || Case <- section(<<"beatAt">>)].

fresh_cases_agree_test_() ->
    [?_assertEqual(maps:get(<<"fresh">>, Case),
                   tidal_link_anchor:is_fresh(maps:get(<<"ageMicros">>, Case)))
     || Case <- section(<<"fresh">>)].

%% The text frame as this module writes it, for every anchor the vectors
%% accept: `anchor`, then digits, then three plain decimals, single spaces
%% between; and the values a reader gets back are the ones written, to the
%% six decimals `~f` keeps.
accepted_anchors_are_written_as_a_line_the_grammar_admits_test_() ->
    Whole = "^[0-9]+$",
    Real = "^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$",
    [{binary_to_list(maps:get(<<"name">>, Case)),
      fun() ->
              {ok, {UnixUs, Beat, Tempo, Quantum}} =
                  tidal_link_anchor:decode(
                    binary:decode_hex(maps:get(<<"hex">>, Case))),
              Line = tidal_link_anchor:format_anchor(UnixUs, Beat, Tempo, Quantum),
              [<<"anchor">>, Us, B, T, Q] = binary:split(Line, <<" ">>, [global]),
              ?assertMatch({match, _}, re:run(Us, Whole)),
              [?assertMatch({match, _}, re:run(Word, Real)) || Word <- [B, T, Q]],
              ?assertEqual(UnixUs, binary_to_integer(Us)),
              [?assert(abs(binary_to_float(Word) - Value) =< 1.0e-6)
               || {Word, Value} <- [{B, Beat}, {T, Tempo}, {Q, Quantum}]]
      end}
     || Case <- section(<<"osc">>),
        maps:get(<<"expect">>, Case) =:= <<"accept">>].

%% Diaphus's peer count (`/link/peers ,i n`, diaphus src/main.rs item 8):
%% read as its own message, never as an anchor, and passed to the pages as
%% `link <peers> <refused>`.
peers_test_() ->
    Peers = fun(N) -> <<"/link/peers", 0, ",i", 0, 0, N:32/big-signed>> end,
    [?_assertEqual({ok, 0}, tidal_link_anchor:decode_peers(Peers(0))),
     ?_assertEqual({ok, 3}, tidal_link_anchor:decode_peers(Peers(3))),
     ?_assertEqual(other, tidal_link_anchor:decode_peers(Peers(-1))),
     ?_assertEqual(other, tidal_link_anchor:decode(Peers(3))),
     ?_assertEqual(other, tidal_link_anchor:decode_peers(<<"/link/peers", 0, ",f", 0, 0, 0:32>>)),
     ?_assertEqual(<<"link 2 architeuthis=0 es9-daemon=- continuo=3">>,
                   tidal_link_anchor:format_link(2, [{architeuthis, 0}, {'es9-daemon', unknown}, {continuo, 3}])),
     ?_assertEqual(0, tidal_link_anchor:es9_refused({ok, <<"OK locked snaps 14 latency-ms 0.00 origin 0 refused 0\n">>})),
     ?_assertEqual(unknown, tidal_link_anchor:es9_refused({error, enoent})),
     ?_assertEqual(2, tidal_link_anchor:continuo_refused({ok, <<"{\"anchors\": 9, \"anchorsRefused\": 2, \"x\": 1}">>}))].
