%% Diagnostic-only MIDI module. Real dispatch lives in Tidal.MIDIBridge,
%% which sends OSC to link-spike for kernel-timestamped CoreMIDI
%% delivery. The os:cmd sendmidi path that used to live here was
%% removed because it added 5–30 ms of subprocess-spawn jitter per
%% event — untenable for dense patterns and CC streams.

-module(tidal_mIDI@foreign).
-export([listDevices/0]).

%% Path to sendmidi binary (still used here for the at-startup
%% destination listing — sendmidi list is a quick way to confirm
%% CoreMIDI sees the expected apps. Once link-spike is up, all real
%% dispatch goes through it via OSC).
-define(SENDMIDI, os:getenv("HOME") ++ "/bin/sendmidi").

listDevices() ->
    fun() ->
        Cmd = ?SENDMIDI ++ " list 2>/dev/null || echo 'sendmidi not found'",
        Result = os:cmd(Cmd),
        io:format("MIDI Devices:~n~s~n", [Result]),
        unit
    end.
