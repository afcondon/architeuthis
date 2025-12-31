-module(tidal_webSocket_handler@foreign).
-export([binaryToString/1]).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

%% Convert binary to string (UTF-8)
binaryToString(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(Bin, utf8);
binaryToString(Other) ->
    %% Already a string or other type
    Other.

%% Cowboy callbacks - delegate to PureScript
init(Req, Config) ->
    SchedulerPid = maps:get(schedulerPid, Config),
    State = #{schedulerPid => SchedulerPid, connected => true},
    io:format("WebSocket: New connection~n"),
    {cowboy_websocket, Req, State}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Text}, State) ->
    io:format("WebSocket: Received pattern: ~s~n", [Text]),
    SchedulerPid = maps:get(schedulerPid, State),
    %% Try to parse the pattern
    case 'tidal_parse_parser@ps':parse(Text) of
        {right, _} ->
            %% Valid pattern - send to scheduler
            SchedulerPid ! {updatePattern, Text},
            Reply = {text, <<"OK: ", Text/binary>>},
            {reply, Reply, State};
        {left, Err} ->
            io:format("WebSocket: Parse error: ~p~n", [Err]),
            ErrBin = list_to_binary(io_lib:format("~p", [Err])),
            Reply = {text, <<"ERROR: ", ErrBin/binary>>},
            {reply, Reply, State}
    end;
websocket_handle({binary, Bin}, State) ->
    %% Treat binary as text
    websocket_handle({text, Bin}, State);
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(Info, State) ->
    io:format("WebSocket: Info: ~p~n", [Info]),
    {ok, State}.
