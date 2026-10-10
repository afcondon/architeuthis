%% @doc es9_cv — emit pitch CV to the ES-9 (via es9-daemon's OSC `/cv`), with a
%% per-VCO calibration table applied so an intended MIDI note lands in tune.
%%
%% This is the BEAM side of the "calibrate the output, not the module" pipeline
%% proven in the 2026-07-11 session (see deepstar/docs/CALIBRATION.md). A
%% calibration table is a monotonic curve of {volts, measured_hz} points, swept
%% by the DeepStar probe and stored in Amphora (collection `vco-calibrations`,
%% one label per VCO/voice). The REALISER inverts that curve: given a target Hz,
%% interpolate (in log-Hz) the volts that will produce it, then send
%% `/cv <bus> <volts/10>` (es9-daemon maps ±1.0 → ±10 V).
%%
%% All hand-written Erlang (not purs-backend-erl output): `math:pow` is the BIF,
%% so the purerl `Data.Number.pow` gap ([[reference_purerl_math_pow_and_xor]])
%% does not apply here. JSON via the OTP 27+ `json` module; HTTP via raw gen_tcp
%% (localhost, tiny bodies) to avoid pulling in inets — keeps the runtime lean
%% ([[feedback_minimize_system_complexity]]).
-module(es9_cv).
-export([send_cv/3, send_slew/4, send_trig_at/5, encode_cv/2, encode_trig_at/4,
         realise/2, note_to_hz/1, fetch_tables/1]).

%% es9-daemon's OSC intake (moved 57120 -> 57130 in workstream C; see the
%% atlantis compose fixture and CALIBRATION.md).
-define(ES9_IP,   {127,0,0,1}).
-define(ES9_PORT, 57130).

%% Amphora content store (Bosun-Atlantis member, no auth).
-define(AMPHORA_IP,   {127,0,0,1}).
-define(AMPHORA_PORT, 3024).

%% =========================================================================
%% Emit
%% =========================================================================

%% Send one `/cv <bus:int> <value:float>` to es9-daemon over the given (already
%% open, unbound) UDP socket. `Value` is volts/10 in ±1.0 → ±10 V units.
send_cv(Sock, Bus, Value) ->
    gen_udp:send(Sock, ?ES9_IP, ?ES9_PORT, encode_cv(Bus, float(Value))).

%% Build the OSC message for `/cv` — address, ",if" type-tag, then an int32 bus
%% and a float32 value, each big-endian and 4-byte aligned.
encode_cv(Bus, Value) ->
    Addr = pad_string(<<"/cv">>),
    Tags = pad_string(<<",if">>),
    Body = <<Bus:32/big-signed-integer, (float(Value)):32/float-big>>,
    <<Addr/binary, Tags/binary, Body/binary>>.

%% Send `/cv/slew <bus> <value> <lag_sec>`: move the bus to `value` through
%% es9-daemon's first-order smoother, whose lag (a time constant, seconds)
%% stays on the bus until set again. A slide is a slew with a long lag; a plain
%% note restores the short one (Reef.Articulation).
send_slew(Sock, Bus, Value, LagSec) ->
    Addr = pad_string(<<"/cv/slew">>),
    Tags = pad_string(<<",iff">>),
    Body = <<Bus:32/big-signed-integer, (float(Value)):32/float-big, (float(LagSec)):32/float-big>>,
    gen_udp:send(Sock, ?ES9_IP, ?ES9_PORT, <<Addr/binary, Tags/binary, Body/binary>>).

%% Send `/cv/trig/at <bus> <value> <dur_ms> <delay_ms>` — a SAMPLE-ACCURATE
%% scheduled trigger (the note-gate facet). The daemon raises `bus` to `value`
%% for `dur_ms`, firing exactly `delay_ms` from receipt (applied on the matching
%% audio frame — no audio-buffer jitter). Use it for on-beat gates: send once at
%% schedule time with delay_ms = (beat_wall_us - now_us)/1000, and the daemon
%% nails the transient. `Value` is volts/10 (a +5 V trigger => 0.5). `send_cv`'s
%% `/cv` sibling has no scheduled form, so pitch DC uses BEAM-side send_after
%% while the timing-critical gate rides this daemon primitive.
send_trig_at(Sock, Bus, Value, DurMs, DelayMs) ->
    gen_udp:send(Sock, ?ES9_IP, ?ES9_PORT,
                 encode_trig_at(Bus, float(Value), float(DurMs), float(DelayMs))).

%% OSC for `/cv/trig/at` — ",ifff" tag: int32 bus, then three float32s
%% (value, dur_ms, delay_ms), big-endian, 4-byte aligned.
encode_trig_at(Bus, Value, DurMs, DelayMs) ->
    Addr = pad_string(<<"/cv/trig/at">>),
    Tags = pad_string(<<",ifff">>),
    Body = <<Bus:32/big-signed-integer,
             (float(Value)):32/float-big,
             (float(DurMs)):32/float-big,
             (float(DelayMs)):32/float-big>>,
    <<Addr/binary, Tags/binary, Body/binary>>.

%% =========================================================================
%% Realiser — invert a calibration table (target Hz -> volts)
%% =========================================================================

%% Given a table of {volts, measured_hz} points (monotonic: more volts = higher
%% Hz) and a target frequency, return the volts that produce it. Interpolates in
%% log-Hz between the bracketing points; clamps to the table's endpoints outside
%% its swept range. Mirrors play.py's `realise()` exactly.
realise(Points0, TargetHz) ->
    Points = lists:keysort(1, Points0),
    {VFirst, HFirst} = hd(Points),
    {VLast,  HLast}  = lists:last(Points),
    if
        TargetHz =< HFirst -> VFirst;
        TargetHz >= HLast  -> VLast;
        true               -> interp(Points, TargetHz)
    end.

interp([{V0, H0}, {V1, H1} | _], Hz) when H0 =< Hz, Hz =< H1 ->
    F = (math:log(Hz) - math:log(H0)) / (math:log(H1) - math:log(H0)),
    V0 + F * (V1 - V0);
interp([{V, _}], _Hz)  -> V;
interp([_ | Rest], Hz) -> interp(Rest, Hz).

%% Equal-tempered A440 MIDI -> Hz. `math:pow` is the Erlang BIF.
note_to_hz(Note) ->
    440.0 * math:pow(2.0, (Note - 69) / 12.0).

%% =========================================================================
%% Amphora fetch — load calibration tables by label
%% =========================================================================

%% Fetch the `vco-calibrations` favorites from Amphora and return, for each
%% requested label (in order), its list of {volts, hz} points — or `undefined`
%% if that label isn't present. Read once at voice start; never on the hot path.
fetch_tables(Labels) ->
    case http_get_json(<<"/favorites?collection=vco-calibrations">>) of
        {ok, Favs} when is_list(Favs) ->
            ByLabel =
                lists:foldl(
                  fun(#{<<"contentHash">> := Hash}, Acc) ->
                          case fetch_one(Hash) of
                              {ok, Label, Points} -> Acc#{Label => Points};
                              _                   -> Acc
                          end;
                     (_, Acc) -> Acc
                  end, #{}, Favs),
            {ok, [maps:get(L, ByLabel, undefined) || L <- Labels]};
        {ok, _}      -> {error, unexpected_favorites};
        {error, Why} -> {error, Why}
    end.

fetch_one(Hash) ->
    case http_get_json(<<"/content/", Hash/binary>>) of
        {ok, #{<<"payload">> := Payload}} ->
            case json:decode(ensure_bin(Payload)) of
                #{<<"label">> := Label, <<"points">> := Pts} when is_list(Pts) ->
                    Points = [ {to_float(maps:get(<<"volts">>, Pt)),
                                to_float(maps:get(<<"hz">>, Pt))}
                               || Pt <- Pts, is_map(Pt) ],
                    {ok, Label, Points};
                _ -> error
            end;
        _ -> error
    end.

%% =========================================================================
%% Tiny HTTP/1.0 GET (localhost only) + helpers
%% =========================================================================

http_get_json(Path) ->
    Req = [<<"GET ">>, ensure_bin(Path),
           <<" HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n">>],
    case gen_tcp:connect(?AMPHORA_IP, ?AMPHORA_PORT,
                         [binary, {active, false}], 2000) of
        {ok, Sock} ->
            ok = gen_tcp:send(Sock, Req),
            Resp = recv_all(Sock, <<>>),
            gen_tcp:close(Sock),
            case binary:split(Resp, <<"\r\n\r\n">>) of
                [_Hdr, Body] when byte_size(Body) > 0 ->
                    try {ok, json:decode(Body)}
                    catch _:E -> {error, {json, E}} end;
                _ -> {error, no_body}
            end;
        {error, R} -> {error, {connect, R}}
    end.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 3000) of
        {ok, Data}      -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, _}      -> Acc
    end.

to_float(X) when is_integer(X) -> float(X);
to_float(X) when is_float(X)   -> X.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L)   -> iolist_to_binary(L).

%% Pad an OSC string to a 4-byte boundary with at least one trailing null.
pad_string(Bin) when is_binary(Bin) ->
    Len = byte_size(Bin) + 1,
    Padding = (4 - (Len rem 4)) rem 4,
    <<Bin/binary, 0:8, 0:(Padding * 8)>>.
