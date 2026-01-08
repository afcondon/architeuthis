-module(tidal_mIDI@foreign).
-export([listDevices/0, startClient/1, stopClient/1, noteOn/3, noteOff/2, sendDrum/4, scheduleDrum/5]).

%% Path to sendmidi binary
-define(SENDMIDI, os:getenv("HOME") ++ "/bin/sendmidi").

%% ETS table for storing the current port (allows restart on failure)
-define(PORT_TABLE, midi_port_table).

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
        #{port => Port, channel => Channel, default_velocity => Velocity, device => Device}
    end.

%% Stop MIDI client - close port
stopClient(Client) ->
    fun() ->
        Port = maps:get(port, Client),
        port_close(Port),
        unit
    end.

%% Send command to port (with error handling for closed ports)
send_cmd(Port, Cmd) ->
    io:format("MIDI> ~s~n", [Cmd]),
    try
        port_command(Port, Cmd ++ "\n")
    catch
        error:badarg ->
            io:format("MIDI> ERROR: Port closed, command dropped: ~s~n", [Cmd]),
            false
    end.

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
%% Uses persistent port to avoid spawning external processes per note
sendDrum(Client, Note, Velocity, DurationMs) ->
    fun() ->
        Port = maps:get(port, Client),
        Channel = maps:get(channel, Client),

        %% Send note on immediately via persistent port
        OnCmd = io_lib:format("ch ~B on ~B ~B", [Channel, Note, Velocity]),
        send_cmd(Port, lists:flatten(OnCmd)),

        %% Spawn lightweight process to schedule note off (no external process)
        spawn(fun() ->
            timer:sleep(DurationMs),
            OffCmd = io_lib:format("ch ~B off ~B", [Channel, Note]),
            send_cmd(Port, lists:flatten(OffCmd))
        end),
        unit
    end.

%% Schedule drum hit after a delay (in milliseconds)
%% Used by scheduler to trigger notes at the correct time within a cycle
%% Uses one-shot sendmidi calls to avoid port lifetime issues
scheduleDrum(Client, Note, Velocity, DurationMs, DelayMs) ->
    fun() ->
        Device = maps:get(device, Client),
        Channel = maps:get(channel, Client),

        %% Spawn process that waits then plays the note via one-shot sendmidi
        spawn(fun() ->
            %% Wait until the note should play
            timer:sleep(DelayMs),

            %% Send note on via one-shot command
            OnCmd = lists:flatten(io_lib:format(
                "~s dev \"~s\" ch ~B on ~B ~B",
                [?SENDMIDI, Device, Channel, Note, Velocity])),
            io:format("MIDI> ~s~n", [OnCmd]),
            os:cmd(OnCmd),

            %% Wait note duration then send note off
            timer:sleep(DurationMs),
            OffCmd = lists:flatten(io_lib:format(
                "~s dev \"~s\" ch ~B off ~B",
                [?SENDMIDI, Device, Channel, Note])),
            io:format("MIDI> ~s~n", [OffCmd]),
            os:cmd(OffCmd)
        end),
        unit
    end.
