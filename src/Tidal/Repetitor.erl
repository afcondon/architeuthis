%% FFI for Tidal.Repetitor — only `floorN`.
%%
%% PureScript Number is Erlang float on the BEAM; floor maps to the
%% standard truncating-toward-negative-infinity floor.  Mirror of
%% Tidal.Grids's FFI module.
-module('tidal_repetitor@foreign').
-export([floorN/1]).

floorN(N) -> erlang:floor(N).
