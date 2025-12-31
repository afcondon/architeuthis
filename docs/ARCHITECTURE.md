# purerl-tidal Architecture

A real-time Tidal pattern scheduler running on the Erlang/BEAM VM, written in PureScript and compiled via purerl.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Browser                                   │
│  ws = new WebSocket('ws://localhost:8080/ws')                   │
│  ws.send('bd sn hh cp')                                         │
└─────────────────────┬───────────────────────────────────────────┘
                      │ WebSocket
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Erlang/BEAM VM                                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Cowboy WebSocket Server (port 8080)                         ││
│  │   Handler.erl - receives patterns, validates, forwards      ││
│  └─────────────────────┬───────────────────────────────────────┘│
│                        │ {updatePattern, "bd sn hh cp"}         │
│                        ▼                                         │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ MIDI Scheduler Process                                       ││
│  │   - Parses Tidal mini-notation                              ││
│  │   - Queries pattern for events each cycle                   ││
│  │   - Sends MIDI via persistent sendmidi port                 ││
│  └─────────────────────┬───────────────────────────────────────┘│
│                        │ port_command(Port, "ch 10 on 36 100")  │
│                        ▼                                         │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ sendmidi process (persistent Erlang port)                   ││
│  │   ~/bin/sendmidi dev "IAC Driver Tidal" --                  ││
│  └─────────────────────┬───────────────────────────────────────┘│
└─────────────────────────┼───────────────────────────────────────┘
                          │ MIDI
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  IAC Driver Tidal (macOS virtual MIDI bus)                      │
└─────────────────────────┬───────────────────────────────────────┘
                          │ MIDI
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  Ableton Live / DAW                                             │
│    - MIDI input from IAC Driver Tidal                           │
│    - Drum Rack on channel 10                                    │
└─────────────────────────────────────────────────────────────────┘
```

## Tech Stack

### PureScript → purerl → Erlang

**PureScript** is a strongly-typed functional language that compiles to multiple backends. The standard backend is JavaScript, but **purerl** is an alternative backend that compiles to Erlang.

```
PureScript source (.purs)
        │
        ▼ purerl compiler
Erlang source (.erl)
        │
        ▼ Erlang compiler
BEAM bytecode (.beam)
        │
        ▼ Erlang VM
Running process
```

### Why Erlang/BEAM?

1. **Lightweight processes** - Erlang can spawn millions of processes cheaply
2. **Message passing** - Processes communicate via async messages (actor model)
3. **Precise timing** - `erlang:send_after/3` for scheduling with millisecond precision
4. **Hot code reloading** - Update code without stopping the system
5. **Fault tolerance** - "Let it crash" philosophy with supervisor trees

### Key Erlang Concepts Used

#### Processes and Messages

```erlang
%% Spawn a new process
Pid = spawn(fun() -> loop(State) end).

%% Send a message to a process
Pid ! {updatePattern, <<"bd sn hh cp">>}.

%% Receive messages (blocks until message arrives)
receive
    {updatePattern, Pattern} -> handle_pattern(Pattern);
    tick -> handle_tick()
end.
```

In PureScript (via purerl):
```purescript
-- Spawn returns Process Msg (typed process)
schedulerPid <- spawn do
  msg <- receive  -- blocks waiting for Msg type
  case msg of
    UpdatePattern pat -> ...
    Tick -> ...
```

#### Erlang Ports

Ports are how Erlang communicates with external programs. We use a port to keep a persistent connection to `sendmidi`:

```erlang
%% Open a port to sendmidi (stays running, reads from stdin)
Port = open_port({spawn, "sendmidi dev \"IAC Driver Tidal\" --"}, [stream]).

%% Send commands through the port
port_command(Port, "ch 10 on 36 100\n").  % Note on
port_command(Port, "ch 10 off 36\n").     % Note off
```

This is much faster than spawning a new `os:cmd()` for each note.

#### Timer Facilities

```erlang
%% Schedule a message to be sent after N milliseconds
erlang:send_after(50, self(), tick).
```

This is how the scheduler maintains its tick loop - every 50ms it sends itself a `tick` message.

## Project Structure

```
purerl-tidal/
├── src/
│   ├── Main.purs                 # Entry point
│   ├── Tidal/
│   │   ├── AST/
│   │   │   ├── Types.purs        # Abstract syntax tree types
│   │   │   └── Pretty.purs       # Pretty printer for AST
│   │   ├── Parse/
│   │   │   ├── Parser.purs       # Tidal mini-notation parser
│   │   │   ├── Combinators.purs  # Parser combinators
│   │   │   ├── State.purs        # Parser state
│   │   │   └── Class.purs/.erl   # Parsec compatibility
│   │   ├── Pattern/
│   │   │   ├── Types.purs        # Event, Arc, Pattern types
│   │   │   └── Core.purs         # Pattern evaluation (queryArc)
│   │   ├── Eval/
│   │   │   └── Interpret.purs    # AST → Pattern conversion
│   │   ├── Scheduler.purs/.erl   # Console scheduler (for testing)
│   │   ├── MIDIScheduler.purs    # MIDI output scheduler
│   │   ├── MIDI.purs/.erl        # MIDI FFI (sendmidi interface)
│   │   ├── OSC.purs/.erl         # OSC output (for SuperCollider)
│   │   └── WebSocket/
│   │       ├── Server.purs/.erl  # Cowboy WebSocket server setup
│   │       └── Handler.purs/.erl # WebSocket message handler
├── demo/
│   └── tidal-live.html           # Browser-based pattern editor
├── spago.yaml                    # PureScript package config
├── rebar.config                  # Erlang dependencies (cowboy, ranch)
└── _build/                       # Erlang build artifacts
```

## Module Details

### Main.purs

Entry point that:
1. Lists MIDI devices
2. Starts MIDI scheduler with silence pattern
3. Starts WebSocket server connected to scheduler
4. Runs for 10 minutes

```purescript
main :: Effect Unit
main = do
  MIDI.listDevices
  midiSchedulerPid <- startMIDIScheduler midiConfig "~"
  _ <- WS.startServer WS.defaultServerConfig midiSchedulerPid
  sleep (Milliseconds 600000.0)
```

### Tidal.Parse.Parser

Parses Tidal mini-notation into an AST:

```purescript
parse :: String -> Either ParseError TPat
parse "bd sn hh cp"  -- Right (TSeq [TAtom "bd", TAtom "sn", ...])
parse "bd(3,8)"      -- Right (TEuclid (TAtom "bd") 3 8 Nothing)
parse "bd*4"         -- Right (TFast (TAtom "bd") (TRational 4))
```

Supported syntax:
- `bd sn hh` - sequence
- `[bd sn]` - group (fits in one step)
- `bd*4` - repeat/fast
- `bd/2` - slow
- `bd(3,8)` - Euclidean rhythm
- `<bd sn>` - alternating
- `~` - silence

### Tidal.Pattern.Types

Core pattern types:

```purescript
-- A pattern is a function from time span to events
type Pattern a = Arc -> Array (Event a)

-- An arc is a time span (rational numbers for precision)
newtype Arc = Arc { start :: Rational, stop :: Rational }

-- An event has timing and value
data Event a
  = Digital { whole :: Arc, part :: Arc, value :: a }
  | Analog { part :: Arc, value :: a }
```

### Tidal.Pattern.Core

Pattern evaluation:

```purescript
-- Query a pattern for events in a time range
queryArc :: forall a. Pattern a -> Rational -> Rational -> Array (Event a)

-- Example: query cycle 0-1
events = queryArc pattern (fromInt 0) (fromInt 1)
-- Returns events with their time positions
```

### Tidal.MIDIScheduler

The real-time MIDI scheduler:

```purescript
type MIDISchedulerConfig =
  { bpm :: Number              -- Beats per minute
  , lookAhead :: Number        -- Look-ahead in ms
  , scheduleInterval :: Int    -- Tick interval in ms
  , midi :: MIDIConfig         -- MIDI device settings
  , noteMap :: Map String Int  -- Sample name → MIDI note
  , noteDuration :: Int        -- Note length in ms
  }
```

Timing formula:
```purescript
-- 1 cycle = 1 bar = 4 beats
cycleDurationMs = 240000.0 / bpm
-- At 120 BPM: 240000/120 = 2000ms per cycle
```

### Tidal.MIDI (FFI)

The Erlang FFI for MIDI output:

**MIDI.purs** - PureScript interface:
```purescript
foreign import data MIDIClient :: Type
foreign import startClient :: MIDIConfig -> Effect MIDIClient
foreign import noteOn :: MIDIClient -> Int -> Int -> Effect Unit
foreign import sendDrum :: MIDIClient -> Int -> Int -> Int -> Effect Unit
```

**MIDI.erl** - Erlang implementation:
```erlang
-module(tidal_mIDI@foreign).

%% Path to sendmidi binary
-define(SENDMIDI, os:getenv("HOME") ++ "/bin/sendmidi").

%% Start client - opens persistent port to sendmidi
startClient(Config) ->
    fun() ->
        Device = binary_to_list(maps:get(device, Config)),
        Cmd = lists:flatten(io_lib:format("~s dev \"~s\" --", [?SENDMIDI, Device])),
        Port = open_port({spawn, Cmd}, [stream, {line, 256}]),
        #{port => Port, channel => maps:get(channel, Config)}
    end.

%% Send note via port (fast - no process spawn)
noteOn(Client, Note, Velocity) ->
    fun() ->
        Port = maps:get(port, Client),
        Cmd = io_lib:format("ch ~B on ~B ~B", [Channel, Note, Velocity]),
        port_command(Port, lists:flatten(Cmd) ++ "\n"),
        unit
    end.
```

### Tidal.WebSocket.Handler (FFI)

The native Erlang WebSocket handler (required because cowboy expects specific callback arities):

```erlang
-module(tidal_webSocket_handler@foreign).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

init(Req, Config) ->
    SchedulerPid = maps:get(schedulerPid, Config),
    State = #{schedulerPid => SchedulerPid},
    {cowboy_websocket, Req, State}.

websocket_handle({text, Text}, State) ->
    SchedulerPid = maps:get(schedulerPid, State),
    case 'tidal_parse_parser@ps':parse(Text) of
        {right, _} ->
            %% Valid pattern - send to scheduler process
            SchedulerPid ! {updatePattern, Text},
            {reply, {text, <<"OK: ", Text/binary>>}, State};
        {left, Err} ->
            {reply, {text, <<"ERROR: ", ErrBin/binary>>}, State}
    end.
```

Key points:
- `'tidal_parse_parser@ps'` - purerl module naming (module@ps suffix)
- `SchedulerPid ! {updatePattern, Text}` - send message to scheduler
- Pattern is validated before forwarding

### Tidal.WebSocket.Server

Sets up the Cowboy HTTP server with WebSocket endpoint:

```purescript
startServer :: ServerConfig -> Process Msg -> Effect (Either String Unit)
startServer config schedulerPid = do
  ensureStarted  -- Start ranch, cowboy OTP applications

  let routes = Routes.compile $ List.singleton $
        Routes.anyHost $ List.singleton $
          Routes.path "/ws" handlerModule initialState

  Cowboy.startClear (atom config.name) transportOpts protoOpts
```

## Message Flow

### Pattern Update Flow

```
1. Browser sends: ws.send('bd(3,8)')

2. Cowboy receives WebSocket frame
   → Handler.erl:websocket_handle({text, <<"bd(3,8)">>}, State)

3. Handler validates pattern
   → 'tidal_parse_parser@ps':parse(<<"bd(3,8)">>) = {right, AST}

4. Handler sends message to scheduler
   → SchedulerPid ! {updatePattern, <<"bd(3,8)">>}

5. Scheduler receives message
   → MIDIScheduler receives UpdatePattern in its receive loop

6. Scheduler updates pattern
   → Parses string, converts AST to Pattern, stores in state

7. On next tick, scheduler queries new pattern
   → Events are sent to MIDI
```

### Scheduler Tick Flow

```
1. Scheduler sends itself: sendAfter(50, self(), Tick)

2. After 50ms, scheduler receives Tick

3. Calculate current cycle position:
   elapsed = now - startTime
   currentCycle = elapsed / cycleDuration

4. Query pattern for upcoming events:
   events = queryArc(pattern, currentCycle, currentCycle + lookAhead)

5. For each event in window:
   note = sampleToNote(event.sample)  -- "bd" → 36
   sendDrum(midiClient, note, velocity, duration)

6. Schedule next tick:
   sendAfter(50, self(), Tick)
```

## Drum Mapping

General MIDI drum notes on channel 10:

```purescript
defaultDrumMap :: Map String Int
defaultDrumMap = Map.fromFoldable
  [ Tuple "bd" 36    -- Bass Drum 1
  , Tuple "kick" 36
  , Tuple "sn" 38    -- Acoustic Snare
  , Tuple "snare" 38
  , Tuple "hh" 42    -- Closed Hi-Hat
  , Tuple "hihat" 42
  , Tuple "ho" 46    -- Open Hi-Hat
  , Tuple "oh" 46
  , Tuple "cp" 39    -- Hand Clap
  , Tuple "clap" 39
  , Tuple "rim" 37   -- Side Stick
  , Tuple "lt" 45    -- Low Tom
  , Tuple "mt" 47    -- Mid Tom
  , Tuple "ht" 50    -- High Tom
  , Tuple "cy" 49    -- Crash Cymbal
  , Tuple "rd" 51    -- Ride Cymbal
  , Tuple "cb" 56    -- Cowbell
  , Tuple "~" 0      -- Silence (no note)
  ]
```

## Building and Running

### Prerequisites

```bash
# Install purerl (PureScript to Erlang compiler)
# See: https://github.com/purerl/purerl

# Install spago (PureScript package manager)
npm install -g spago

# Install Erlang/OTP
brew install erlang

# Install sendmidi (for MIDI output)
# Download from https://github.com/gbevin/SendMIDI/releases
# Extract and copy to ~/bin/sendmidi
```

### Build

```bash
cd purerl-tidal

# Build PureScript → Erlang
spago build

# Fetch Erlang dependencies (cowboy, ranch)
rebar3 get-deps
rebar3 compile
```

### Run

```bash
# Set ERL_LIBS to include cowboy
ERL_LIBS="_build/default/lib" spago run
```

### Connect

```javascript
// In browser console
ws = new WebSocket('ws://localhost:8080/ws')
ws.onmessage = e => console.log(e.data)
ws.send('bd sn hh cp')     // basic 4/4
ws.send('bd(3,8)')         // euclidean
ws.send('bd*4 sn*2')       // multiply
ws.send('[bd cp] hh*4')    // stacked
ws.send('~')               // silence
```

## Key Design Decisions

### Why Native Erlang for WebSocket Handler?

purerl generates functions that return functions (curried), but cowboy expects callbacks with specific arities like `init(Req, State)`. Writing the handler in native Erlang avoids this mismatch.

### Why Persistent sendmidi Port?

Initially we used `os:cmd("sendmidi ...")` for each note, but this caused timing drift because process spawn time varies. Using a persistent Erlang port keeps sendmidi running and pipes commands through stdin - much more consistent timing.

### Why 240000/bpm?

In Tidal, 1 cycle = 1 bar = 4 beats. At 120 BPM:
- 1 beat = 500ms
- 1 bar = 4 beats = 2000ms
- Formula: `cycleDurationMs = 60000 * 4 / bpm = 240000 / bpm`

### Why Rational Numbers?

Tidal uses rational numbers for time to avoid floating-point precision issues. A pattern like `bd(3,8)` divides the cycle into exact fractions that wouldn't be representable precisely with floats.

## Extending

### Adding New MIDI Mappings

Edit `Tidal.MIDIScheduler.defaultDrumMap`:

```purescript
, Tuple "tom1" 41
, Tuple "tom2" 43
, Tuple "perc" 54
```

### Adding OSC Output

The `Tidal.OSC` module is already stubbed out for SuperCollider output. Implement:

```purescript
sendOSC :: OSCClient -> String -> Milliseconds -> Effect Unit
```

### Adding More Pattern Combinators

Extend `Tidal.Parse.Parser` with new syntax, then implement the pattern transformation in `Tidal.Eval.Interpret`.
