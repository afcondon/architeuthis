# CV Output Setup for Expert Sleepers ES-9

> **Superseded.** The SuperCollider layer documented here has been replaced
> by a sibling Rust CV router living in its own repo at
> `~/work/afc-work/cv-router/` (Marginalia project 185). It speaks the same
> OSC protocol on :57120 and opens CoreAudio on the ES-9 directly via `cpal`,
> with no SuperCollider startup ceremony.
>
> The sibling repos in the post-2026-04-25 constellation:
>
> - `cv-router` (MIT, sibling repo) — Rust audio router for ES-9
> - `link-spike` (GPLv2+, sibling repo) — Ableton Link client; sends OSC to cv-router
> - `es9-config` (MIT, sibling repo) — typed PureScript model + DSL for ES-9 config
>
> This file is kept as a reference for the SuperCollider path during the
> migration period; the canonical CV/Gate runtime is now `cv-router`.

This document captures all the nitty-gritty details for getting CV/Gate output from Tidal patterns to a modular synth via the Expert Sleepers ES-9.

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────┐
│  Tidal Pattern  │     │  Erlang/BEAM    │     │  SuperCollider  │     │    ES-9     │
│  "bd sn hh cp"  │────▶│  MIDIScheduler  │────▶│  CV Engine      │────▶│  Modular    │
│                 │     │  OSC Client     │     │  OSC Responders │     │  Gates/CV   │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────┘
        WebSocket             UDP:57120              Audio Out
```

## Critical Discoveries

### 1. ES-9 Channel Mapping

The ES-9's USB audio channels are NOT 1:1 with the panel jacks:

| SuperCollider outbus | ES-9 Function |
|---------------------|---------------|
| 0-1 | Headphone outputs |
| 2-7 | Unknown/unused |
| **8** | **Jack 1 (first modular output)** |
| 9 | Jack 2 |
| 10 | Jack 3 |
| ... | ... |
| 15 | Jack 8 |

**Key insight**: `outbus: 8` = ES-9 jack 1. This offset varies by system - yours may differ!

### 2. SuperCollider SynthDef Fix

`DC.ar()` does NOT track control-rate changes. You MUST use `K2A.ar()`:

```supercollider
// WRONG - won't respond to .set(\val, x)
SynthDef(\broken, { |out=0, val=0|
    Out.ar(out, DC.ar(val));
}).add;

// CORRECT - responds to .set(\val, x)
SynthDef(\working, { |out=0, val=0|
    Out.ar(out, K2A.ar(val));
}).add;
```

### 3. Don't Overlap CV and Gate Synths

If you create both a CV synth and a Gate synth on the same output bus, they interfere. The CV engine splits them:
- **Gates**: Channels 0-3 → ES-9 jacks 1-4 (outbus 8-11)
- **CV**: Channels 0-3 → ES-9 jacks 5-8 (outbus 12-15)

### 4. Erlang Build Requires `erlc`

The Makefile now includes this, but if builds seem stale:

```bash
cd /Users/afc/work/afc-work/purescript-ports/purerl-tidal
find output-erl -name "*.erl" -exec erlc -disable-feature maybe_expr -o ebin {} \;
```

### 5. rebar3 Shell Code Path

The purerl-compiled beam files are in `ebin/` but rebar3 shell doesn't automatically include it:

```erlang
code:add_path("/Users/afc/work/afc-work/purescript-ports/purerl-tidal/ebin").
```

---

## Complete Startup Procedure

### Step 1: Build

```bash
cd /Users/afc/work/afc-work/purescript-ports/purerl-tidal
make
```

### Step 2: Start SuperCollider

Open SuperCollider and run (BEFORE booting server):

```supercollider
// Configure for ES-9 - run this BEFORE s.boot
s.options.outDevice = "ES-9";
s.options.inDevice = "ES-9";
s.options.numOutputBusChannels = 16;
s.options.numInputBusChannels = 16;
s.options.sampleRate = 48000;
s.boot;
```

Verify:
```supercollider
s.options.outDevice;            // "ES-9"
s.options.numOutputBusChannels; // 16
```

### Step 3: Load CV Engine

Open and evaluate (Cmd+Enter on entire file):
```
/Users/afc/work/afc-work/purescript-ports/purerl-tidal/supercollider/tidal-cv-engine.scd
```

You should see:
```
Persistent synths created:
  Gate channels 0-3 → ES-9 jacks 1-4 (outbus 8-11)
  CV channels 0-3 → ES-9 jacks 5-8 (outbus 12-15)
=== Tidal CV Engine Ready ===
```

Test it works:
```supercollider
~testGate.(0, 1);  // Jack 1 LED should light
~testGate.(0, 0);  // Jack 1 LED should turn off
~testCV.(0, 0.5);  // Jack 5 should show half voltage
```

### Step 4: Start Erlang Server

```bash
# Kill any existing process on port 8080
lsof -ti:8080 | xargs kill -9 2>/dev/null

# Start rebar3 shell
cd /Users/afc/work/afc-work/purescript-ports/purerl-tidal
rebar3 shell
```

In Erlang shell:
```erlang
code:add_path("/Users/afc/work/afc-work/purescript-ports/purerl-tidal/ebin").
('main@ps':main())().
```

You should see:
```
MIDI Scheduler started
Device: IAC Driver Tidal
BPM: 120
Pattern: ~
Gate output: enabled (OSC 127.0.0.1:57120)
```

### Step 5: Send Patterns

```bash
wscat -c ws://localhost:8080/ws
```

Then type patterns:
```
bd sn hh cp
bd*4
bd(3,8)
[bd sn] hh*2
```

Watch ES-9 jack 1 flash with each drum hit!

---

## Troubleshooting

### No output on ES-9 jacks

1. Check SuperCollider is using ES-9: `s.options.outDevice`
2. Check channel count: `s.options.numOutputBusChannels` (should be 16)
3. Test direct output: `{ DC.ar(0.5) }.play(outbus: 8);`
4. If that works but CV engine doesn't, reload the .scd file

### Gate output not appearing in Erlang console

1. Check for "Gate output: enabled" at startup
2. If missing, rebuild: `make`
3. Check beam files are fresh: `ls -la ebin/main@ps.beam`

### "undefined function" in Erlang

Add the code path:
```erlang
code:add_path("/Users/afc/work/afc-work/purescript-ports/purerl-tidal/ebin").
```

### Port 8080 already in use

```bash
lsof -ti:8080 | xargs kill -9
```

---

## File Locations

| File | Purpose |
|------|---------|
| `supercollider/tidal-cv-engine.scd` | SuperCollider CV/Gate engine |
| `src/Tidal/OSC.purs` | PureScript OSC bindings |
| `src/Tidal/OSC.erl` | Erlang OSC FFI (sendCV, sendGate, etc.) |
| `src/Tidal/MIDIScheduler.purs` | Main scheduler with gate integration |
| `src/Main.purs` | Entry point with gate config |

---

## Configuration

In `src/Main.purs`, the gate config:

```purescript
gateConfig = defaultGateConfig
  { enabled = true
  , oscHost = "127.0.0.1"
  , oscPort = 57120       -- sclang default
  , channelOffset = 0     -- ch10 -> gate 0
  , gateDuration = 50.0   -- 50ms pulse
  }
```

In `supercollider/tidal-cv-engine.scd`:

```supercollider
~es9Offset = 8;           // outbus 8 = ES-9 jack 1
~gateBusOffset = 8;       // Gates on jacks 1-4
~cvBusOffset = 12;        // CVs on jacks 5-8
~cvScale = 0.5;           // Max +5V (conservative)
```

---

## Next Steps

- [ ] CV patterns for pitch control (Pattern Number)
- [ ] Multiple tracks on different gate channels
- [ ] ES-5 ADAT outputs for more gates
- [ ] ESX-8GT integration for dedicated gate outputs

---

*Last updated: 2026-01-12*
*Tested with: SuperCollider 3.x, Erlang/OTP 28, ES-9 firmware latest*
