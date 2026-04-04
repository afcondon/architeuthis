// Tidal CV Engine for Expert Sleepers ES-9
// Receives OSC from purerl-tidal and outputs DC-coupled CV/Gate signals
//
// Channel mapping (0-indexed):
//   ES-9:  outputs 0-7   (USB audio channels 1-8)
//   ES-5:  outputs 8-15  (ADAT from ES-9)
//   ESX-8GT gates derived from ES-5 expansion header
//
// Voltage scaling (conservative):
//   Audio 0.0 to 0.5 = 0V to +5V (safe for all modules)
//   Full range: -1.0 to +1.0 = -10V to +10V
//
// Usage:
//   1. Boot the server with correct output device
//   2. Run this file to load SynthDefs and OSC responders
//   3. Start purerl-tidal backend
//   4. Send patterns!

(
// Configuration
~tidalOscPort = 57120;  // Port to listen on (sclang default)
~numGateOuts = 4;       // Gates on ES-9 jacks 1-4
~numCVOuts = 4;         // CVs on ES-9 jacks 5-8
~cvLag = 0.005;         // 5ms slew for CV smoothing (avoids clicks)

// ES-9 channel offset: outbus 8 = ES-9 jack 1
~es9Offset = 8;
~gateBusOffset = ~es9Offset;       // Gates start at jack 1 (outbus 8)
~cvBusOffset = ~es9Offset + 4;     // CVs start at jack 5 (outbus 12)

// Voltage scaling - start conservative
~cvScale = 0.5;         // Max 0.5 = +5V output
~cvVoltOffset = 0.0;    // Bipolar: set to 0.25 for 0-5V unipolar

// Storage for synth instances (one per channel)
~cvSynths = Array.newClear(~numCVOuts);
~gateSynths = Array.newClear(~numGateOuts);

// Boot server if needed
s.waitForBoot {

    // =========================================
    // SynthDefs
    // =========================================

    // CV output with slew/lag for smooth transitions
    // Uses K2A to convert control rate to audio rate (DC.ar doesn't track control changes)
    SynthDef(\tidalCV, { |out=0, val=0, lag=0.005|
        var sig = Lag.kr(val, lag);
        Out.ar(out, K2A.ar(sig));
    }).add;

    // Simple gate output (0 or 1, scaled to 0.5 for ~5V)
    // Uses K2A to convert control rate to audio rate
    SynthDef(\tidalGate, { |out=0, gate=0|
        Out.ar(out, K2A.ar(gate) * 0.5);
    }).add;

    // LFO for testing (not controlled via OSC, just for verification)
    SynthDef(\testLFO, { |out=0, freq=1, amp=0.25, offset=0.25|
        Out.ar(out, SinOsc.ar(freq, 0, amp, offset));
    }).add;

    s.sync;

    "SynthDefs loaded.".postln;

    // =========================================
    // Initialize persistent synths for each channel
    // =========================================

    // Create Gate synths on ES-9 jacks 1-4
    ~numGateOuts.do { |i|
        ~gateSynths[i] = Synth(\tidalGate, [
            \out, ~gateBusOffset + i,
            \gate, 0
        ]);
    };

    // Create CV synths on ES-9 jacks 5-8
    ~numCVOuts.do { |i|
        ~cvSynths[i] = Synth(\tidalCV, [
            \out, ~cvBusOffset + i,
            \val, 0,
            \lag, ~cvLag
        ]);
    };

    "Persistent synths created:".postln;
    ("  Gate channels 0-" ++ (~numGateOuts - 1) ++ " → ES-9 jacks 1-" ++ ~numGateOuts ++ " (outbus " ++ ~gateBusOffset ++ "-" ++ (~gateBusOffset + ~numGateOuts - 1) ++ ")").postln;
    ("  CV channels 0-" ++ (~numCVOuts - 1) ++ " → ES-9 jacks " ++ (~numGateOuts + 1) ++ "-" ++ (~numGateOuts + ~numCVOuts) ++ " (outbus " ++ ~cvBusOffset ++ "-" ++ (~cvBusOffset + ~numCVOuts - 1) ++ ")").postln;

    // =========================================
    // OSC Responders
    // =========================================

    // Remove old responders if reloading
    OSCdef(\tidalCV).free;
    OSCdef(\tidalGate).free;
    OSCdef(\tidalGateTrig).free;

    // /tidal/cv <channel> <value>
    // value: 0.0 to 1.0 (scaled internally)
    OSCdef(\tidalCV, { |msg, time, addr, recvPort|
        var chan = msg[1].asInteger;
        var val = msg[2].asFloat;
        var scaled = (val * ~cvScale) + ~cvVoltOffset;

        if(chan < ~numCVOuts) {
            ~cvSynths[chan].set(\val, scaled);
            // Uncomment for debugging:
            // ["CV", chan, val, "->", scaled].postln;
        } {
            ("CV channel out of range: " ++ chan).warn;
        };
    }, '/tidal/cv');

    // /tidal/gate <channel> <state>
    // state: 0 or 1
    OSCdef(\tidalGate, { |msg, time, addr, recvPort|
        var chan = msg[1].asInteger;
        var state = msg[2].asInteger;

        if(chan < ~numGateOuts) {
            ~gateSynths[chan].set(\gate, state);
            // Uncomment for debugging:
            // ["Gate", chan, state].postln;
        } {
            ("Gate channel out of range: " ++ chan).warn;
        };
    }, '/tidal/gate');

    // /tidal/gate/trig <channel> <duration_ms>
    // Trigger gate high, then low after duration
    OSCdef(\tidalGateTrig, { |msg, time, addr, recvPort|
        var chan = msg[1].asInteger;
        var durMs = msg[2].asFloat;

        if(chan < ~numGateOuts) {
            ~gateSynths[chan].set(\gate, 1);
            SystemClock.sched(durMs / 1000, {
                ~gateSynths[chan].set(\gate, 0);
                nil;
            });
        };
    }, '/tidal/gate/trig');

    // /tidal/cv/slew <channel> <value> <lag_time>
    // Set CV with custom slew time
    OSCdef(\tidalCVSlew, { |msg, time, addr, recvPort|
        var chan = msg[1].asInteger;
        var val = msg[2].asFloat;
        var lag = msg[3].asFloat;
        var scaled = (val * ~cvScale) + ~cvVoltOffset;

        if(chan < ~numCVOuts) {
            ~cvSynths[chan].set(\val, scaled, \lag, lag);
        };
    }, '/tidal/cv/slew');

    "OSC responders active on port %:".format(~tidalOscPort).postln;
    "  /tidal/cv <chan> <val>           - Set CV (0.0-1.0)".postln;
    "  /tidal/cv/slew <chan> <val> <lag> - Set CV with custom slew".postln;
    "  /tidal/gate <chan> <0|1>         - Set gate state".postln;
    "  /tidal/gate/trig <chan> <ms>     - Trigger gate for duration".postln;

    // =========================================
    // Test/Debug Functions
    // =========================================

    // Test a CV channel
    ~testCV = { |chan=0, val=0.5|
        ("Testing CV " ++ chan ++ " = " ++ val).postln;
        ~cvSynths[chan].set(\val, val * ~cvScale + ~cvVoltOffset);
    };

    // Test a gate channel
    ~testGate = { |chan=0, state=1|
        ("Testing Gate " ++ chan ++ " = " ++ state).postln;
        ~gateSynths[chan].set(\gate, state);
    };

    // Ramp CV for testing
    ~rampCV = { |chan=0, from=0, to=1, dur=2|
        ("Ramping CV " ++ chan ++ " from " ++ from ++ " to " ++ to).postln;
        {
            var env = EnvGen.kr(Env([from, to], [dur]), doneAction: 2);
            ~cvSynths[chan].set(\val, env * ~cvScale + ~cvVoltOffset);
        }.play;
    };

    // Test LFO on an ES-9 output (for scope/verification)
    ~testLFO = { |chan=0, freq=1|
        ("LFO on ES-9 jack " ++ (chan + 1) ++ " (outbus " ++ (~es9Offset + chan) ++ ") at " ++ freq ++ "Hz").postln;
        Synth(\testLFO, [\out, ~es9Offset + chan, \freq, freq, \amp, 0.25, \offset, 0.25]);
    };

    // Zero all outputs
    ~zeroAll = {
        "Zeroing all outputs...".postln;
        ~numCVOuts.do { |i| ~cvSynths[i].set(\val, 0) };
        ~numGateOuts.do { |i| ~gateSynths[i].set(\gate, 0) };
    };

    // Print current config
    ~printConfig = {
        "".postln;
        "=== Tidal CV Engine Config ===".postln;
        ("ES-9 offset: outbus " ++ ~es9Offset ++ " = ES-9 jack 1").postln;
        ("CV Scale: " ++ ~cvScale ++ " (max " ++ (~cvScale * 10) ++ "V)").postln;
        ("CV Volt Offset: " ++ ~cvVoltOffset).postln;
        ("CV Lag: " ++ (~cvLag * 1000) ++ "ms").postln;
        ("Gate Channels: 0-" ++ (~numGateOuts - 1) ++ " → ES-9 jacks 1-" ++ ~numGateOuts).postln;
        ("CV Channels: 0-" ++ (~numCVOuts - 1) ++ " → ES-9 jacks " ++ (~numGateOuts + 1) ++ "-" ++ (~numGateOuts + ~numCVOuts)).postln;
        "".postln;
    };

    "".postln;
    "=== Tidal CV Engine Ready ===".postln;
    "Test functions:".postln;
    "  ~testCV.(chan, val)     - Test CV output".postln;
    "  ~testGate.(chan, state) - Test gate output".postln;
    "  ~testLFO.(chan, freq)   - LFO for scope testing".postln;
    "  ~rampCV.(chan, from, to, dur) - Ramp CV".postln;
    "  ~zeroAll.()             - Zero all outputs".postln;
    "  ~printConfig.()         - Show config".postln;
    "".postln;
};
)

// =========================================
// Quick Tests (run manually in SC)
// =========================================

// Test CV on channel 0 (half voltage)
// ~testCV.(0, 0.5);

// Test gate on channel 0
// ~testGate.(0, 1);
// ~testGate.(0, 0);

// LFO on channel 0 for scope
// ~testLFO.(0, 2);

// Zero everything
// ~zeroAll.();

// Check your audio device
// ServerOptions.devices;
// s.options.outDevice;
