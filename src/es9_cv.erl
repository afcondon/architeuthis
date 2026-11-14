%% @doc es9_cv — send CV to the ES-9, through es9-daemon's OSC (`/cv`,
%% `/cv/slew`, `/cv/trig/at`).
%%
%% Only the sending is here. Turning an intended pitch into the voltage that
%% produces it on a particular oscillator is `Reef.Calibration` (reef, compiled
%% to this node and to the browser), and it is held to DeepStar's realiser by
%% reef/conformance/vectors/calibration.json, which test/reef_calibration_tests
%% replays here. This module once had its own realiser and its own reader of
%% the calibration tables in Amphora; nothing called either, and both went on
%% 2026-11-14.
-module(es9_cv).
-export([send_cv/3, send_slew/4, send_trig_at/5]).

%% es9-daemon's OSC intake (moved 57120 -> 57130 in workstream C; see the
%% atlantis compose fixture and CALIBRATION.md).
-define(ES9_IP,   {127,0,0,1}).
-define(ES9_PORT, 57130).

%% =========================================================================
%% Emit
%% =========================================================================

%% The packets are laid out by rig_wire, from the declared descriptions
%% (binnacle/conformance/ES9-OSC.md). A value that breaks a declared rule
%% (a bus above 15, a negative time) is counted there and not sent.

%% Send `/cv <bus> <value>` to es9-daemon over the given (already open,
%% unbound) UDP socket. `Value` is volts/10 in ±1.0 → ±10 V units.
send_cv(Sock, Bus, Value) ->
    rig_wire:send(Sock, ?ES9_IP, ?ES9_PORT, rig_wire:cv(Bus, Value)).

%% Send `/cv/slew <bus> <value> <lag_sec>`: move the bus to `value` through
%% es9-daemon's first-order smoother, whose lag (a time constant, seconds)
%% stays on the bus until set again. A slide is a slew with a long lag; a plain
%% note restores the short one (Reef.Articulation).
send_slew(Sock, Bus, Value, LagSec) ->
    rig_wire:send(Sock, ?ES9_IP, ?ES9_PORT, rig_wire:cv_slew(Bus, Value, LagSec)).

%% Send `/cv/trig/at <bus> <value> <dur_ms> <delay_ms>` — a SAMPLE-ACCURATE
%% scheduled trigger (the note-gate facet). The daemon raises `bus` to `value`
%% for `dur_ms`, firing exactly `delay_ms` from receipt (applied on the matching
%% audio frame — no audio-buffer jitter). Use it for on-beat gates: send once at
%% schedule time with delay_ms = (beat_wall_us - now_us)/1000, and the daemon
%% nails the transient. `Value` is volts/10 (a +5 V trigger => 0.5). `send_cv`'s
%% `/cv` sibling has no scheduled form, so pitch DC uses BEAM-side send_after
%% while the timing-critical gate rides this daemon primitive.
send_trig_at(Sock, Bus, Value, DurMs, DelayMs) ->
    rig_wire:send(Sock, ?ES9_IP, ?ES9_PORT, rig_wire:cv_trig_at(Bus, Value, DurMs, DelayMs)).
