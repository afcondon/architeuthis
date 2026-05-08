%% FFI shim for Tidal.Application.purs.
%%
%% Wraps application:ensure_started/1 in the Effect Unit shape the rest
%% of the FFI uses (zero-arg fun returning unit on success, raises on
%% failure). Started failures are loud — we crash the caller rather
%% than silently log + continue, since a missing supervision tree at
%% boot is unrecoverable.
-module(tidal_application@foreign).

-export([startApplication/0]).

startApplication() ->
    fun() ->
        %% ensure_all_started starts the dependency chain (kernel,
        %% stdlib, ranch, cowboy) too, not just the named application.
        %% Idempotent — already-running apps are no-ops.
        case application:ensure_all_started(purerl_tidal) of
            {ok, Started} ->
                io:format("started OTP application purerl_tidal "
                          "(deps started: ~p)~n", [Started]),
                unit;
            {error, Reason} ->
                io:format("FAILED to start purerl_tidal: ~p~n", [Reason]),
                error({application_start_failed, Reason})
        end
    end.
