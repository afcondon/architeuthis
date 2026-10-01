-module(haskell_double@foreign).
-export([sin/1, cos/1, sqrt/1, pi/0, floorImpl/1]).

sin(X) -> math:sin(X).
cos(X) -> math:cos(X).
sqrt(X) -> math:sqrt(X).
pi() -> math:pi().
%% Erlang's floor/1 returns an integer, exactly.
floorImpl(X) -> erlang:floor(X).
