# Purerl Tidal Backend Architecture

An Erlang/OTP backend for TidalCycles that receives patterns via WebSocket and outputs MIDI.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    FRONTEND (Browser)                        │
│         purescript-psd3-tidal - Pattern Editor               │
└─────────────────────────────────────────────────│───────────┘
                                                  │
                                          ws://localhost:8080/ws
                                                  │
                                                  ▼
┌─────────────────────────────────────────────────────────────┐
│                    BACKEND (Erlang/BEAM)                     │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │  WebSocket   │    │   Pattern    │    │    MIDI      │   │
│  │   Server     │───►│   Parser &   │───►│  Scheduler   │   │
│  │  (Cowboy)    │    │  Evaluator   │    │              │   │
│  └──────────────┘    └──────────────┘    └──────────────┘   │
│                                                 │            │
│                                                 ▼            │
│                                          ┌──────────────┐   │
│                                          │   sendmidi   │   │
│                                          │  (CLI tool)  │   │
│                                          └──────────────┘   │
└─────────────────────────────────────────────────│───────────┘
                                                  │
                                                  ▼
                                          MIDI Hardware
                                    (DAW, Synth, Drum Machine)
```

## Backend Responsibilities

1. **WebSocket Server** - Accept connections from pattern editors
2. **Pattern Parsing** - Parse Tidal mini-notation to AST
3. **Pattern Evaluation** - AST to executable Pattern (query function)
4. **MIDI Scheduling** - Real-time scheduling with precise timing
5. **MIDI Output** - Send notes via `sendmidi` CLI tool

## Module Structure

```
src/
├── Main.purs                   # Entry point, starts all services
└── Tidal/
    ├── Core/
    │   └── Types.purs          # Time (Rational), basic types
    ├── AST/
    │   └── Types.purs          # TPat - parsed AST type
    ├── Parse/
    │   ├── Parser.purs         # Mini-notation parser
    │   └── Combinators.purs    # Parser implementation
    ├── Pattern/
    │   ├── Types.purs          # Pattern, Event, Arc, State
    │   └── Core.purs           # Combinators: fast, slow, cat, stack
    ├── Eval/
    │   └── Interpret.purs      # TPat → Pattern evaluation
    └── Output/
        ├── WebSocket.purs      # Cowboy WebSocket handler
        ├── Scheduler.purs      # Real-time MIDI scheduler
        └── Midi.purs           # sendmidi FFI bindings
```

## Key Components

### WebSocket Server (Cowboy)

```erlang
% Listens on ws://localhost:8080/ws
% Receives: "bd sn [hh hh] cp"
% Responds: "OK: bd sn [hh hh] cp" or "ERROR: ..."
```

### Pattern Parser

Parses Tidal mini-notation:
- Sequences: `bd sn cp hh`
- Rests: `bd ~ sn ~`
- Parallel: `[bd, sn, hh]`
- Fast/slow: `bd*4`, `sn/2`
- Euclidean: `bd(3,8)`
- Alternation: `<bd sn cp>`

### MIDI Scheduler

Erlang process that:
1. Maintains current BPM and pattern
2. Ticks every 25ms
3. Queries pattern for upcoming events
4. Schedules MIDI via `sendmidi`

### Note Mapping

| Pattern | MIDI Note | Sound |
|---------|-----------|-------|
| bd | 36 | Kick |
| sn | 38 | Snare |
| hh | 42 | Hi-hat |
| cp | 39 | Clap |
| rim | 37 | Rim |
| 60 | 60 | Middle C |

## Running

```bash
cd purerl-tidal
ERL_LIBS="_build/default/lib" spago run
```

Output:
```
Tidal on the BEAM!
===================

=== MIDI Devices ===
MIDI Devices:
IAC Driver Tidal
...

=== WebSocket → MIDI Server ===
Starting WebSocket server on port 8080
Connect to ws://localhost:8080/ws
MIDI Scheduler started
Device: IAC Driver Tidal
BPM: 120
```

## Configuration

Default settings in `Main.purs`:
- **Port**: 8080
- **MIDI Device**: "IAC Driver Tidal"
- **BPM**: 120 (configurable via frontend)

## Dependencies

### PureScript (compiled to Erlang via purerl)
- `purescript-rationals` - Exact time representation
- `purescript-parsing` - Parser combinators

### Erlang
- `cowboy` - HTTP/WebSocket server
- `ranch` - TCP acceptor pool

### System
- `sendmidi` - CLI tool for MIDI output (install via Homebrew)

## Why Erlang?

1. **No browser timing issues** - BEAM scheduler is predictable
2. **No background tab throttling** - Runs as native process
3. **OTP supervision** - Fault-tolerant process management
4. **Low latency** - Direct OS access for MIDI

## WebSocket Protocol

### From Frontend
```
bd sn [hh hh] cp          # Pattern string (mini-notation)
~                         # Silence
```

### To Frontend
```
OK: bd sn [hh hh] cp      # Pattern accepted
ERROR: Parse error at...   # Parse/validation error
```

## Future Improvements

1. **BPM sync** - Accept BPM changes from frontend
2. **Multi-track** - Independent patterns per MIDI channel
3. **OSC output** - Support SuperCollider/SuperDirt
4. **Pattern storage** - Save/load pattern sets
