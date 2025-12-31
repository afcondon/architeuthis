-module(tidal_mIDI@foreign).
-export([listDevices/0, startClient/1, stopClient/1, noteOn/3, noteOff/2, sendDrum/4]).

%% Path to sendmidi binary
-define(SENDMIDI, os:getenv("HOME") ++ "/bin/sendmidi").

%% List available MIDI devices using sendmidi
listDevices() ->
    fun() ->
        Cmd = ?SENDMIDI ++ " list 2>/dev/null || echo 'sendmidi not found'",
        Result = os:cmd(Cmd),
        io:format("MIDI Devices:~n~s~n", [Result]),
        unit
    end.

%% Start MIDI client - open persistent port to sendmidi
startClient(Config) ->
    fun() ->
        Device = binary_to_list(maps:get(device, Config)),
        Channel = maps:get(channel, Config),
        Velocity = maps:get(defaultVelocity, Config),

        %% Open port to sendmidi with -- flag (reads commands from stdin)
        Cmd = lists:flatten(io_lib:format("~s dev \"~s\" --", [?SENDMIDI, Device])),
        Port = open_port({spawn, Cmd}, [stream, {line, 256}, exit_status]),

        %% Return port and config as client handle
        #{port => Port, channel => Channel, default_velocity => Velocity}
    end.

%% Stop MIDI client - close port
stopClient(Client) ->
    fun() ->
        Port = maps:get(port, Client),
        port_close(Port),
        unit
    end.

%% Send command to port
send_cmd(Port, Cmd) ->
    port_command(Port, Cmd ++ "\n").

%% Send note on via port
noteOn(Client, Note, Velocity) ->
    fun() ->
        Port = maps:get(port, Client),
        Channel = maps:get(channel, Client),
        Cmd = io_lib:format("ch ~B on ~B ~B", [Channel, Note, Velocity]),
        send_cmd(Port, lists:flatten(Cmd)),
        unit
    end.

%% Send note off via port
noteOff(Client, Note) ->
    fun() ->
        Port = maps:get(port, Client),
        Channel = maps:get(channel, Client),
        Cmd = io_lib:format("ch ~B off ~B", [Channel, Note]),
        send_cmd(Port, lists:flatten(Cmd)),
        unit
    end.

%% Send drum hit - note on, schedule note off
sendDrum(Client, Note, Velocity, DurationMs) ->
    fun() ->
        Port = maps:get(port, Client),
        Channel = maps:get(channel, Client),

        %% Send note on immediately via port
        OnCmd = io_lib:format("ch ~B on ~B ~B", [Channel, Note, Velocity]),
        send_cmd(Port, lists:flatten(OnCmd)),

        %% Schedule note off in spawned process
        spawn(fun() ->
            timer:sleep(DurationMs),
            OffCmd = io_lib:format("ch ~B off ~B", [Channel, Note]),
            send_cmd(Port, lists:flatten(OffCmd))
        end),
        unit
    end.
