# Architeuthis

*Formerly purerl-tidal (renamed 2026-10-02).* The giant squid: the rig's deep
engine, many arms (a supervised voice per machine), drawn as the kraken on the
Triggerfish chart. Inside, the OTP application is still `purerl_tidal`; the
internal names follow later.

Erlang/OTP backend for TidalCycles - receives patterns via WebSocket, outputs MIDI.

## Overview

This is the backend component of a two-part system:
- **purerl-tidal** (this repo) - Erlang backend, handles MIDI output
- **purescript-psd3-tidal** - Browser frontend, pattern visualization & editing

Built with [purerl](https://github.com/purerl/purerl) (PureScript → Erlang compiler).

## Quick Start

```bash
# Install sendmidi (required for MIDI output)
brew install gbevin/tools/sendmidi

# Fetch Erlang dependencies (first time only)
rebar3 get-deps && rebar3 compile

# Build and run
make run
```

## Build System

The project uses a Makefile to orchestrate the multi-stage build:

```bash
make              # Full build (spago → purerl → erlc)
make test         # Run the test suite (77 tests)
make run          # Start the WebSocket/MIDI server
make clean        # Clean PureScript output
make distclean    # Clean everything including deps
make help         # Show all targets
```

### Build Pipeline

1. `spago build` - Compiles PureScript to Erlang source (`.erl` files in `output/`)
2. `erlc` - Compiles Erlang source to BEAM bytecode (`.beam` files in `ebin/`)
3. `rebar3` - Manages Erlang dependencies (cowboy, ranch)

### Manual Build (if needed)

```bash
spago build                                    # PureScript → Erlang
find output -name "*.erl" -exec erlc -o ebin {} \;   # Erlang → BEAM
ERL_LIBS="_build/default/lib" erl -pa ebin -noshell -eval 'F = main@ps:main(), F()'
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
```

## Features

- **WebSocket server** on `ws://localhost:8080/ws`
- **Tidal mini-notation parser** - `bd sn [hh hh] cp`, `bd(3,8)`, etc.
- **Real-time MIDI scheduling** with precise timing
- **Multiple MIDI device support** via macOS IAC Driver

## Architecture

```
Frontend (Browser)          Backend (Erlang/BEAM)
      │                            │
      │  ws://localhost:8080/ws    │
      ├───────────────────────────►│
      │  "bd sn [hh hh] cp"        │
      │                            ▼
      │                     ┌──────────────┐
      │                     │ Parse pattern│
      │                     └──────┬───────┘
      │                            ▼
      │                     ┌──────────────┐
      │                     │MIDI Scheduler│
      │                     └──────┬───────┘
      │                            ▼
      │                     ┌──────────────┐
      │◄───────────────────│   sendmidi   │───► MIDI Hardware
      │  "OK: bd sn..."    └──────────────┘
```

## Test Suite

The project includes a comprehensive test suite (77 tests) covering:

- **Parser tests** (36): Basic atoms, silence, speed modifiers, degradation, repetition, elongation, grouping, stack, polyrhythm, euclidean, choose, variables, round-trip
- **Pattern evaluation** (12): Sequences, silence, stack/parallel, speed modifiers, euclidean rhythms, groups
- **Core combinators** (13): `cat`, `fastCat`, `stack`, `rev`, `fast`, `slow`, `rotL`, `rotR`, `fastAppend`
- **Euclidean rhythms** (16): Toussaint paper examples including E(3,8), E(5,8), E(7,12), Cuban cinquillo, West African bell patterns

Run tests with:
```bash
make test
```

## Supported Mini-Notation

- Sequences: `bd sn cp hh`
- Rests: `bd ~ sn ~`
- Parallel/polyrhythm: `[bd, sn, hh]`
- Fast/slow: `bd*4`, `sn/2`
- Euclidean rhythms: `bd(3,8)`
- Alternation: `<bd sn cp>`

## MIDI Setup (macOS)

1. Open **Audio MIDI Setup**
2. Window → Show MIDI Studio
3. Double-click IAC Driver
4. Add a port named "Tidal"
5. Route to your DAW or hardware

## Dependencies

- Erlang/OTP 24+
- [purerl](https://github.com/purerl/purerl) compiler
- [sendmidi](https://github.com/gbevin/SendMIDI) CLI tool
- cowboy (Erlang HTTP server)

## License

GPL-3.0-or-later (matching TidalCycles licensing)
