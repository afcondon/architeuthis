%%%-------------------------------------------------------------------
%%% @doc Architeuthis as a WRITER, held to what Diaphus and es9-daemon read.
%%%
%%% Replays the `packets` of binnacle's two vector files through rig_wire:
%%% the declared values go in, and the bytes that come out must be the
%%% vector's, exactly. Then a few values that break a declared rule, which
%%% rig_wire must decline to encode.
%%%
%%% rig_wire is the only place Architeuthis lays out a packet for either
%%% daemon, so this holds every sender in the node (MIDIBridge, Tidal.OSC,
%%% es9_cv, the WebSocket relay). It does not exercise their sockets.
%%%
%%% Run: make test-erl
%%% @end
%%%-------------------------------------------------------------------
-module(rig_wire_tests).

-include_lib("eunit/include/eunit.hrl").

vectors(File, VersionKey) ->
    Dir = case os:getenv("BINNACLE_DIR") of
              false -> "../binnacle";
              Given -> Given
          end,
    {ok, Text} = file:read_file(filename:join([Dir, "conformance/vectors", File])),
    Json = json:decode(Text),
    %% The one vector format this replayer understands.
    1 = maps:get(VersionKey, Json),
    Json.

packets(File, VersionKey) ->
    Cases = maps:get(<<"packets">>, vectors(File, VersionKey)),
    %% An empty section would pass every test while testing nothing.
    true = length(Cases) > 0,
    Cases.

%% The message a declared address is, as rig_wire sends it. `not_sent` for
%% the addresses Architeuthis never writes.
write(<<"/midi/note/at">>, [P, C, N, V, D, T]) -> rig_wire:note_at(P, C, N, V, D, T);
write(<<"/midi/on/at">>, [P, C, N, V, T]) -> rig_wire:on_at(P, C, N, V, T);
write(<<"/midi/off/at">>, [P, C, N, T]) -> rig_wire:off_at(P, C, N, T);
write(<<"/midi/cc/at">>, [P, C, K, V, T]) -> rig_wire:cc_at(P, C, K, V, T);
write(<<"/link/set-tempo">>, [Bpm]) -> rig_wire:set_tempo(Bpm);
write(<<"/link/play">>, _) -> not_sent;
write(<<"/clock/restart">>, _) -> not_sent;
write(<<"/cv">>, [B, V]) -> rig_wire:cv(B, V);
write(<<"/cv/slew">>, [B, V, L]) -> rig_wire:cv_slew(B, V, L);
write(<<"/cv/trig">>, [B, V, D]) -> rig_wire:cv_trig(B, V, D);
write(<<"/cv/trig/at">>, [B, V, D, W]) -> rig_wire:cv_trig_at(B, V, D, W);
write(<<"/esx">>, [S, V]) -> rig_wire:esx(S, V);
write(<<"/esx/enable">>, _) -> not_sent;
write(<<"/esx5gate">>, [B, S]) -> rig_wire:esx5_gate(B, S);
write(<<"/tidal/gate">>, [C, S]) -> rig_wire:gate(C, S);
write(<<"/tidal/gate/trig">>, [C, D]) -> rig_wire:gate_trig(C, D);
write(<<"/tidal/cv">>, [C, V]) -> rig_wire:tidal_cv(C, V);
write(<<"/tidal/cv/slew">>, [C, V, L]) -> rig_wire:tidal_cv_slew(C, V, L).

replay(File, VersionKey) ->
    Results = [ {maps:get(<<"name">>, Case),
                 write(maps:get(<<"address">>, Case), maps:get(<<"values">>, Case)),
                 binary:decode_hex(maps:get(<<"hex">>, Case))}
                || Case <- packets(File, VersionKey) ],
    Written = [ R || {_, Outcome, _} = R <- Results, Outcome =/= not_sent ],
    %% Most of each file is ours to write; if little is, the table above is wrong.
    true = length(Written) * 2 > length(Results),
    [ ?_assertEqual({Name, {ok, Expected}}, {Name, Outcome}) || {Name, Outcome, Expected} <- Written ].

to_diaphus_test_() ->
    replay("diaphus-inbound.json", <<"diaphus-inbound-vectors">>).

to_es9_test_() ->
    replay("es9-osc.json", <<"es9-osc-vectors">>).

%% What the daemons tolerate from the old encoders and the declarations do
%% not allow: rig_wire sends the declared form whatever Erlang type it is
%% handed.
whole_number_level_is_still_a_binary32_test() ->
    ?assertEqual(rig_wire:cv(8, 1.0), rig_wire:cv(8, 1)),
    {ok, <<"/cv", 0, ",if", 0, 8:32, 1.0:32/float>>} = rig_wire:cv(8, 1).

tempo_is_a_binary64_test() ->
    {ok, <<"/link/set-tempo", 0, ",d", 0, 0, 120.0:64/float>>} = rig_wire:set_tempo(120).

declined_test_() ->
    Then = 1794326400000000,
    Before = rig_wire:refused(),
    Declined =
        [ {<<"channel-out-of-range">>, rig_wire:note_at(<<"IAC Driver Tidal">>, 0, 60, 100, 250, Then)}
        , {<<"channel-out-of-range">>, rig_wire:cc_at(<<"IAC Driver Tidal">>, 17, 7, 100, Then)}
        , {<<"not-seven-bit">>, rig_wire:note_at(<<"IAC Driver Tidal">>, 1, 128, 100, 250, Then)}
        , {<<"negative-duration">>, rig_wire:note_at(<<"IAC Driver Tidal">>, 1, 60, 100, -1, Then)}
        , {<<"bus-out-of-range">>, rig_wire:cv(16, 0.5)}
        , {<<"negative-time">>, rig_wire:cv_trig_at(8, 0.5, 10.0, -1.0)}
        , {<<"tempo-out-of-range">>, rig_wire:set_tempo(19.0)}
        ],
    [ ?_assertEqual({refused, Tag}, Outcome) || {Tag, Outcome} <- Declined ]
        ++ [ ?_assertEqual(Before + length(Declined), rig_wire:refused()) ].
