# purerl-tidal

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

# Start the backend
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
