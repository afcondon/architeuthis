-define(BUILD_TEST, <<"BUILD_MARKER_1767904118">>).
-module(tidal_webSocket_handler@foreign).
-export([binaryToString/1]).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

%% Sets directory relative to working directory
-define(SETUP_DIR, "setup").

%% Convert binary to string (UTF-8)
binaryToString(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(Bin, utf8);
binaryToString(Other) ->
    %% Already a string or other type
    Other.

%% Cowboy callbacks - delegate to PureScript
init(Req, _Config) ->
    %% After PR1.7d the WS handler no longer holds a scheduler pid;
    %% all dispatch goes through registered names (tidal_dispatcher,
    %% tidal_voice_sup, tidal_clock). State just tracks connection
    %% liveness for hypothetical disconnect cleanup.
    State = #{connected => true},
    io:format("WebSocket: New connection~n"),
    %% Default cowboy idle_timeout is 60_000ms — too aggressive for a
    %% live-coding session (the user routinely sits looking at the
    %% modular for >1 minute between commands). Bump to 30 minutes.
    Opts = #{idle_timeout => 1800000},
    {cowboy_websocket, Req, State, Opts}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Text}, State) ->
    tidal_log:debug("WebSocket: Received message: ~s~n", [Text]),
    handle_pattern_message(Text, State);
websocket_handle({binary, Bin}, State) ->
    %% Treat binary as text
    websocket_handle({text, Bin}, State);
websocket_handle(_Frame, State) ->
    {ok, State}.

%% Try to parse one of the built-in verb prefixes.
%% Returns one of:
%%   {fh2_envelope, Voice, Output, Channel}    — register an FH-2 envelope voice
%%   {fh2_trigger, Voice, Pattern}             — pattern fires MIDI notes to FH-2 voice
%%   {fh2_shape, Voice, A, D, S, R}            — live ADSR via CCs 70/71/72/73
%%   {bind, Name, ActionSpec}                  — register a named binding
%%   {unbind, Name}                            — remove a named binding
%%   {hush}                                    — silence everything (Tidal-compat)
%%   none                                      — try named-binding dispatch
try_parse_prefixed(<<"hush">>) -> {hush};
try_parse_prefixed(<<"hush ", _/binary>>) -> {hush};
try_parse_prefixed(<<"silence">>) -> {hush};
try_parse_prefixed(<<"silence ", _/binary>>) -> {hush};
try_parse_prefixed(<<"log-level ", Rest/binary>>) ->
    try
        N = binary_to_integer(string:trim(Rest, both, "\r \t")),
        case N >= 0 andalso N =< 2 of
            true -> {log_level, N};
            false -> none
        end
    catch error:badarg -> none
    end;
try_parse_prefixed(<<"midi-device ", Rest/binary>>) ->
    %% midi-device <alias> <device-name-with-spaces> [lat <ms>]
    %% The optional `lat <ms>` suffix is stripped first if present;
    %% remainder is the device name. Surrounding `"..."` quotes are
    %% stripped — without this, the shell-quoted format string later
    %% wraps the value in another pair of quotes, producing
    %% `dev ""AUDIO4c USB2""` which the shell tokenises as two unquoted
    %% words and sendmidi falls back to substring matching.
    case binary:split(Rest, <<" ">>) of
        [Alias, AfterAlias] when AfterAlias =/= <<>> ->
            {RawName, Latency} = split_lat_suffix(AfterAlias),
            DeviceName = strip_surrounding_quotes(RawName),
            {midi_device, Alias, DeviceName, Latency};
        _ -> none
    end;
try_parse_prefixed(<<"fh2-envelope ", Rest/binary>>) ->
    %% fh2-envelope <voice> <output> <channel>
    case binary:split(Rest, <<" ">>, [global]) of
        [VoiceBin, OutputBin, ChannelBin] ->
            try
                Voice = binary_to_integer(VoiceBin),
                Output = binary_to_integer(OutputBin),
                Channel = binary_to_integer(ChannelBin),
                {fh2_envelope, Voice, Output, Channel}
            catch
                error:badarg -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"fh2-gate ", Rest/binary>>) ->
    %% fh2-gate <voice> <output> <channel>
    %%   1-8     → FH-2 main jacks
    %%   9-64    → FHX-8CV expanders
    %%   65-128  → FHX-8GT expanders (separate routing — uses basegate field)
    case binary:split(Rest, <<" ">>, [global]) of
        [VoiceBin, OutputBin, ChannelBin] ->
            try
                Voice = binary_to_integer(VoiceBin),
                Output = binary_to_integer(OutputBin),
                Channel = binary_to_integer(ChannelBin),
                {fh2_gate, Voice, Output, Channel}
            catch
                error:badarg -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"fh2-trigger ", Rest/binary>>) ->
    try_parse_num_pattern(fh2_trigger, Rest);
try_parse_prefixed(<<"fh2-shape ", Rest/binary>>) ->
    %% fh2-shape <voice> <attack> <decay> <sustain> <release>
    case binary:split(Rest, <<" ">>, [global]) of
        [VoiceBin, ABin, DBin, SBin, RBin] ->
            try
                Voice = binary_to_integer(VoiceBin),
                A = binary_to_integer(ABin),
                D = binary_to_integer(DBin),
                S = binary_to_integer(SBin),
                R = binary_to_integer(RBin),
                {fh2_shape, Voice, A, D, S, R}
            catch
                error:badarg -> none
            end;
        _ -> none
    end;
try_parse_prefixed(<<"bind ", Rest/binary>>) ->
    %% bind <name> <action-spec>; action-spec runs to end of line.
    case binary:split(Rest, <<" ">>) of
        [Name, ActionSpec] -> {bind, Name, ActionSpec};
        _ -> none
    end;
try_parse_prefixed(<<"unbind ", Rest/binary>>) ->
    %% unbind <name>
    Name = binary_part(Rest, 0, byte_size(Rest)),
    case binary:match(Name, <<" ">>) of
        nomatch -> {unbind, Name};
        _ -> none
    end;
try_parse_prefixed(<<"load ", Rest/binary>>) ->
    %% load <name>  — read setup/<name>.tidal and evaluate each line
    Name = binary_part(Rest, 0, byte_size(Rest)),
    case binary:match(Name, <<" ">>) of
        nomatch -> {load, Name};
        _ -> none
    end;
try_parse_prefixed(<<"state">>) ->
    %% state — read latest StateBus snapshot (ETS-backed) and reply.
    %% No args; trailing chars after `state` aren't accepted to keep
    %% the verb unambiguous.
    {state};
try_parse_prefixed(<<"bpm ", Rest/binary>>) ->
    %% Shortcut for `config bpm <n>` — bpm is the most-likely-to-change
    %% config dimension and warrants a one-word verb.  Same SetBpm
    %% scheduler path: sends /link/set-tempo to link-spike AND updates
    %% the local free-run fallback.
    case parse_number(trim_binary(Rest)) of
        {ok, N} -> {set_bpm, N};
        error -> none
    end;
try_parse_prefixed(<<"config bpm ", Rest/binary>>) ->
    case parse_number(trim_binary(Rest)) of
        {ok, N} -> {set_bpm, N};
        error -> none
    end;
try_parse_prefixed(_) ->
    none.

try_parse_num_pattern(Tag, Rest) ->
    case binary:split(Rest, <<" ">>) of
        [NumBin, Pattern] ->
            try
                Num = binary_to_integer(NumBin),
                {Tag, Num, strip_quotes(Pattern)}
            catch
                error:badarg -> none
            end;
        _ ->
            none
    end.

%% Parse a binary as a float, accepting either "1.5" or "1" (integer literal).
parse_number(Bin) ->
    try
        FloatVal = binary_to_float(Bin),
        {ok, FloatVal}
    catch
        error:badarg ->
            try
                IntVal = binary_to_integer(Bin),
                {ok, float(IntVal)}
            catch
                error:badarg -> error
            end
    end.

%% Split "<word> <rest>" into {Word, Rest}, or treat single-word input as
%% {Word, <<>>}. Used for named-binding dispatch fallback.
%% Strips surrounding double quotes from Rest so Tidal-style
%% `kick "bd*4"` works the same as our native `kick bd*4`.
split_first_word(Text) ->
    case binary:split(Text, <<" ">>) of
        [Word, Rest] -> {Word, strip_quotes(trim_binary(Rest))};
        [Word] -> {Word, <<>>}
    end.

%% Split a `#`-joined named-binding line into the structure pattern
%% plus a list of joined parameter specs.
%%
%%   `kick "x*4" # vel "100 64 80 50"`            →
%%       {<<"kick">>, <<"x*4">>, [#{name => <<"vel">>, pat => <<"100 64 80 50">>}]}
%%
%%   `kick "x*4" # vel "100" # cutoff "30 60"`    →
%%       {<<"kick">>, <<"x*4">>, [#{name => <<"vel">>, pat => <<"100">>},
%%                                #{name => <<"cutoff">>, pat => <<"30 60">>}]}
%%
%%   `kick "x*4"`                                 →
%%       {<<"kick">>, <<"x*4">>, []}
%%
%% Each segment uses split_first_word to peel off the leading word and
%% strip outer quotes from the body.  Pre-`#`-split avoids the
%% strip_quotes-on-mixed-content trap (where `kick "x*4" # vel "..."`
%% has its outer quotes mis-stripped if treated as a single word+rest).
parse_with_join(Text) ->
    case binary:split(Text, <<" # ">>, [global]) of
        [Single] ->
            %% No join — return the existing word+rest shape with empty params.
            {Word, Rest} = split_first_word(Single),
            {Word, Rest, []};
        [First | RestSegments] ->
            {Word, StructPat} = split_first_word(First),
            ParamSpecs = [parse_join_segment(S) || S <- RestSegments],
            %% Drop any segments that didn't yield a name+body shape.
            ValidSpecs = [P || P <- ParamSpecs, P =/= invalid],
            {Word, StructPat, ValidSpecs}
    end.

%% Parse one `<name> <body>` segment from after a `#`.  The body may
%% be quoted; strip_quotes handles the unquoted case idempotently.
%% Returns `invalid` rather than a partial spec if the segment doesn't
%% have at least name + body — the caller drops invalid specs.
parse_join_segment(Segment) ->
    case binary:split(string:trim(Segment), <<" ">>) of
        [Name, Body] when Body =/= <<>> ->
            #{name => Name, pat => strip_quotes(Body)};
        _ ->
            invalid
    end.

%% Strip a single pair of surrounding double quotes if present.
%% `<<"\"bd*4\"">>` → `<<"bd*4">>`. Idempotent on already-unquoted input.
strip_quotes(Bin) ->
    Sz = byte_size(Bin),
    case Sz >= 2 of
        true ->
            First = binary:part(Bin, 0, 1),
            Last = binary:part(Bin, Sz - 1, 1),
            case First =:= <<"\"">> andalso Last =:= <<"\"">> of
                true -> binary:part(Bin, 1, Sz - 2);
                false -> Bin
            end;
        false -> Bin
    end.

%% Trim leading/trailing whitespace from a binary.
trim_binary(Bin) ->
    list_to_binary(string:trim(binary_to_list(Bin))).

%% Strip a trailing " lat <ms>" suffix from a device-name binary.
%% Returns {DeviceName, Latency} where Latency is a float (default 0.0
%% if the suffix is absent or unparseable).
%%
%%   "FH-2"               → {<<"FH-2">>, 0.0}
%%   "AUDIO4c USB2 lat 12"→ {<<"AUDIO4c USB2">>, 12.0}
%%   "FH-2 lat 1.5"       → {<<"FH-2">>, 1.5}
strip_surrounding_quotes(<<"\"", Rest/binary>>) when byte_size(Rest) >= 1 ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> <<"\"", Rest/binary>>
    end;
strip_surrounding_quotes(B) -> B.

split_lat_suffix(Bin) ->
    %% Look for " lat " followed by a number to end of line.
    Parts = binary:split(Bin, <<" lat ">>, [global]),
    case Parts of
        [Single] ->
            {Single, 0.0};
        [Name | LatParts] ->
            %% The lat value is everything after the LAST " lat ".
            %% (Unlikely to be ambiguous since device names don't usually
            %% contain " lat " — but if they do, that's a self-inflicted
            %% wound and we still cope.)
            LatBin = lists:last(LatParts),
            case parse_number(trim_binary(LatBin)) of
                {ok, Lat} -> {Name, Lat};
                error -> {Bin, 0.0}  %% suffix didn't parse — treat whole thing as name
            end
    end.

%% Handle pattern messages. New path: recognise "gate <ch>" / "cv <bus>"
%% prefixes for per-track replacement (live-coding shape). Otherwise
%% fall through to the legacy single-pattern / multi-track JSON parser.
handle_pattern_message(Text, State) ->
    case try_parse_prefixed(Text) of
        {bind, Name, ActionSpec} ->
            tidal_dispatcher:set_binding_from_spec(Name, ActionSpec),
            Reply = {text, <<"OK: bind ", Name/binary, " ", ActionSpec/binary>>},
            {reply, Reply, State};
        {unbind, Name} ->
            tidal_dispatcher:remove_binding(Name),
            Reply = {text, <<"OK: unbind ", Name/binary>>},
            {reply, Reply, State};
        {hush} ->
            tidal_voice_sup:hush_all(),
            Reply = {text, <<"OK: hush">>},
            {reply, Reply, State};
        {log_level, N} ->
            tidal_log:set_level(N),
            NBin = integer_to_binary(N),
            Reply = {text, <<"OK: log-level ", NBin/binary>>},
            {reply, Reply, State};
        {load, Name} ->
            handle_load_setup(Name, State);
        {midi_device, Alias, DeviceName, Latency} ->
            tidal_dispatcher:register_midi_device(Alias, DeviceName, Latency),
            LatBin = list_to_binary(io_lib:format("~p", [Latency])),
            Reply = {text, <<"OK: midi-device ", Alias/binary,
                             " = ", DeviceName/binary,
                             " (lat ", LatBin/binary, "ms)">>},
            {reply, Reply, State};
        {fh2_gate, Voice, Output, Channel} ->
            %% Gate-only MCV configuration via fh2-config CLI shell-out.
            %% No scheduler state to update (gates are dispatched via
            %% bind+midi-note, which uses explicit channel — no voice
            %% lookup needed).
            spawn(fun() -> fh2_set_gate(Voice, Output, Channel) end),
            Reply = {text, <<"OK: fh2-gate voice ",
                             (integer_to_binary(Voice))/binary,
                             " -> output ", (integer_to_binary(Output))/binary,
                             " on ch ", (integer_to_binary(Channel))/binary,
                             " (SysEx push in flight)">>},
            {reply, Reply, State};
        {fh2_envelope, Voice, Output, Channel} ->
            %% Dispatcher owns the voice→channel mapping (PR1.6 +
            %% PR1.7b). setFh2VoiceChannel auto-registers the `fh2`
            %% MIDI device alias if the user hasn't done it manually.
            %% The FH-2 SysEx push runs in the background (5–10s);
            %% any fh2-trigger note that lands during the push just
            %% hits the still-old routing for a moment.
            tidal_dispatcher:set_fh2_voice_channel(Voice, Channel),
            spawn(fun() -> fh2_set_envelope(Voice, Output, Channel) end),
            Reply = {text, <<"OK: fh2-envelope voice ",
                             (integer_to_binary(Voice))/binary,
                             " -> output ", (integer_to_binary(Output))/binary,
                             " on ch ", (integer_to_binary(Channel))/binary,
                             " (SysEx push in flight)">>},
            {reply, Reply, State};
        {fh2_trigger, Voice, Pattern} ->
            %% After PR1.6: install a Discrete voice in the new tree
            %% with name `fh2-v<N>` and a single Fh2Trigger PrimAction.
            %% defaultNote = 60 (C4) matches MIDIScheduler's previous
            %% fallback for non-note-name tokens. Channel is resolved
            %% at dispatch time from the dispatcher's
            %% fh2VoiceChannels map (populated via fh2-envelope above).
            case ('tidal_expr@ps':parseMiniPattern())(Pattern) of
                {right, Pat} ->
                    VoiceName = <<"fh2-v",
                                  (integer_to_binary(Voice))/binary>>,
                    Binding = array:from_list(
                        [{fh2Trigger, #{voice => Voice,
                                        defaultNote => 60}}]),
                    %% Dispatcher needs the binding for dispatch-time
                    %% lookup; voice_sup needs it for the voice's
                    %% State. Set dispatcher first (synchronous call)
                    %% so the voice can never emit an event before
                    %% the dispatcher knows about the name.
                    tidal_dispatcher:set_binding(VoiceName, Binding),
                    case tidal_voice_sup:set_voice_pat(
                           VoiceName, Binding, Pat) of
                        ok ->
                            Reply = {text,
                                     <<"OK: fh2-trigger v",
                                       (integer_to_binary(Voice))/binary,
                                       " ", Pattern/binary>>},
                            {reply, Reply, State};
                        {error, Err} ->
                            ErrBin = list_to_binary(
                                       io_lib:format("~p", [Err])),
                            {reply,
                             {text, <<"ERROR: fh2-trigger: ",
                                      ErrBin/binary>>},
                             State}
                    end;
                {left, ErrBin0} ->
                    ErrBin = case ErrBin0 of
                        B when is_binary(B) -> B;
                        Other -> list_to_binary(
                                   io_lib:format("~p", [Other]))
                    end,
                    Reply = {text,
                             <<"ERROR: fh2-trigger parse: ",
                               ErrBin/binary>>},
                    {reply, Reply, State}
            end;
        {fh2_shape, Voice, A, D, S, R} ->
            tidal_dispatcher:dispatch_fh2_shape(Voice, A, D, S, R),
            Reply = {text, <<"OK: fh2-shape v",
                             (integer_to_binary(Voice))/binary,
                             " A=", (integer_to_binary(A))/binary,
                             " D=", (integer_to_binary(D))/binary,
                             " S=", (integer_to_binary(S))/binary,
                             " R=", (integer_to_binary(R))/binary>>},
            {reply, Reply, State};
        {state} ->
            %% Read latest snapshot from StateBus (ETS-backed).  Falls
            %% back to "{}" if the table doesn't exist yet (boot window).
            Json = (tidal_stateBus@foreign:read())(),
            {reply, {text, Json}, State};
        {set_bpm, N} ->
            %% Clock owns the BPM value; dispatcher broadcasts to
            %% link-spike. Both fire in parallel — clock's set_bpm is
            %% synchronous (so the snapshot picks up the new value on
            %% the next publisher tick), dispatcher's set_link_tempo
            %% is fire-and-forget OSC.
            tidal_clock:set_bpm(N),
            tidal_dispatcher:set_link_tempo(N),
            NumBin = list_to_binary(io_lib:format("~p", [N])),
            {reply, {text, <<"OK: bpm = ", NumBin/binary>>}, State};
        none ->
            %% Not a built-in verb. Try named-binding dispatch.
            %% Unbound names produce an error reply (the legacy whole-
            %% text fallback that lived in MIDIScheduler is gone as of
            %% PR1.7a).
            case Text of
                <<":", ExprSrc/binary>> ->
                    %% Bare `:<expr>` form. Voice tags inside the
                    %% expression's fan-out spec name bindings
                    %% directly, so each voice flows to its own
                    %% destination. Distinct from `<binding> :<expr>`
                    %% which fans-out-then-merges through one channel.
                    handle_multi_expr(ExprSrc, Text, State);
                _ ->
                    {Word, Rest, ParamSpecs} = parse_with_join(Text),
                    case Rest of
                        <<":", ExprSrc/binary>> ->
                            %% Named-binding + host-language expression
                            %% form (`bass :rev "c2*4 g2*4"`). Evaluate
                            %% via Tidal.Expr and dispatch the result as
                            %% a BoundTrack so the binding's note
                            %% resolver applies.  Param specs from `#`
                            %% segments are ignored on this path in v1;
                            %% the expression already produces a
                            %% complete Pattern.
                            handle_play_by_name_expr(Word, ExprSrc, Text, State);
                        _ ->
                            %% Pre-flight parse so malformed input
                            %% (non-ASCII chars reaching the upstream
                            %% parser, etc.) returns [err] instead of
                            %% crashing the scheduler.  Check `Rest`
                            %% (quote-stripped pattern body) — that's
                            %% what the scheduler uses for the
                            %% bound-name case, AND it covers the
                            %% legacy-fallback case adequately because
                            %% if Rest contains crash-inducing input,
                            %% Text will too.  Crucially, checking Text
                            %% instead would reject valid bound-name
                            %% dispatches with quoted patterns
                            %% (`kick "bd*4"`), since Text contains the
                            %% quote chars the parser doesn't understand.
                            case safe_parse(Rest) of
                                {ok, _} ->
                                    %% Route through new tree if Word
                                    %% is a registered binding; otherwise
                                    %% return an error (legacy whole-text
                                    %% fallback removed in PR1.7a).
                                    case tidal_dispatcher:lookup_binding(Word) of
                                        {just, Binding} ->
                                            case tidal_voice_sup:set_voice(
                                                   Word, Binding, Rest, ParamSpecs) of
                                                ok ->
                                                    Reply = {text, <<"OK: dispatched '",
                                                                     Word/binary, "'">>},
                                                    {reply, Reply, State};
                                                {error, Err} ->
                                                    ErrBin = list_to_binary(
                                                               io_lib:format("~p", [Err])),
                                                    Reply = {text, <<"ERROR: ",
                                                                     ErrBin/binary>>},
                                                    {reply, Reply, State}
                                            end;
                                        {nothing} ->
                                            Reply = {text,
                                                     <<"ERROR: no binding '",
                                                       Word/binary,
                                                       "' (use `bind` first)">>},
                                            {reply, Reply, State}
                                    end;
                                {parse_err, ErrBin} ->
                                    Reply = {text, <<"ERROR: parse: ", ErrBin/binary>>},
                                    {reply, Reply, State}
                            end
                    end
            end
    end.

%% Wrap the Tidal parser in try/catch so any uncaught exception
%% (e.g. Data.String.split blowing up on incomplete UTF-8) becomes
%% a graceful {parse_err, Reason} instead of crashing the scheduler.
%% The parser returns Either-shaped {right, _} | {left, _}, so we
%% also surface Left as parse_err.
safe_parse(Text) ->
    try
        case ('tidal_parse_parser@ps':parse())(Text) of
            {right, _} -> {ok, ok};
            {left, Err} ->
                {parse_err, list_to_binary(io_lib:format("~p", [Err]))}
        end
    catch
        Class:Reason ->
            {parse_err, list_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L);
to_binary(Other) -> list_to_binary(io_lib:format("~p", [Other])).

%% Named-binding `<name> :<expr>` path. Three-way routing:
%%   * discrete binding   → new voice tree, parseEvalPattern.
%%   * continuous binding → new voice tree, parseEvalNumPattern.
%%   * neither            → ERROR reply (legacy fallback gone).
%%
%% Parse failures inside either bound branch surface as ERROR
%% replies too — the user sees the message in Calypso instead of
%% buried in the BEAM log (the MIDIScheduler-side typed-error
%% diagnostic was retired with PR1.7d).
handle_play_by_name_expr(Word, ExprSrc, _FullText, State) ->
    OkReply = {reply,
               {text, <<"OK: dispatched '", Word/binary,
                        "' :", ExprSrc/binary>>},
               State},
    case tidal_dispatcher:lookup_binding(Word) of
        {just, Binding} ->
            case ('tidal_expr@ps':parseEvalPattern())(ExprSrc) of
                {right, Pattern} ->
                    case tidal_voice_sup:set_voice_pat(Word, Binding, Pattern) of
                        ok -> OkReply;
                        {error, Err} ->
                            ErrBin = list_to_binary(io_lib:format("~p", [Err])),
                            {reply,
                             {text, <<"ERROR: ", ErrBin/binary>>},
                             State}
                    end;
                {left, Err} ->
                    ErrBin = to_binary(Err),
                    {reply,
                     {text, <<"ERROR: ", Word/binary, " :expr: ",
                              ErrBin/binary>>},
                     State}
            end;
        {nothing} ->
            case tidal_dispatcher:lookup_continuous_binding(Word) of
                {just, Dest} ->
                    case ('tidal_expr@ps':parseEvalNumPattern())(ExprSrc) of
                        {right, NumPattern} ->
                            case tidal_voice_sup:set_voice_cont_pat(
                                   Word, Dest, NumPattern) of
                                ok -> OkReply;
                                {error, Err} ->
                                    ErrBin = list_to_binary(
                                               io_lib:format("~p", [Err])),
                                    {reply,
                                     {text, <<"ERROR: ", ErrBin/binary>>},
                                     State}
                            end;
                        {left, Err} ->
                            ErrBin = to_binary(Err),
                            {reply,
                             {text, <<"ERROR: ", Word/binary, " :expr: ",
                                      ErrBin/binary>>},
                             State}
                    end;
                {nothing} ->
                    {reply,
                     {text, <<"ERROR: no binding '", Word/binary,
                              "' (use `bind` first)">>},
                     State}
            end
    end.

%% Bare `:<expr>` form: voice tags name bindings, each voice flows to
%% its own destination. Tidal.Expr.evalMulti returns the per-voice
%% (name, Pattern) pairs as an Erlang array of `{tuple, Name, Pat}`
%% (PureScript Array (Tuple String (Pattern String))). For each entry
%% we look up the binding on the dispatcher; entries with a discrete
%% binding install on the new voice tree, entries without log the
%% same "voice skipped" message MIDIScheduler.PlayMultiByName used to.
%%
%% After this commit MIDIScheduler is no longer in this path —
%% PlayMultiByName migrates entirely to the new tree. The reply still
%% lists only the names that actually got installed (skipped entries
%% don't appear in the bracketed list).
handle_multi_expr(ExprSrc, _FullText, State) ->
    Result = try ('tidal_expr@ps':evalMulti())(ExprSrc)
             catch Class:Reason ->
                 {crash, list_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
             end,
    case Result of
        {right, Entries} ->
            EntryList = array:to_list(Entries),
            InstalledNames = install_multi_entries(EntryList),
            NamesBin = case InstalledNames of
                [] -> <<"(no voices)">>;
                _  -> join_binary(InstalledNames, <<", ">>)
            end,
            {reply,
             {text, <<"OK: dispatched multi [", NamesBin/binary, "] :",
                      ExprSrc/binary>>},
             State};
        {left, Err} ->
            ErrBin = to_binary(Err),
            {reply, {text, <<"ERROR: expr: ", ErrBin/binary>>}, State};
        {crash, CrashBin} ->
            {reply, {text, <<"ERROR: expr crash: ", CrashBin/binary>>}, State}
    end.

%% Walk the entries list, installing each on the new tree if its name
%% has a discrete binding. Returns the list of installed names in
%% original order (for the WS reply text).
install_multi_entries(Entries) ->
    install_multi_entries(Entries, []).

install_multi_entries([], Acc) ->
    lists:reverse(Acc);
install_multi_entries([{tuple, Name, Pat} | Rest], Acc) ->
    case tidal_dispatcher:lookup_binding(Name) of
        {just, Binding} ->
            tidal_voice_sup:set_voice_pat(Name, Binding, Pat),
            install_multi_entries(Rest, [Name | Acc]);
        {nothing} ->
            io:format("(no binding '~s', voice skipped)~n", [Name]),
            install_multi_entries(Rest, Acc)
    end.

join_binary([], _Sep) -> <<>>;
join_binary([X], _Sep) -> X;
join_binary([X | Rest], Sep) ->
    RestJoined = join_binary(Rest, Sep),
    <<X/binary, Sep/binary, RestJoined/binary>>.

websocket_info(Info, State) ->
    io:format("WebSocket: Info: ~p~n", [Info]),
    {ok, State}.

%% Sanitize a name from a WS verb argument to prevent path traversal
%% on filesystem operations (e.g. `load <name>` reads
%% `setup/<name>.tidal`). Only allows alphanumeric, dash, underscore.
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


%% ============================================================================
%% Load Setup File Handler
%% ============================================================================
%%
%% `load <name>` reads `setup/<name>.tidal` and evaluates each non-blank,
%% non-comment line as if it had been typed in the WS one at a time.
%% Useful for one-line "boot" of a device's full bind set:
%%   - load rample      → 44-line Rample MIDI vocabulary
%%   - load fh2-base    → standard FH-2 envelope farm
%%   - load show1-set1  → live-coded scene preset
%%
%% Comments use Tidal's `--` line-comment syntax (Haskell-derived).
%% Blank lines are ignored.
%%
%% Each line is parsed via the same try_parse_prefixed + dispatch logic
%% used by direct WS messages, so any verb (bind, midi-device, fh2-*,
%% rample-*, gate, cv, hush, even other `load` calls) works inside
%% setup files. Errors on individual lines are logged but don't abort
%% the load (best-effort — partial setup is more useful than none).

handle_load_setup(Name, State) ->
    case sanitize_name(Name) of
        <<>> ->
            Reply = {text, <<"ERROR: load - invalid name (alphanum/dash/underscore only)">>},
            {reply, Reply, State};
        SafeName ->
            FilePath = setup_file_path(SafeName),
            case file:read_file(FilePath) of
                {ok, Content} ->
                    Lines = binary:split(Content, <<"\n">>, [global]),
                    {Total, Skipped, Errors} = lists:foldl(
                        fun(Line, {T, S, E}) ->
                            Trimmed = trim_line(Line),
                            case classify_line(Trimmed) of
                                blank   -> {T, S + 1, E};
                                comment -> {T, S + 1, E};
                                code    ->
                                    case dispatch_setup_line(Trimmed) of
                                        ok    -> {T + 1, S, E};
                                        error -> {T + 1, S, E + 1}
                                    end
                            end
                        end,
                        {0, 0, 0},
                        Lines
                    ),
                    Summary = iolist_to_binary(io_lib:format(
                        "OK: load ~s - ~B lines fired (~B skipped, ~B errors)",
                        [SafeName, Total, Skipped, Errors])),
                    {reply, {text, Summary}, State};
                {error, enoent} ->
                    Msg = iolist_to_binary(io_lib:format(
                        "ERROR: load ~s - file not found at ~s",
                        [SafeName, FilePath])),
                    {reply, {text, Msg}, State};
                {error, Reason} ->
                    Msg = iolist_to_binary(io_lib:format(
                        "ERROR: load ~s - ~p", [SafeName, Reason])),
                    {reply, {text, Msg}, State}
            end
    end.

%% Resolve a setup name to a filesystem path. Relative to BEAM CWD,
%% which is typically purerl-tidal/ when started via `rebar3 shell`.
setup_file_path(SafeName) ->
    filename:join([?SETUP_DIR, <<SafeName/binary, ".tidal">>]).

%% Strip leading/trailing whitespace AND a trailing \r (for CRLF files).
%% Erlang binary patterns require a size on a /binary segment unless it's
%% the last in the pattern, so we use string:trim with the explicit char
%% set instead of pattern-matching for the \r.
trim_line(Line) ->
    string:trim(Line, both, "\r \t").

%% Classify a (trimmed) line as blank, comment, or code.
classify_line(<<>>) -> blank;
classify_line(<<"--", _/binary>>) -> comment;
classify_line(_) -> code.

%% Dispatch one line from a setup file. Mirrors handle_pattern_message
%% minus the WS replies, plus a "name + pattern" path for unprefixed
%% lines.
dispatch_setup_line(Line) ->
    case try_parse_prefixed(Line) of
        none ->
            %% Unprefixed line — treat as named-binding dispatch with
            %% optional `#` parameter joins.
            {Word, Rest, ParamSpecs} = parse_with_join(Line),
            case safe_parse(Rest) of
                {ok, _} ->
                    case tidal_dispatcher:lookup_binding(Word) of
                        {just, Binding} ->
                            case tidal_voice_sup:set_voice(
                                   Word, Binding, Rest, ParamSpecs) of
                                ok -> ok;
                                {error, Err} ->
                                    io:format("[load] install error on line ~s: ~p~n",
                                              [Line, Err]),
                                    error
                            end;
                        {nothing} ->
                            io:format("[load] no binding for '~s' on line: ~s~n",
                                      [Word, Line]),
                            error
                    end;
                {parse_err, _} ->
                    io:format("[load] parse error on line: ~s~n", [Line]),
                    error
            end;
        Action ->
            dispatch_setup_action(Action)
    end.

%% Run a parsed action against the same destinations
%% handle_pattern_message uses, minus the WS reply side. Add a clause
%% here whenever a new verb is added to handle_pattern_message that
%% should also work inside setup files.
dispatch_setup_action(Action) ->
    case Action of
        {midi_device, Alias, DeviceName, Latency} ->
            tidal_dispatcher:register_midi_device(Alias, DeviceName, Latency),
            ok;
        {bind, Name, ActionSpec} ->
            tidal_dispatcher:set_binding_from_spec(Name, ActionSpec),
            ok;
        {unbind, Name} ->
            tidal_dispatcher:remove_binding(Name),
            ok;
        {hush} ->
            tidal_voice_sup:hush_all(),
            ok;
        {load, Name} ->
            %% Recursive load — common pattern: a "scene" file that
            %% loads device packs first, then defines patterns.
            handle_load_setup(Name, #{}),
            ok;
        {fh2_gate, Voice, Output, Channel} ->
            %% Synchronous on the load path. fh2-config does a read-
            %% modify-write of the FH-2's full config blob; parallel
            %% invocations race and clobber each other (only the last
            %% writer's slot survives). Serialising here costs ~7s per
            %% gate but is the only way to reliably configure multiple
            %% MCVs in one `load`. The WS-direct path (handle_pattern_
            %% message) still spawns since one-off typing can't race.
            fh2_set_gate(Voice, Output, Channel),
            ok;
        {fh2_envelope, Voice, Output, Channel} ->
            tidal_dispatcher:set_fh2_voice_channel(Voice, Channel),
            fh2_set_envelope(Voice, Output, Channel),
            ok;
        {set_bpm, N} ->
            tidal_clock:set_bpm(N),
            tidal_dispatcher:set_link_tempo(N),
            ok;
        Other ->
            io:format("[load] verb not yet supported in setup files: ~p~n", [Other]),
            error
    end.

%% Shell out to fh2-config to push the per-MCV envelope routing to the
%% real FH-2 hardware. Synchronous within the spawned process (caller
%% spawn/1's it so the WS handler returns immediately). Logs the result
%% to stdout where the BEAM is running so failures aren't silent.
%%
%% The fh2-config binary lives at a known path; if you move it, update
%% here too. (Could be made configurable via app env later.)
fh2_set_envelope(Voice, Output, Channel) ->
    %% Composite --set-envelope-with-ccs (envelope routing + ADSR CCs in
    %% one config write).  Tries the fh2-config daemon first via Unix
    %% socket; falls back to `spago run -- --set-envelope-with-ccs ...`
    %% if no daemon is reachable.  Daemon path is sub-100ms; standalone
    %% is 5-10s per call.
    Cmd = iolist_to_binary(io_lib:format(
        "set-envelope-with-ccs ~B ~B ~B", [Voice, Output, Channel])),
    case fh2_daemon_call(Cmd) of
        {ok, Reply} ->
            io:format("[fh2-envelope daemon] voice=~B output=~B ch=~B: ~s~n",
                      [Voice, Output, Channel, Reply]);
        {error, _Reason} ->
            io:format("[fh2-envelope] no daemon, falling back to spago shell-out~n"),
            fh2_set_envelope_standalone(Voice, Output, Channel)
    end.

fh2_set_envelope_standalone(Voice, Output, Channel) ->
    Path = "/Users/afc/work/afc-work/music/expert-sleepers/fh2-config",
    Cmd = io_lib:format(
        "cd ~s && spago run -- --set-envelope-with-ccs ~B ~B ~B 2>&1",
        [Path, Voice, Output, Channel]),
    Output0 = os:cmd(lists:flatten(Cmd)),
    io:format("[fh2-envelope shell-out] voice=~B output=~B ch=~B done~n~ts~n",
              [Voice, Output, Channel, Output0]).

fh2_set_gate(Voice, Output, Channel) ->
    %% Gate-only MCV.  Routes to FH-2 main jacks (1-8), FHX-8CV (9-64),
    %% or FHX-8GT (65-128) automatically based on output number.  Tries
    %% the daemon first; falls back to spago shell-out otherwise.
    Cmd = iolist_to_binary(io_lib:format(
        "set-gate ~B ~B ~B", [Voice, Output, Channel])),
    case fh2_daemon_call(Cmd) of
        {ok, Reply} ->
            io:format("[fh2-gate daemon] voice=~B output=~B ch=~B: ~s~n",
                      [Voice, Output, Channel, Reply]);
        {error, _Reason} ->
            io:format("[fh2-gate] no daemon, falling back to spago shell-out~n"),
            fh2_set_gate_standalone(Voice, Output, Channel)
    end.

fh2_set_gate_standalone(Voice, Output, Channel) ->
    Path = "/Users/afc/work/afc-work/music/expert-sleepers/fh2-config",
    Cmd = io_lib:format(
        "cd ~s && spago run -- --set-gate ~B ~B ~B 2>&1",
        [Path, Voice, Output, Channel]),
    Output0 = os:cmd(lists:flatten(Cmd)),
    io:format("[fh2-gate shell-out] voice=~B output=~B ch=~B done~n~ts~n",
              [Voice, Output, Channel, Output0]).

%% --- fh2-config daemon client ---------------------------------------
%% Single round-trip Unix-socket client.  Matches fh2-config's daemon
%% protocol: send one line, read one newline-terminated reply, close.
%% Returns {ok, ReplyBinary} on success, {error, Reason} on failure
%% (including ENOENT when no daemon is listening).

fh2_daemon_socket_path() ->
    case os:getenv("HOME") of
        false -> "/tmp/fh2-control.sock";
        Home -> Home ++ "/.fh2/control.sock"
    end.

fh2_daemon_call(Command) ->
    SockPath = fh2_daemon_socket_path(),
    Opts = [{active, false}, binary, {packet, line}],
    case gen_tcp:connect({local, SockPath}, 0, Opts, 1000) of
        {ok, Sock} ->
            try
                ok = gen_tcp:send(Sock, [Command, $\n]),
                case gen_tcp:recv(Sock, 0, 5000) of
                    {ok, Reply} ->
                        %% Strip trailing newline for cleaner logs.
                        Trimmed = case Reply of
                            <<>> -> Reply;
                            _ ->
                                case binary:last(Reply) of
                                    $\n -> binary:part(Reply, 0, byte_size(Reply) - 1);
                                    _ -> Reply
                                end
                        end,
                        {ok, Trimmed};
                    {error, RecvReason} ->
                        {error, RecvReason}
                end
            after
                gen_tcp:close(Sock)
            end;
        {error, ConnReason} ->
            {error, ConnReason}
    end.
