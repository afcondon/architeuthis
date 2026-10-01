-module(tidal_pattern_random@foreign).
-export([timeToRandImpl/2]).

-define(SEED_RANGE, 536870912).  % 2^29

%% timeToRand for the time N/D (D > 0), as Haskell Tidal computes it:
%%   timeToIntSeed = xorwise . truncate . (* 2^29) . snd . properFraction . (/ 300)
%%   intSeedToRand = (/ 2^29) . (`mod` 2^29)
timeToRandImpl(0, _) -> 0.5;
timeToRandImpl(N, D) ->
    D300 = 300 * D,
    FracN = N - (N div D300) * D300,          % properFraction keeps the sign
    Seed = xorwise((FracN * ?SEED_RANGE) div D300),  % truncate towards zero
    Mod = ((Seed rem ?SEED_RANGE) + ?SEED_RANGE) rem ?SEED_RANGE,
    Mod / ?SEED_RANGE.

%% Haskell's Int is 64-bit and wraps; Erlang's integers do not.
xorwise(X) ->
    A = wrap(wrap(X bsl 13) bxor X),
    B = wrap((A bsr 17) bxor A),
    wrap(wrap(B bsl 5) bxor B).

wrap(X) ->
    Y = X band 16#FFFFFFFFFFFFFFFF,
    case Y >= 16#8000000000000000 of
        true -> Y - 16#10000000000000000;
        false -> Y
    end.
