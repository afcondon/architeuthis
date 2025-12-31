-module(tidal_scheduler@foreign).
-export([sendAfterImpl/3]).

%% Send a message to a process after a delay (in milliseconds)
%% Uses erlang:send_after for precise timing
sendAfterImpl(Ms, Pid, Msg) ->
    fun() ->
        erlang:send_after(Ms, Pid, Msg),
        unit
    end.
