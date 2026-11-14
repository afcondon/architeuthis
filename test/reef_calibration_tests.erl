%%%-------------------------------------------------------------------
%%% @doc The V/oct realiser, as this node runs it, held to one answer.
%%%
%%% Replays reef/conformance/vectors/calibration.json against
%%% `Reef.Calibration.realise` compiled to the BEAM: a table and a pitch in,
%%% volts out, to the file's tolerance (a nanovolt). The same file is
%%% replayed by Reef on JavaScript's side (it is generated there), by a
%%% Python realiser written apart, and by DeepStar's.
%%%
%%% Run: make test-erl (after `make erl`)
%%% @end
%%%-------------------------------------------------------------------
-module(reef_calibration_tests).

-include_lib("eunit/include/eunit.hrl").

vectors() ->
    Dir = case os:getenv("REEF_DIR") of
              false -> "../../reef";
              Given -> Given
          end,
    {ok, Text} = file:read_file(filename:join(Dir, "conformance/vectors/calibration.json")),
    Json = json:decode(Text),
    %% The one vector format this replayer understands.
    1 = maps:get(<<"calibration-vectors">>, Json),
    Json.

%% A table as PureScript holds it here: a record is a map with atom keys, and
%% an Array is an `array`.
table(Label, Points) ->
    #{label => Label,
      points => array:from_list([ #{volts => float(maps:get(<<"volts">>, P)), hz => float(maps:get(<<"hz">>, P))}
                                  || P <- Points ])}.

realise_test_() ->
    Json = vectors(),
    Cases = maps:get(<<"cases">>, Json),
    %% An empty list would pass every test while testing nothing.
    true = length(Cases) > 0,
    Tolerance = maps:get(<<"toleranceVolts">>, Json),
    Tables = maps:get(<<"tables">>, Json),
    [ begin
          Name = maps:get(<<"name">>, Case),
          Label = maps:get(<<"table">>, Case),
          Got = reef_calibration@ps:realise(table(Label, maps:get(Label, Tables)), float(maps:get(<<"hz">>, Case))),
          Want = float(maps:get(<<"volts">>, Case)),
          {binary_to_list(Name), ?_assert(abs(Got - Want) =< Tolerance)}
      end || Case <- Cases ].
