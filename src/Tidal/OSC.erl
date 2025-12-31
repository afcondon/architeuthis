-module(tidal_oSC@foreign).
-export([startClient/1, stopClient/1, sendNote/3, sendSample/4]).

%% Start UDP socket for OSC
startClient(Config) ->
    fun() ->
        Host = binary_to_list(maps:get(host, Config)),
        Port = maps:get(port, Config),
        {ok, Socket} = gen_udp:open(0, [binary]),
        {Socket, Host, Port}
    end.

%% Close UDP socket
stopClient(Client) ->
    fun() ->
        {Socket, _, _} = Client,
        gen_udp:close(Socket),
        unit
    end.

%% Send a note - simple trigger for testing
%% Format: /note <sample_name> <velocity>
sendNote(Client, Sample, Velocity) ->
    fun() ->
        {Socket, Host, Port} = Client,
        Msg = encode_osc(<<"/note">>, [Sample, Velocity]),
        gen_udp:send(Socket, Host, Port, Msg),
        unit
    end.

%% Send a sample to SuperDirt
%% Format: /dirt/play s <sample> cycle <cycle> delta <delta>
sendSample(Client, Sample, Cycle, Delta) ->
    fun() ->
        {Socket, Host, Port} = Client,
        Msg = encode_superdirt(Sample, Cycle, Delta),
        gen_udp:send(Socket, Host, Port, Msg),
        unit
    end.

%% Encode an OSC message
encode_osc(Address, Args) ->
    PaddedAddr = pad_string(Address),
    {TypeTag, EncodedArgs} = encode_args(Args),
    PaddedTypeTag = pad_string(<<",", TypeTag/binary>>),
    <<PaddedAddr/binary, PaddedTypeTag/binary, EncodedArgs/binary>>.

%% Encode SuperDirt message
%% /dirt/play with key-value pairs
encode_superdirt(Sample, Cycle, Delta) ->
    Address = pad_string(<<"/dirt/play">>),
    %% SuperDirt expects: s <sample> cycle <num> delta <num> cps <num>
    TypeTag = pad_string(<<",sfsfsf">>),  %% string, float, string, float, string, float
    SamplePadded = pad_string(ensure_binary(Sample)),
    CycleKey = pad_string(<<"cycle">>),
    DeltaKey = pad_string(<<"delta">>),
    CycleFloat = <<Cycle:32/float>>,
    DeltaFloat = <<Delta:32/float>>,
    SKey = pad_string(<<"s">>),
    <<Address/binary, TypeTag/binary,
      SKey/binary, SamplePadded/binary,
      CycleKey/binary, CycleFloat/binary,
      DeltaKey/binary, DeltaFloat/binary>>.

%% Encode arguments and build type tag
encode_args(Args) ->
    encode_args(Args, <<>>, <<>>).

encode_args([], TypeTag, Encoded) ->
    {TypeTag, Encoded};
encode_args([Arg | Rest], TypeTag, Encoded) when is_binary(Arg) ->
    PaddedArg = pad_string(Arg),
    encode_args(Rest, <<TypeTag/binary, "s">>, <<Encoded/binary, PaddedArg/binary>>);
encode_args([Arg | Rest], TypeTag, Encoded) when is_integer(Arg) ->
    encode_args(Rest, <<TypeTag/binary, "i">>, <<Encoded/binary, Arg:32/big-signed-integer>>);
encode_args([Arg | Rest], TypeTag, Encoded) when is_float(Arg) ->
    encode_args(Rest, <<TypeTag/binary, "f">>, <<Encoded/binary, Arg:32/float>>).

%% Pad string to 4-byte boundary (OSC requirement)
pad_string(Bin) when is_binary(Bin) ->
    Len = byte_size(Bin) + 1,  %% +1 for null terminator
    Padding = (4 - (Len rem 4)) rem 4,
    <<Bin/binary, 0:8, 0:(Padding*8)>>.

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> list_to_binary(L).
