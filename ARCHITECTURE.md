# PureScript Tidal Architecture

This document describes the architecture of the PureScript port of TidalCycles, focused on MIDI output.

## Overview

The port takes Tidal's mini-notation strings, parses them to an AST, evaluates the AST to executable patterns, and schedules MIDI output to hardware.

```
"bd sn [hh hh] cp"     (mini-notation string)
        │
        ▼
    ┌───────────┐
    │  Parser   │      Tidal.Parse.*
    └───────────┘
        │
        ▼
    TPat String        (Abstract Syntax Tree)
        │
        ▼
    ┌───────────┐
    │ Evaluator │      Tidal.Eval.Interpret
    └───────────┘
        │
        ▼
    Pattern String     (Query function: State → [Event])
        │
        ▼
    ┌───────────┐
    │ Scheduler │      Tidal.Output.Scheduler
    └───────────┘
        │
        ▼
    MIDI messages      (via Web MIDI API)
        │
        ▼
    Hardware           (modular synth, Ableton, etc.)
```

## Module Structure

```
src/Tidal/
├── Core/
│   └── Types.purs          # Time (Rational), Seed, ControlName, SourceSpan
│
├── AST/
│   ├── Types.purs          # TPat - the parsed AST type
│   └── Pretty.purs         # AST → String (for round-tripping)
│
├── Parse/
│   ├── Parser.purs         # Entry points: parseMini, parseTPat
│   ├── Combinators.purs    # Parser implementation
│   ├── Class.purs          # AtomParseable typeclass
│   └── State.purs          # Parser state (seed counter, position)
│
├── Pattern/
│   ├── Types.purs          # Pattern, Event, Arc, Value, State
│   └── Core.purs           # Combinators: fast, slow, cat, stack, etc.
│
├── Eval/
│   └── Interpret.purs      # TPat → Pattern evaluation
│
└── Output/
    ├── WebMidi.purs + .js  # Web MIDI API bindings
    └── Scheduler.purs + .js # Real-time pattern → MIDI scheduling
```

## Key Types

### Time Representation

```purescript
type Time = Rational  -- Exact rational arithmetic (e.g., 1/3 is precise)
```

Tidal uses rational numbers for time to avoid floating-point drift and ensure exact subdivision.

### Arc (Time Intervals)

```purescript
newtype Arc = Arc { start :: Time, stop :: Time }
```

Arcs are half-open intervals `[start, stop)` representing spans of time. A **cycle** is the interval `[n, n+1)` for integer `n`.

### Event (Digital vs Analog)

```purescript
data Event a
  = Digital { context :: Context, whole :: Arc, part :: Arc, value :: a }
  | Analog { context :: Context, part :: Arc, value :: a }
```

**Key design improvement over Haskell Tidal**: The digital/analog distinction is explicit in the type, not hidden in a `Maybe` field.

- **Digital events** have a defined "whole" (the complete event span). Used for discrete occurrences like note onsets.
- **Analog events** are continuous (no defined boundaries). Used for parameter sweeps like LFOs.

This distinction affects how patterns combine via Applicative.

### Pattern (The Core Abstraction)

```purescript
newtype Pattern a = Pattern (State → Array (Event a))

type State = { arc :: Arc, controls :: ControlMap }
```

A pattern is a **query function**: given a time arc, return all events in that arc. Patterns are:
- Lazy: Nothing computes until queried
- Pure: Same query always returns same events
- Composable: Functor, Applicative, Monad instances

### TPat (The AST)

```purescript
data TPat a
  = TPat_Atom (Located a)           -- "bd", 60, etc.
  | TPat_Silence SourceSpan         -- ~
  | TPat_Seq SourceSpan (Array (TPat a))        -- bd sn hh
  | TPat_Stack SourceSpan (Array (TPat a))      -- bd, sn (simultaneous)
  | TPat_Fast SourceSpan (TPat Rational) (TPat a)   -- bd*2
  | TPat_Slow SourceSpan (TPat Rational) (TPat a)   -- bd/2
  | TPat_Euclid SourceSpan (TPat Int) (TPat Int) (TPat Int) (TPat a)  -- bd(3,8)
  -- ... and more
```

Every node carries a `SourceSpan` for error messages and editor integration.

## Design Decisions (Improvements over Haskell Tidal)

### 1. Explicit Digital/Analog Events

Haskell Tidal uses `Maybe Arc` for the "whole" field, requiring runtime checks:
```haskell
isAnalog (Event {whole = Nothing}) = True  -- Runtime check
```

We use a sum type, enforced at compile time:
```purescript
data Event a = Digital { whole :: Arc, ... } | Analog { ... }
```

### 2. No VState in Value Type

Haskell Tidal's `Value` type includes:
```haskell
data Value = ... | VState (ValueMap -> (ValueMap, Value))  -- Function inside data!
```

This conflates values with computations. Our `Value` type is pure data:
```purescript
data Value = VInt Int | VNumber Number | VString String | VNote Note | VBool Boolean | VRational Rational
```

### 3. No Optimization Fields in Pattern

Haskell Tidal exposes internal optimization fields:
```haskell
data Pattern a = Pattern { query :: ..., steps :: Maybe Rational, pureValue :: Maybe a }
```

We hide these implementation details:
```purescript
newtype Pattern a = Pattern (State → Array (Event a))
```

### 4. Modular File Structure

Haskell Tidal has 3000+ line files (UI.hs, Params.hs). We split by concern:
- `Pattern/Types.purs` - Core types only
- `Pattern/Core.purs` - Combinators
- `Eval/Interpret.purs` - AST evaluation

### 5. No Underscore Function Explosion

Haskell Tidal has 50+ function pairs like:
```haskell
degradeBy :: Pattern Double -> Pattern a -> Pattern a
_degradeBy :: Double -> Pattern a -> Pattern a
```

We use a single implementation with pattern application handled by the caller.

## Pattern Evaluation Flow

When `tpatToPattern` converts AST to Pattern:

1. **Atoms** become constant patterns (one event per cycle)
2. **Sequences** become `fastCat` (divide cycle equally)
3. **Stacks** become `stack` (overlay simultaneous)
4. **Fast/Slow** scale time via `fast`/`slow` combinators
5. **Euclidean** uses Bjorklund's algorithm to distribute events

## Scheduling and MIDI Output

### Timing Model

```
BPM = 120
1 cycle = 1 bar = 4 beats
cps (cycles per second) = BPM / 240 = 0.5

At 120 BPM, one cycle takes 2 seconds.
```

### Scheduler Loop

Every 25ms, the scheduler:
1. Calculates current position in cycles
2. Queries pattern for upcoming events (100ms look-ahead)
3. Converts events to MIDI messages
4. Schedules via Web MIDI API with precise timestamps

```purescript
tick :: Ref SchedulerState → Effect Unit
tick stateRef = do
  currentTime ← now
  let elapsedCycles = (currentTime - startTime) * cps / 1000.0
      lookAheadCycles = 100.0 * cps / 1000.0
  -- Query pattern, schedule MIDI...
```

### Note Mapping

Pattern values (strings like "bd", "sn") map to MIDI:

| Pattern | MIDI Note | Channel | Sound |
|---------|-----------|---------|-------|
| bd | 36 | 10 | Kick |
| sn | 38 | 10 | Snare |
| hh | 42 | 10 | Hi-hat |
| 60 | 60 | 1 | Middle C |

## Browser Considerations

- **Web MIDI requires HTTPS** (or localhost)
- **Background tabs are throttled** - keep Chrome in foreground
- **User interaction required** for MIDI access (browser security)

## Dependencies

- `purescript-midi` - MIDI types (NoteOn, NoteOff, etc.)
- `purescript-rationals` - Exact time representation
- `purescript-parsing` - Parser combinators
- `purescript-aff` / `purescript-refs` - Effects and state

## Known Issues

### MIDI Note Bunching When Receiver is Backgrounded

**Symptom:** When Chrome is foregrounded but the receiving DAW (e.g., Ableton) is backgrounded, patterns like `bd sn [hh hh] cp` trigger dozens of repeated notes per step rather than single hits.

**Observations:**
- Works correctly when both Chrome and DAW are foregrounded
- Works correctly when DAW is foregrounded (Chrome background causes separate throttling issues)
- Other MIDI sources (e.g., iPad sequencers via network MIDI) work fine with backgrounded Ableton

**Possible causes to investigate:**
1. **Web MIDI timestamp handling** - We schedule with future timestamps via `send(data, timestamp)`. The browser or OS MIDI layer may handle these differently than real-time streams from hardware/network sources.
2. **Look-ahead window interaction** - Our 100ms look-ahead schedules multiple events with future timestamps. Hardware sequencers send events just-in-time.
3. **IAC Driver behavior** - If using macOS IAC for routing, it may buffer differently than hardware MIDI ports.
4. **Chrome's MIDI implementation** - May differ from CoreMIDI network sessions in how it batches or timestamps messages.

**Workarounds for now:**
- Keep the DAW foregrounded during playback
- Use a hardware MIDI interface rather than virtual ports (untested)

**Potential fixes to explore:**
- Send messages just-in-time (smaller look-ahead) at cost of timing precision
- Use AudioContext clock for scheduling instead of setInterval + Web MIDI timestamps
- Investigate if explicit MIDI clock sync helps

## Future Improvements

1. **Web Audio timing** - Use AudioContext for jitter-free scheduling
2. **Web Workers** - Avoid background tab throttling
3. **More combinators** - `every`, `sometimes`, `jux`, etc.
4. **Control patterns** - Velocity, CC, pitch bend modulation
5. **Variable lookup** - Support `^speed` style references
