%% FFI for Tidal.Rene — only `floorN`, mirror of Tidal.Repetitor / Tidal.Grids.
-module('tidal_rene@foreign').
-export([floorN/1]).

floorN(N) -> erlang:floor(N).
