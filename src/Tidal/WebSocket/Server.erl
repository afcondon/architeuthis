-module(tidal_webSocket_server@foreign).
-export([ensureStarted/0]).

%% Start required OTP applications for cowboy
ensureStarted() ->
    fun() ->
        %% Start crypto (required by ssl)
        application:ensure_all_started(crypto),
        %% Start ranch (connection pool)
        application:ensure_all_started(ranch),
        %% Start cowlib (utilities)
        application:ensure_all_started(cowlib),
        %% Start cowboy (web server)
        application:ensure_all_started(cowboy),
        unit
    end.
