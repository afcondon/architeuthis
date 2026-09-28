%% @doc OSC for SuperDirt: a message, and a bundle timetagged so SuperDirt plays
%% it at a wall-clock instant rather than on receipt.
%%
%% Shared by the voices that play samples (reef_conspicillum_voice, and
%% reef_balistes_voice for a drum lane routed to a sample voice).
-module(dirt_osc).
-export([encode_msg/2, osc_bundle/2, send_at/3]).

-define(SUPERDIRT_HOST, "127.0.0.1").
-define(SUPERDIRT_PORT, 57120).
-define(NTP_EPOCH_OFFSET, 2208988800).

%% An OSC message. Binaries are strings, floats are 32-bit floats, integers are
%% 32-bit ints: SuperDirt reads `n` and friends as floats, so callers pass floats.
encode_msg(Addr, Args) ->
    AddrBin = pad_string(Addr),
    {Tags, Body} = lists:foldl(fun(A, {T, B}) ->
        case A of
            Bin when is_binary(Bin) -> {[$s | T], <<B/binary, (pad_string(Bin))/binary>>};
            F when is_float(F) -> {[$f | T], <<B/binary, F:32/float>>};
            I when is_integer(I) -> {[$i | T], <<B/binary, I:32/big-signed-integer>>}
        end
    end, {[], <<>>}, Args),
    TagBin = pad_string(list_to_binary([$, | lists:reverse(Tags)])),
    <<AddrBin/binary, TagBin/binary, Body/binary>>.

pad_string(B) ->
    Pad = 4 - (byte_size(B) rem 4),
    <<B/binary, 0:(Pad * 8)>>.

%% Wrap one message in a bundle timetagged at `WhenUnixUs`. SuperDirt schedules
%% the sound at the timetag, so sending ahead lands it sample-accurately rather
%% than late-on-receipt.
osc_bundle(WhenUnixUs, Msg) ->
    Secs = (WhenUnixUs div 1000000) + ?NTP_EPOCH_OFFSET,
    FracUs = WhenUnixUs rem 1000000,
    Frac = (FracUs * 4294967296) div 1000000,
    Timetag = <<Secs:32/big-unsigned-integer, Frac:32/big-unsigned-integer>>,
    Element = <<(byte_size(Msg)):32/big-signed-integer, Msg/binary>>,
    <<"#bundle", 0, Timetag/binary, Element/binary>>.

%% Send `Msg` to SuperDirt on `Sock`, to sound at `WhenUnixUs`.
send_at(Sock, WhenUnixUs, Msg) ->
    gen_udp:send(Sock, ?SUPERDIRT_HOST, ?SUPERDIRT_PORT, osc_bundle(WhenUnixUs, Msg)).
