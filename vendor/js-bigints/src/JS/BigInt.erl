%% purerl port of js-bigints 2.2.1 (purescript-contrib, MIT).
%%
%% The specification is upstream's BigInt.js, not its doc comments, where the
%% two disagree: `fromString "5e1"` is Nothing (JS's BigInt() rejects it) and
%% `fromNumber 1.5` is Nothing (BigInt(1.5) is a RangeError). `div` and `mod`
%% are Euclidean, as upstream's are: the remainder is never negative.
%%
%% Erlang integers are unbounded, so a BigInt is just an integer.
-module(jS_bigInt@foreign).
-export([fromStringImpl/3, fromStringAsImpl/4, fromInt/1, fromNumberImpl/3,
         toNumber/1, biAdd/2, biMul/2, biSub/2, biMod/2, biDiv/2, biDegree/1,
         biZero/0, biOne/0, pow/2, 'not'/1, 'or'/2, 'xor'/2, 'and'/2,
         shl/2, shr/2, biEquals/2, biCompare/2, toString/1, asIntN/2,
         asUintN/2, toStringAs/2]).

%% BigInt(s): surrounding whitespace allowed; "" is 0; a sign only on a
%% decimal; 0x / 0o / 0b prefixes in either case.
fromStringImpl(Just, Nothing, S) ->
    case parse(string:trim(binary_to_list(S))) of
        {ok, N} -> Just(N);
        error -> Nothing
    end.

parse("") -> {ok, 0};
parse([$0, P | Ds]) when P =:= $x; P =:= $X -> digits(Ds, 16);
parse([$0, P | Ds]) when P =:= $o; P =:= $O -> digits(Ds, 8);
parse([$0, P | Ds]) when P =:= $b; P =:= $B -> digits(Ds, 2);
parse([$- | Ds]) -> negate(digits(Ds, 10));
parse([$+ | Ds]) -> digits(Ds, 10);
parse(Ds) -> digits(Ds, 10).

negate({ok, N}) -> {ok, -N};
negate(error) -> error.

digits([], _) -> error;
digits(Ds, Radix) ->
    try list_to_integer(Ds, Radix) of
        N when N >= 0 -> {ok, N};
        _ -> error
    catch error:badarg -> error
    end.

%% Upstream's own parser: an optional leading '-', then digits in the radix.
fromStringAsImpl(Just, Nothing, Radix, S) ->
    L = binary_to_list(S),
    {Sign, Ds} = case L of
        [$- | Rest] -> {-1, Rest};
        _ -> {1, L}
    end,
    case digits(Ds, Radix) of
        {ok, N} -> Just(Sign * N);
        error -> Nothing
    end.

fromInt(N) -> N.

%% BigInt(n) accepts only integral, finite numbers.
fromNumberImpl(Just, _Nothing, N) when is_integer(N) -> Just(N);
fromNumberImpl(Just, Nothing, N) when is_float(N) ->
    T = trunc(N),
    case T == N of
        true -> Just(T);
        false -> Nothing
    end.

toNumber(N) -> float(N).

biAdd(X, Y) -> X + Y.
biMul(X, Y) -> X * Y.
biSub(X, Y) -> X - Y.

biMod(_, 0) -> 0;
biMod(X, Y) ->
    YY = abs(Y),
    ((X rem YY) + YY) rem YY.

biDiv(_, 0) -> 0;
biDiv(X, Y) -> (X - biMod(X, Y)) div Y.

biDegree(X) -> abs(X).

biZero() -> 0.
biOne() -> 1.

pow(X, Y) when Y >= 0 -> ipow(X, Y, 1);
pow(_, _) -> 0.

ipow(_, 0, Acc) -> Acc;
ipow(X, Y, Acc) when Y band 1 =:= 1 -> ipow(X * X, Y bsr 1, Acc * X);
ipow(X, Y, Acc) -> ipow(X * X, Y bsr 1, Acc).

'not'(X) -> bnot X.
'or'(X, Y) -> X bor Y.
'xor'(X, Y) -> X bxor Y.
'and'(X, Y) -> X band Y.

%% JS's << and >> on BigInt; a negative count shifts the other way, as
%% Erlang's bsl and bsr do. bsr is arithmetic, as >> is.
shl(X, N) -> X bsl N.
shr(X, N) -> X bsr N.

biEquals(X, Y) -> X =:= Y.

biCompare(X, Y) when X =:= Y -> 0;
biCompare(X, Y) when X > Y -> 1;
biCompare(_, _) -> -1.

toString(X) -> integer_to_binary(X).

%% BigInt.asIntN: the low Bits bits, read as two's complement.
asIntN(0, _) -> 0;
asIntN(Bits, N) ->
    M = N band ((1 bsl Bits) - 1),
    case M >= (1 bsl (Bits - 1)) of
        true -> M - (1 bsl Bits);
        false -> M
    end.

asUintN(Bits, N) -> N band ((1 bsl Bits) - 1).

%% JS writes the letters of radix > 10 in lower case.
toStringAs(Radix, X) -> string:lowercase(integer_to_binary(X, Radix)).
