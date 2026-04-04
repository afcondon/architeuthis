-define(BUILD_TEST, <<"BUILD_MARKER_1767904118">>).
-module(tidal_webSocket_handler@foreign).
-export([binaryToString/1]).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

%% Sets directory relative to working directory
-define(SETS_DIR, "sets").

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

    %% First check for set management actions
    case extract_action(Text) of
        <<"list_sets">> ->
            handle_list_sets(State);
        <<"save_set">> ->
            handle_save_set(Text, State);
        <<"load_set">> ->
            handle_load_set(Text, SchedulerPid, State);
        <<"delete_set">> ->
            handle_delete_set(Text, State);
        _ ->
            %% Not a set action, handle as pattern message
            handle_pattern_message(Text, SchedulerPid, State)
    end;
websocket_handle({binary, Bin}, State) ->
    %% Treat binary as text
    websocket_handle({text, Bin}, State);
websocket_handle(_Frame, State) ->
    {ok, State}.

%% Handle pattern messages (existing logic, refactored into function)
handle_pattern_message(Text, SchedulerPid, State) ->
    case parse_message(Text) of
        {tracks, Tracks} ->
            %% Multiple tracks with individual channels
            io:format("WebSocket: Parsed ~B tracks~n", [length(Tracks)]),
            lists:foreach(fun({P, C}) ->
                io:format("  - ch~B: ~s~n", [C, P])
            end, Tracks),

            %% Validate all patterns parse correctly
            AllValid = lists:all(fun({P, _C}) ->
                case ('tidal_parse_parser@ps':parse())(P) of
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
            case ('tidal_parse_parser@ps':parse())(Pattern) of
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
    end.

websocket_info(Info, State) ->
    io:format("WebSocket: Info: ~p~n", [Info]),
    {ok, State}.

%% ============================================================================
%% Set Management Functions
%% ============================================================================

%% Extract "action" field from JSON message
extract_action(Text) when is_binary(Text) ->
    extract_json_field(Text, <<"\"action\":\"">>, <<>>).

%% Extract "name" field from JSON message
extract_set_name(Text) when is_binary(Text) ->
    extract_json_field(Text, <<"\"name\":\"">>, <<>>).

%% Sanitize set name to prevent path traversal attacks
%% Only allows alphanumeric, dash, underscore
sanitize_name(Name) when is_binary(Name) ->
    sanitize_name_loop(Name, <<>>).

sanitize_name_loop(<<>>, Acc) -> Acc;
sanitize_name_loop(<<C, Rest/binary>>, Acc) when
        (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $- orelse C =:= $_ ->
    sanitize_name_loop(Rest, <<Acc/binary, C>>);
sanitize_name_loop(<<_, Rest/binary>>, Acc) ->
    sanitize_name_loop(Rest, Acc).

%% Ensure sets directory exists
ensure_sets_dir() ->
    case filelib:is_dir(?SETS_DIR) of
        true -> ok;
        false ->
            io:format("Creating sets directory: ~s~n", [?SETS_DIR]),
            file:make_dir(?SETS_DIR)
    end.

%% Get full path for a set file
set_file_path(Name) ->
    filename:join(?SETS_DIR, <<Name/binary, ".json">>).

%% ============================================================================
%% List Sets Handler
%% ============================================================================

handle_list_sets(State) ->
    io:format("WebSocket: Listing sets~n"),
    ensure_sets_dir(),
    Pattern = filename:join(?SETS_DIR, "*.json"),
    Files = filelib:wildcard(binary_to_list(iolist_to_binary(Pattern))),
    SetNames = [extract_set_name_from_path(F) || F <- Files],
    Response = encode_sets_list(SetNames),
    io:format("WebSocket: Found ~B sets: ~p~n", [length(SetNames), SetNames]),
    {reply, {text, Response}, State}.

%% Extract set name from file path (remove directory and .json extension)
extract_set_name_from_path(Path) ->
    Basename = filename:basename(Path, ".json"),
    list_to_binary(Basename).

%% Encode sets_list response
encode_sets_list(SetNames) ->
    SetsJson = encode_string_array(SetNames),
    <<"{\"action\":\"sets_list\",\"sets\":", SetsJson/binary, "}">>.

%% ============================================================================
%% Save Set Handler
%% ============================================================================

handle_save_set(Text, State) ->
    Name = extract_set_name(Text),
    case sanitize_name(Name) of
        <<>> ->
            io:format("WebSocket: Invalid set name~n"),
            Response = encode_error(<<"Invalid or empty set name">>),
            {reply, {text, Response}, State};
        SafeName ->
            io:format("WebSocket: Saving set '~s'~n", [SafeName]),
            ensure_sets_dir(),
            FilePath = set_file_path(SafeName),
            %% Extract the full set data (name + tracks) from the original message
            SetData = extract_set_data_for_save(Text, SafeName),
            case file:write_file(FilePath, SetData) of
                ok ->
                    io:format("WebSocket: Saved set to ~s~n", [FilePath]),
                    Response = <<"{\"action\":\"set_saved\",\"name\":\"", SafeName/binary, "\"}">>,
                    {reply, {text, Response}, State};
                {error, Reason} ->
                    io:format("WebSocket: Failed to save set: ~p~n", [Reason]),
                    ErrMsg = iolist_to_binary(io_lib:format("Failed to save set: ~p", [Reason])),
                    Response = encode_error(ErrMsg),
                    {reply, {text, Response}, State}
            end
    end.

%% Extract set data for saving (preserves the full JSON with tracks)
extract_set_data_for_save(Text, Name) ->
    %% Find the tracks array in the original message
    TracksJson = extract_tracks_json(Text),
    %% Build the file content with name and tracks
    <<"{\"name\":\"", Name/binary, "\",\"tracks\":", TracksJson/binary, "}">>.

%% Extract the raw tracks JSON array from the message
extract_tracks_json(Text) ->
    case binary:match(Text, <<"\"tracks\":">>) of
        {Pos, Len} ->
            Start = Pos + Len,
            AfterKey = binary:part(Text, Start, byte_size(Text) - Start),
            %% Skip whitespace
            AfterWs = skip_whitespace(AfterKey),
            %% Find matching bracket
            extract_json_array(AfterWs);
        nomatch ->
            <<"[]">>
    end.

%% Skip leading whitespace
skip_whitespace(<<" ", Rest/binary>>) -> skip_whitespace(Rest);
skip_whitespace(<<"\t", Rest/binary>>) -> skip_whitespace(Rest);
skip_whitespace(<<"\n", Rest/binary>>) -> skip_whitespace(Rest);
skip_whitespace(<<"\r", Rest/binary>>) -> skip_whitespace(Rest);
skip_whitespace(Bin) -> Bin.

%% Extract JSON array (handling nested brackets)
extract_json_array(<<"[", Rest/binary>>) ->
    {ArrayContent, _} = extract_until_matching_bracket(Rest, 1, <<>>),
    <<"[", ArrayContent/binary, "]">>;
extract_json_array(_) ->
    <<"[]">>.

%% Extract content until matching closing bracket
extract_until_matching_bracket(<<>>, _, Acc) ->
    {Acc, <<>>};
extract_until_matching_bracket(<<"]", Rest/binary>>, 1, Acc) ->
    {Acc, Rest};
extract_until_matching_bracket(<<"]", Rest/binary>>, Depth, Acc) ->
    extract_until_matching_bracket(Rest, Depth - 1, <<Acc/binary, "]">>);
extract_until_matching_bracket(<<"[", Rest/binary>>, Depth, Acc) ->
    extract_until_matching_bracket(Rest, Depth + 1, <<Acc/binary, "[">>);
extract_until_matching_bracket(<<"{", Rest/binary>>, Depth, Acc) ->
    %% Handle nested objects - need to skip to matching }
    {ObjContent, AfterObj} = extract_until_matching_brace(Rest, 1, <<>>),
    extract_until_matching_bracket(AfterObj, Depth, <<Acc/binary, "{", ObjContent/binary, "}">>);
extract_until_matching_bracket(<<"\"", Rest/binary>>, Depth, Acc) ->
    %% Handle strings (skip escaped content)
    {StrContent, AfterStr} = extract_json_string(Rest, <<>>),
    extract_until_matching_bracket(AfterStr, Depth, <<Acc/binary, "\"", StrContent/binary, "\"">>);
extract_until_matching_bracket(<<C, Rest/binary>>, Depth, Acc) ->
    extract_until_matching_bracket(Rest, Depth, <<Acc/binary, C>>).

%% Extract until matching closing brace
extract_until_matching_brace(<<>>, _, Acc) ->
    {Acc, <<>>};
extract_until_matching_brace(<<"}", Rest/binary>>, 1, Acc) ->
    {Acc, Rest};
extract_until_matching_brace(<<"}", Rest/binary>>, Depth, Acc) ->
    extract_until_matching_brace(Rest, Depth - 1, <<Acc/binary, "}">>);
extract_until_matching_brace(<<"{", Rest/binary>>, Depth, Acc) ->
    extract_until_matching_brace(Rest, Depth + 1, <<Acc/binary, "{">>);
extract_until_matching_brace(<<"\"", Rest/binary>>, Depth, Acc) ->
    {StrContent, AfterStr} = extract_json_string(Rest, <<>>),
    extract_until_matching_brace(AfterStr, Depth, <<Acc/binary, "\"", StrContent/binary, "\"">>);
extract_until_matching_brace(<<C, Rest/binary>>, Depth, Acc) ->
    extract_until_matching_brace(Rest, Depth, <<Acc/binary, C>>).

%% Extract JSON string content (handling escapes)
extract_json_string(<<>>, Acc) ->
    {Acc, <<>>};
extract_json_string(<<"\\", C, Rest/binary>>, Acc) ->
    %% Escaped character
    extract_json_string(Rest, <<Acc/binary, "\\", C>>);
extract_json_string(<<"\"", Rest/binary>>, Acc) ->
    %% End of string
    {Acc, Rest};
extract_json_string(<<C, Rest/binary>>, Acc) ->
    extract_json_string(Rest, <<Acc/binary, C>>).

%% ============================================================================
%% Load Set Handler
%% ============================================================================

handle_load_set(Text, SchedulerPid, State) ->
    Name = extract_set_name(Text),
    case sanitize_name(Name) of
        <<>> ->
            io:format("WebSocket: Invalid set name~n"),
            Response = encode_error(<<"Invalid or empty set name">>),
            {reply, {text, Response}, State};
        SafeName ->
            io:format("WebSocket: Loading set '~s'~n", [SafeName]),
            FilePath = set_file_path(SafeName),
            case file:read_file(FilePath) of
                {ok, Content} ->
                    io:format("WebSocket: Loaded set from ~s~n", [FilePath]),
                    %% Parse and send active tracks to Tidal
                    send_set_to_tidal(Content, SchedulerPid),
                    %% Respond with full set data
                    TracksJson = extract_tracks_json(Content),
                    Response = <<"{\"action\":\"set_loaded\",\"name\":\"", SafeName/binary, "\",\"tracks\":", TracksJson/binary, "}">>,
                    {reply, {text, Response}, State};
                {error, enoent} ->
                    io:format("WebSocket: Set not found: ~s~n", [SafeName]),
                    Response = encode_error(<<"Set not found">>),
                    {reply, {text, Response}, State};
                {error, Reason} ->
                    io:format("WebSocket: Failed to load set: ~p~n", [Reason]),
                    ErrMsg = iolist_to_binary(io_lib:format("Failed to load set: ~p", [Reason])),
                    Response = encode_error(ErrMsg),
                    {reply, {text, Response}, State}
            end
    end.

%% Send active tracks from a set to the Tidal scheduler
send_set_to_tidal(SetContent, SchedulerPid) ->
    %% Extract all tracks
    AllTracks = extract_tracks_from_set(SetContent),
    %% Filter to only active tracks
    ActiveTracks = [T || T <- AllTracks, is_track_active(T)],
    io:format("WebSocket: Sending ~B active tracks to Tidal~n", [length(ActiveTracks)]),
    case ActiveTracks of
        [] ->
            %% No active tracks, send silence
            SchedulerPid ! {updatePattern, <<"~">>};
        _ ->
            %% Send tracks to scheduler
            TracksList = [#{pattern => P, channel => C} || {P, C, _Active} <- ActiveTracks],
            TracksArray = array:from_list(TracksList),
            SchedulerPid ! {updateTracks, TracksArray}
    end.

%% Extract tracks from saved set content (returns list of {Pattern, Channel, Active})
extract_tracks_from_set(Content) ->
    extract_tracks_from_set_loop(Content, []).

extract_tracks_from_set_loop(Content, Acc) ->
    %% Find next track object
    case binary:match(Content, <<"{\"name\":">>) of
        {Pos, _Len} ->
            AfterStart = binary:part(Content, Pos, byte_size(Content) - Pos),
            %% Extract this track's data
            Pattern = extract_json_field(AfterStart, <<"\"pattern\":\"">>, <<>>),
            Channel = extract_channel_from_track(AfterStart),
            Active = extract_active_from_track(AfterStart),
            %% Continue with remaining content
            case binary:match(AfterStart, <<"}">>) of
                {EndPos, _} ->
                    Remaining = binary:part(AfterStart, EndPos + 1, byte_size(AfterStart) - EndPos - 1),
                    extract_tracks_from_set_loop(Remaining, [{Pattern, Channel, Active} | Acc]);
                nomatch ->
                    lists:reverse(Acc)
            end;
        nomatch ->
            lists:reverse(Acc)
    end.

%% Extract "active" boolean from track object
extract_active_from_track(Text) ->
    case binary:match(Text, <<"\"active\":">>) of
        {Pos, Len} ->
            Start = Pos + Len,
            AfterKey = binary:part(Text, Start, byte_size(Text) - Start),
            AfterWs = skip_whitespace(AfterKey),
            case AfterWs of
                <<"true", _/binary>> -> true;
                <<"false", _/binary>> -> false;
                _ -> true  % Default to active
            end;
        nomatch ->
            true  % Default to active
    end.

%% Check if track is active
is_track_active({_Pattern, _Channel, Active}) -> Active.

%% ============================================================================
%% Delete Set Handler
%% ============================================================================

handle_delete_set(Text, State) ->
    Name = extract_set_name(Text),
    case sanitize_name(Name) of
        <<>> ->
            io:format("WebSocket: Invalid set name~n"),
            Response = encode_error(<<"Invalid or empty set name">>),
            {reply, {text, Response}, State};
        SafeName ->
            io:format("WebSocket: Deleting set '~s'~n", [SafeName]),
            FilePath = set_file_path(SafeName),
            case file:delete(FilePath) of
                ok ->
                    io:format("WebSocket: Deleted set ~s~n", [FilePath]),
                    Response = <<"{\"action\":\"set_deleted\",\"name\":\"", SafeName/binary, "\"}">>,
                    {reply, {text, Response}, State};
                {error, enoent} ->
                    io:format("WebSocket: Set not found: ~s~n", [SafeName]),
                    Response = encode_error(<<"Set not found">>),
                    {reply, {text, Response}, State};
                {error, Reason} ->
                    io:format("WebSocket: Failed to delete set: ~p~n", [Reason]),
                    ErrMsg = iolist_to_binary(io_lib:format("Failed to delete set: ~p", [Reason])),
                    Response = encode_error(ErrMsg),
                    {reply, {text, Response}, State}
            end
    end.

%% ============================================================================
%% JSON Encoding Helpers
%% ============================================================================

%% Encode error response
encode_error(Message) ->
    EscapedMsg = escape_json_string(Message),
    <<"{\"action\":\"error\",\"message\":\"", EscapedMsg/binary, "\"}">>.

%% Encode array of strings as JSON array
encode_string_array(Strings) ->
    Encoded = [<<"\"", (escape_json_string(S))/binary, "\"">> || S <- Strings],
    Joined = join_with_comma(Encoded),
    <<"[", Joined/binary, "]">>.

%% Join list of binaries with comma
join_with_comma([]) -> <<>>;
join_with_comma([H]) -> H;
join_with_comma([H|T]) ->
    lists:foldl(fun(E, Acc) -> <<Acc/binary, ",", E/binary>> end, H, T).

%% Escape special characters in JSON string
escape_json_string(Bin) when is_binary(Bin) ->
    escape_json_string_loop(Bin, <<>>);
escape_json_string(List) when is_list(List) ->
    escape_json_string(list_to_binary(List)).

escape_json_string_loop(<<>>, Acc) -> Acc;
escape_json_string_loop(<<"\"", Rest/binary>>, Acc) ->
    escape_json_string_loop(Rest, <<Acc/binary, "\\\"">>);
escape_json_string_loop(<<"\\", Rest/binary>>, Acc) ->
    escape_json_string_loop(Rest, <<Acc/binary, "\\\\">>);
escape_json_string_loop(<<"\n", Rest/binary>>, Acc) ->
    escape_json_string_loop(Rest, <<Acc/binary, "\\n">>);
escape_json_string_loop(<<"\r", Rest/binary>>, Acc) ->
    escape_json_string_loop(Rest, <<Acc/binary, "\\r">>);
escape_json_string_loop(<<"\t", Rest/binary>>, Acc) ->
    escape_json_string_loop(Rest, <<Acc/binary, "\\t">>);
escape_json_string_loop(<<C, Rest/binary>>, Acc) ->
    escape_json_string_loop(Rest, <<Acc/binary, C>>).
