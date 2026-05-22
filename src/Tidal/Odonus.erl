%% FFI for Tidal.Odonus — only `floorN`, mirror of Tidal.Repetitor / Tidal.Balistes.
-module('tidal_odonus@foreign').
-export([floorN/1]).

floorN(N) -> erlang:floor(N).
