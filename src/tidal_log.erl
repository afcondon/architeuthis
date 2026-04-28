%% Tiny log-level gate for the purerl-tidal backend.
%%
%% Levels:
%%   0 = quiet (errors only — call err/2 for those, currently unused)
%%   1 = info (default; startup, parse, connection, state changes)
%%   2 = debug (per-event spam: every MIDI send, every WS message)
%%
%% Updated at runtime via the `log-level <N>` Tidal verb (see
%% WebSocket/Handler.erl). Level lives in persistent_term so reads are
%% lock-free and cheap on the hot path.
-module(tidal_log).
-export([level/0, set_level/1, info/2, debug/2, err/2]).

-define(KEY, tidal_log_level).
-define(DEFAULT_LEVEL, 1).

level() ->
    try persistent_term:get(?KEY)
    catch error:badarg -> ?DEFAULT_LEVEL
    end.

set_level(N) when is_integer(N), N >= 0, N =< 2 ->
    persistent_term:put(?KEY, N).

info(Format, Args) ->
    case level() >= 1 of
        true -> io:format(Format, Args);
        false -> ok
    end.

debug(Format, Args) ->
    case level() >= 2 of
        true -> io:format(Format, Args);
        false -> ok
    end.

err(Format, Args) ->
    %% errors always print
    io:format(Format, Args).
