# Claude Context: purerl-tidal

Erlang backend for the Tilted Radio (Tidal Editor) showcase. Compiles PureScript to Erlang via purs-backend-erl (the PureScript-based rewrite of purerl, using purescript-backend-optimizer).

## Quick Reference

**Build:**
```bash
cd /Users/afc/work/afc-work/PSD3-Repos
make app-tilted-radio
```

**Run:**
```bash
cd showcases/psd3-tilted-radio/purerl-tidal
rebar3 shell
# Then in Erlang:
code:add_path("/Users/afc/work/afc-work/PSD3-Repos/showcases/psd3-tilted-radio/purerl-tidal/ebin").
('main@ps':main())().
```

**Send patterns:**
```bash
wscat -c ws://localhost:8080/ws
# Type: bd sn hh cp
```

## Key Files

| File | Purpose |
|------|---------|
| `src/Main.purs` | Entry point, config |
| `src/Tidal/MIDIScheduler.purs` | Pattern scheduling, MIDI + Gate output |
| `src/Tidal/OSC.purs` + `.erl` | OSC bindings for CV/Gate |
| `supercollider/tidal-cv-engine.scd` | SuperCollider engine for ES-9 |
| `CV-SETUP.md` | **Detailed setup guide for CV output** |

## Critical Knowledge

### purerl Module Naming
- PureScript `Main` → Erlang `'main@ps'`
- Quotes required due to `@` symbol

### Build Pipeline
1. `spago build` → CoreFn JSON in `output/`, then invokes `purs-backend-erl` → `.erl` files in `output-erl/`
2. `rebar3 compile` → deps only
3. `erlc -disable-feature maybe_expr -o ebin output-erl/*/*.erl` → beam files (Makefile does this)

### OTP 25+ Compatibility
`maybe` became a keyword in Erlang/OTP 25. The purs-backend-erl backend generates `maybe/0` and `maybe/3` functions (from `Data.Maybe`). The Makefile passes `-disable-feature maybe_expr` to erlc to work around this.

### rebar3 Shell Gotcha
The `ebin/` directory with purerl output is NOT in rebar3's default code path. Must add manually:
```erlang
code:add_path(".../ebin").
```

### ES-9 CV Output
See `CV-SETUP.md` for complete details. Key points:
- SuperCollider outbus 8 = ES-9 jack 1 (not outbus 0!)
- Must use `K2A.ar()` not `DC.ar()` for control-rate tracking
- Gates on jacks 1-4, CV on jacks 5-8

## Architecture

```
Browser ──WebSocket──▶ Cowboy ──▶ MIDIScheduler
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
              sendmidi CLI      OSC to SC        (future: CV patterns)
                    │                 │
                    ▼                 ▼
              MIDI Hardware     ES-9 Gates/CV
```

## Dependencies

- Erlang/OTP 24+
- rebar3
- purs-backend-erl (npm devDependency)
- SuperCollider (for CV output)
- sendmidi CLI (for MIDI output)
- wscat or browser for WebSocket client
