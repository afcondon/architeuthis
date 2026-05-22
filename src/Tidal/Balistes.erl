%% FFI for Tidal.Balistes — only `floorN`.
%%
%% PureScript Number is Erlang float on the BEAM; floor maps to the
%% standard truncating-toward-negative-infinity floor.  erlang:floor/1
%% is an Erlang BIF that returns an integer for both float and
%% integer inputs.
-module('tidal_balistes@foreign').
-export([floorN/1]).

floorN(N) -> erlang:floor(N).
