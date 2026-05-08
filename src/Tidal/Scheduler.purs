-- | Real-time scheduler for Tidal patterns on Erlang/BEAM
-- |
-- | Uses Erlang's timer facilities for precise scheduling
module Tidal.Scheduler
  ( SchedulerConfig
  , ScheduledEvent
  , ParamSpec
  , Msg(..)
  , startScheduler
  , sendAfter
  , currentTimeMs
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Foldable (for_)
import Data.Int (round, toNumber, floor) as Int
import Data.Rational (Rational, fromInt, toNumber) as R
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple (Tuple)
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Erl.Kernel.Erlang (monotonicTime, monotonicStartTime, monotonicTimeDelta, nativeTimeToMilliseconds)
import Erl.Process (Process, ProcessM, spawn, self, receive, (!), unsafeRunProcessM)
import Erl.Process.Raw as Raw
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Core (queryArc, stack)
import Tidal.Pattern.Types (Event(..), Pattern, Arc(..))

-- | Scheduler configuration
type SchedulerConfig =
  { bpm :: Number           -- Beats per minute (cycles per minute)
  , lookAhead :: Number     -- How far ahead to schedule (in ms)
  , scheduleInterval :: Int -- How often to run scheduler (in ms)
  }

-- | Internal scheduler state
type SchedulerState =
  { config :: SchedulerConfig
  , startTime :: Milliseconds   -- When scheduler started
  , nextCycle :: R.Rational     -- Next cycle to schedule
  , pattern :: Pattern String   -- Current pattern
  }

-- | A scheduled event with absolute time
type ScheduledEvent =
  { time :: Milliseconds  -- When to trigger (absolute)
  , sample :: String      -- What sample to play
  }

-- | One named-parameter join from a `#` segment.  Carried alongside the
-- | structure pattern in PlayByName so the scheduler can build per-event
-- | parameter values when a binding fires.
-- |
-- |   `kick "x*4" # vel "100 64 80 50"` →
-- |       PlayByName "kick" "x*4" "<text>" [{ name: "vel", pat: "100 64 80 50" }]
type ParamSpec = { name :: String, pat :: String }

-- | Messages to the scheduler process
data Msg
  = Tick              -- Time to schedule more events
  -- Named bindings (Tidal.Binding.PrimAction). Action specs come in as
  -- pre-formatted strings the scheduler parses, so binding errors show up
  -- in the BEAM logs rather than requiring an Erlang-side parser.
  | AddBinding String String      -- name, action-spec (e.g. "gate 6 + cv 15 voct")
  | RemoveBinding String          -- name
  -- Like PlayByName but with a pre-evaluated structure pattern (from
  -- `Tidal.Expr.eval`).  Used by the `<bound-name> :<expr>` form so
  -- the host language's Branched combinators flow through the
  -- binding's per-event note resolver instead of GateTrack's
  -- drum-map fallback.  Param specs (`# vel "..."`) are ignored on
  -- this path in v1 — the expression already produces a complete
  -- Pattern.
  | PlayByNameP String (Pattern String) String
      -- name, pre-evaluated pattern, fullText (for logging only)
  -- Same colon-prefix form as PlayByNameP, but carries the raw expression
  -- source rather than a pre-evaluated pattern.  This lets the scheduler
  -- choose between `Tidal.Expr.eval` (string-typed pattern, dispatched
  -- via BoundTrack) and `Tidal.Expr.evalNum` (number-typed pattern,
  -- dispatched via ContinuousTrack) based on whether the name is
  -- registered as a continuous binding.  WS handler sends this for the
  -- `<name> :<expr>` form; the registry lookup is the only thing that
  -- decides which dispatch path to take.
  | PlayByNameExpr String String String
      -- name, exprSrc, fullText
  -- Multi-destination dispatch from the bare `:<expr>` form (e.g.
  -- `:mult [bass:id, lead:rev] "c4 e4 g4 b4"`).  Each (name, pattern)
  -- becomes a BoundTrack on its named binding, replacing any prior
  -- BoundTrack with the same name.  All voices in a single message
  -- update atomically.  Voices whose name has no registered binding
  -- are logged and skipped — the rest still ship.
  | PlayMultiByName (Array (Tuple String (Pattern String))) String
      -- per-voice patterns, fullText (for logging only)
  -- Tidal-compat: silence everything. Bindings registry is preserved
  -- (so subsequent `kick bd*4` works without rebinding). Same intent
  -- as upstream Tidal's `hush`.
  | Hush
  -- MIDI device alias registry: `midi-device <alias> <real-device-name> [lat <ms>]`.
  -- Real device name is the rest-of-line so it can contain spaces
  -- ("AUDIO4c USB2"). Bindings reference the alias. Latency is in ms,
  -- subtracted from each event's delay so slow destinations (iPad audio
  -- buffer, Ableton) fire on-time alongside the modular.
  | RegisterMidiDevice String String Number  -- alias, deviceName, latencyMs
  -- FH-2 envelope registration. `Fh2Envelope voice output channel` records
  -- the (voice → channel) mapping in scheduler state so `fh2-trigger` can
  -- resolve it. The accompanying SysEx push to actually configure the FH-2
  -- happens in Handler.erl (shell-out to fh2-config), not here.
  | Fh2Envelope Int Int Int            -- voice, base-output, MIDI channel
  -- One-shot ADSR push for an FH-2 voice. Sends 4 MIDI CCs (70/71/72/73 by
  -- convention, per the configurator's ADSR bindings) to the FH-2 device
  -- on the voice's MIDI channel. Not pattern-driven — fires immediately on
  -- evaluation, like fh2-envelope. Lets the user reshape envelopes live
  -- without touching the FH-2 Configurator.
  | Fh2Shape Int Int Int Int Int       -- voice, attack, decay, sustain, release (each 0-127)
  -- Live config writes (in-memory; not yet persisted to current.tidal).
  -- Mid-session BPM change without Link will glitch the cycle counter
  -- (currentCycle = elapsedMs / cycleDurationMs and both sides shift);
  -- with Link active the rate change is smooth.
  | SetBpm Number                      -- BPM, e.g. 120.0
  | SetDefaultMidiDevice String        -- legacy default MIDI device name
  | SetGateEnabled Boolean             -- toggles OSC gate output to cv-router
  | SetLookAheadMs Number              -- scheduler look-ahead in ms
  | Stop              -- Stop the scheduler

-- | FFI for erlang:send_after
foreign import sendAfterImpl :: Int -> Raw.Pid -> Msg -> Effect Unit

sendAfter :: Int -> Raw.Pid -> Msg -> Effect Unit
sendAfter = sendAfterImpl

-- | Get current monotonic time in milliseconds
currentTimeMs :: Effect Milliseconds
currentTimeMs = do
  now <- monotonicTime
  pure $ nativeTimeToMilliseconds $ monotonicTimeDelta monotonicStartTime now

-- | Start the scheduler process
startScheduler :: SchedulerConfig -> String -> Effect (Process Msg)
startScheduler config patternStr = do
  spawn do
    startTime <- liftEffect currentTimeMs

    -- Parse initial pattern
    let pat = case parse patternStr of
          Right ast -> tpatToPattern ast
          Left _ -> pure "~"  -- silence on parse error

    -- Initial state
    stateRef <- liftEffect $ Ref.new
      { config
      , startTime
      , nextCycle: zero
      , pattern: pat
      }

    liftEffect $ log $ "Scheduler started at " <> show startTime
    liftEffect $ log $ "BPM: " <> show config.bpm
    liftEffect $ log $ "Pattern: " <> patternStr

    -- Start the tick loop
    pid <- liftEffect Raw.self
    liftEffect $ sendAfter config.scheduleInterval pid Tick

    -- Main loop
    schedulerLoop stateRef

-- | Main scheduler loop
schedulerLoop :: Ref SchedulerState -> ProcessM Msg Unit
schedulerLoop stateRef = do
  msg <- receive
  case msg of
    Tick -> do
      state <- liftEffect $ Ref.read stateRef
      now <- liftEffect currentTimeMs

      -- Calculate cycle time (1 cycle = 1 bar = 4 beats)
      let cycleDurationMs = 240000.0 / state.config.bpm
      let elapsedMs = case now, state.startTime of
            Milliseconds n, Milliseconds s -> n - s

      -- Current position in cycles
      let currentCycle = elapsedMs / cycleDurationMs

      -- Schedule events for upcoming cycles
      let lookAheadCycles = state.config.lookAhead / cycleDurationMs
      let endCycle = currentCycle + lookAheadCycles

      -- Query pattern for events
      let fromCycleNum = max (R.toNumber state.nextCycle) currentCycle
      let toCycleNum = endCycle
      let fromCycle = R.fromInt (Int.floor fromCycleNum)
      let toCycle = R.fromInt (Int.floor toCycleNum + 1)

      when (fromCycle < toCycle) do
        let events = queryArc state.pattern fromCycle toCycle
        for_ events \event -> do
          let eventCycle = eventStartCycle event
          let sample = eventSample event

          -- Only log events in our lookahead window
          when (eventCycle >= fromCycle && eventCycle < toCycle) do
            liftEffect $ log $ "  → " <> sample <> " @ cycle " <> show (R.toNumber eventCycle)

      -- Update next cycle
      liftEffect $ Ref.write (state { nextCycle = toCycle }) stateRef

      -- Schedule next tick
      pid <- liftEffect Raw.self
      liftEffect $ sendAfter state.config.scheduleInterval pid Tick
      schedulerLoop stateRef

    -- Named-binding messages have no meaning in the base scheduler
    -- (it has no binding registry, no PrimAction dispatcher, no slot env).
    -- Ignore so the Cowboy handler can broadcast to either scheduler kind.
    AddBinding _ _ -> schedulerLoop stateRef
    RemoveBinding _ -> schedulerLoop stateRef
    PlayByNameP _ _ _ -> schedulerLoop stateRef
    PlayByNameExpr _ _ _ -> schedulerLoop stateRef
    PlayMultiByName _ _ -> schedulerLoop stateRef
    Hush -> do
      state <- liftEffect $ Ref.read stateRef
      liftEffect $ Ref.write (state { pattern = pure "~" }) stateRef
      liftEffect $ log "hush"
      schedulerLoop stateRef

    RegisterMidiDevice _ _ _ -> schedulerLoop stateRef

    -- Base scheduler has no FH-2 awareness either; the MIDI scheduler
    -- carries that state.
    Fh2Envelope _ _ _ -> schedulerLoop stateRef
    Fh2Shape _ _ _ _ _ -> schedulerLoop stateRef

    -- Live config writes are handled in MIDIScheduler; the base
    -- scheduler doesn't carry that state, so swallow them.
    SetBpm _ -> schedulerLoop stateRef
    SetDefaultMidiDevice _ -> schedulerLoop stateRef
    SetGateEnabled _ -> schedulerLoop stateRef
    SetLookAheadMs _ -> schedulerLoop stateRef

    Stop -> do
      liftEffect $ log "Scheduler stopped"

-- | Get cycle start time from event
eventStartCycle :: Event String -> R.Rational
eventStartCycle = case _ of
  Digital { part: Arc { start } } -> start
  Analog { part: Arc { start } } -> start

-- | Get sample name from event
eventSample :: Event String -> String
eventSample = case _ of
  Digital { value } -> value
  Analog { value } -> value
