-define(BUILD_TEST, <<"BUILD_MARKER_1767904118">>).
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

%% Parse message and extract tracks with their channels
%% JSON format: {"tracks":[{"pattern":"...","channel":10},...],"combined":"..."}
%% Returns {tracks, [{Pattern, Channel}, ...]} or {pattern, Pattern} for legacy
parse_message(Text) when is_binary(Text) ->
    case Text of
        <<"{", _/binary>> ->
            %% Looks like JSON - try to extract tracks array
            case extract_tracks(Text) of
                [] ->
                    %% No tracks found, fall back to combined pattern
                    Pattern = extract_json_field(Text, <<"\"combined\":\"">>, <<"~">>),
                    {pattern, Pattern};
                Tracks ->
                    {tracks, Tracks}
            end;
        _ ->
            %% Plain pattern string
            {pattern, Text}
    end.

%% Extract all tracks from JSON tracks array
%% Returns list of {Pattern, Channel} tuples
extract_tracks(Text) ->
    extract_tracks_loop(Text, []).

extract_tracks_loop(Text, Acc) ->
    %% Find next {"pattern":" occurrence
    case binary:match(Text, <<"{\"pattern\":\"">> ) of
        {Pos, _Len} ->
            %% Extract this track
            AfterBrace = binary:part(Text, Pos + 12, byte_size(Text) - Pos - 12),
            %% Find pattern value (until next quote)
            case binary:match(AfterBrace, <<"\"">> ) of
                {PatEnd, _} ->
                    Pattern = binary:part(AfterBrace, 0, PatEnd),
                    %% Find channel in this track object
                    AfterPattern = binary:part(AfterBrace, PatEnd, byte_size(AfterBrace) - PatEnd),
                    Channel = extract_channel_from_track(AfterPattern),
                    %% Continue searching for more tracks
                    Remaining = binary:part(Text, Pos + 12 + PatEnd, byte_size(Text) - Pos - 12 - PatEnd),
                    extract_tracks_loop(Remaining, [{Pattern, Channel} | Acc]);
                nomatch ->
                    lists:reverse(Acc)
            end;
        nomatch ->
            lists:reverse(Acc)
    end.

%% Extract channel value from within a track object
extract_channel_from_track(Text) ->
    case binary:match(Text, <<"\"channel\":">> ) of
        {Pos, Len} ->
            Start = Pos + Len,
            AfterKey = binary:part(Text, Start, byte_size(Text) - Start),
            extract_number(AfterKey, <<>>);
        nomatch ->
            10  % Default to channel 10
    end.

%% Extract a string field value from JSON (simple extraction)
extract_json_field(Text, FieldPattern, Default) ->
    case binary:match(Text, FieldPattern) of
        {Pos, Len} ->
            Start = Pos + Len,
            AfterKey = binary:part(Text, Start, byte_size(Text) - Start),
            case binary:match(AfterKey, <<"\"">> ) of
                {EndPos, _} ->
                    binary:part(AfterKey, 0, EndPos);
                nomatch ->
                    Default
            end;
        nomatch ->
            Default
    end.

%% Extract leading digits from binary and convert to integer
extract_number(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    extract_number(Rest, <<Acc/binary, C>>);
extract_number(_, <<>>) ->
    10;  % No digits found, default
extract_number(_, Acc) ->
    binary_to_integer(Acc).

%% Convert list of {Pattern, Channel} to list of maps for PureScript
tracks_to_ps_format(Tracks) ->
    [#{pattern => P, channel => C} || {P, C} <- Tracks].

%% Cowboy callbacks - delegate to PureScript
init(Req, Config) ->
    SchedulerPid = maps:get(schedulerPid, Config),
    State = #{schedulerPid => SchedulerPid, connected => true},
    io:format("WebSocket: New connection (handler v2 - channel support)~n"),
    {cowboy_websocket, Req, State}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Text}, State) ->
    io:format("WebSocket: Received message: ~s~n", [Text]),
    SchedulerPid = maps:get(schedulerPid, State),

    case parse_message(Text) of
        {tracks, Tracks} ->
            %% Multiple tracks with individual channels
            io:format("WebSocket: Parsed ~B tracks~n", [length(Tracks)]),
            lists:foreach(fun({P, C}) ->
                io:format("  - ch~B: ~s~n", [C, P])
            end, Tracks),

            %% Validate all patterns parse correctly
            AllValid = lists:all(fun({P, _C}) ->
                case 'tidal_parse_parser@ps':parse(P) of
                    {right, _} -> true;
                    {left, _} -> false
                end
            end, Tracks),

            case AllValid of
                true ->
                    %% Send tracks to scheduler as array of maps (PureScript Array = Erlang array module)
                    TracksList = tracks_to_ps_format(Tracks),
                    TracksArray = array:from_list(TracksList),
                    SchedulerPid ! {updateTracks, TracksArray},
                    Reply = {text, <<"OK: ", (integer_to_binary(length(Tracks)))/binary, " tracks">>},
                    {reply, Reply, State};
                false ->
                    io:format("WebSocket: Some tracks failed to parse~n"),
                    Reply = {text, <<"ERROR: Some tracks failed to parse">>},
                    {reply, Reply, State}
            end;

        {pattern, Pattern} ->
            %% Legacy: single pattern
            io:format("WebSocket: Extracted pattern: ~s~n", [Pattern]),
            case 'tidal_parse_parser@ps':parse(Pattern) of
                {right, _} ->
                    SchedulerPid ! {updatePattern, Pattern},
                    Reply = {text, <<"OK: ", Pattern/binary>>},
                    {reply, Reply, State};
                {left, Err} ->
                    io:format("WebSocket: Parse error: ~p~n", [Err]),
                    ErrBin = list_to_binary(io_lib:format("~p", [Err])),
                    Reply = {text, <<"ERROR: ", ErrBin/binary>>},
                    {reply, Reply, State}
            end
    end;
websocket_handle({binary, Bin}, State) ->
    %% Treat binary as text
    websocket_handle({text, Bin}, State);
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(Info, State) ->
    io:format("WebSocket: Info: ~p~n", [Info]),
    {ok, State}.
