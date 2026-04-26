-- | Real-time scheduler for Tidal patterns on Erlang/BEAM
-- |
-- | Uses Erlang's timer facilities for precise scheduling
module Tidal.Scheduler
  ( SchedulerConfig
  , ScheduledEvent
  , TrackInfo
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

-- | A track with its pattern string and MIDI channel
type TrackInfo = { pattern :: String, channel :: Int }

-- | Messages to the scheduler process
data Msg
  = Tick              -- Time to schedule more events
  | UpdatePattern String  -- Update the pattern (legacy, uses default channel)
  | UpdatePatternWithChannel String Int  -- Update pattern with specific MIDI channel
  | UpdateTracks (Array TrackInfo)  -- Update multiple tracks, each with own channel
  | UpdateGateTrack Int String   -- Replace gate track at channel idx with pattern
  | UpdateCVTrack Int String     -- Replace CV track at bus idx with pattern
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

    UpdatePattern patStr -> do
      state <- liftEffect $ Ref.read stateRef
      let newPat = case parse patStr of
            Right ast -> tpatToPattern ast
            Left _ -> state.pattern
      liftEffect $ Ref.write (state { pattern = newPat }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr
      schedulerLoop stateRef

    UpdatePatternWithChannel patStr _ -> do
      -- Base scheduler ignores channel (MIDI scheduler handles it)
      state <- liftEffect $ Ref.read stateRef
      let newPat = case parse patStr of
            Right ast -> tpatToPattern ast
            Left _ -> state.pattern
      liftEffect $ Ref.write (state { pattern = newPat }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr
      schedulerLoop stateRef

    UpdateTracks tracks -> do
      -- Base scheduler combines all track patterns (MIDI scheduler handles per-track channels)
      state <- liftEffect $ Ref.read stateRef
      let patterns = Array.mapMaybe (\t -> case parse t.pattern of
            Right ast -> Just (tpatToPattern ast)
            Left _ -> Nothing) tracks
      let combined = stack patterns
      liftEffect $ Ref.write (state { pattern = combined }) stateRef
      liftEffect $ log $ "Tracks updated: " <> show (Array.length tracks) <> " tracks"
      schedulerLoop stateRef

    UpdateGateTrack _ patStr -> do
      -- Base scheduler treats GateTrack the same as a single pattern update.
      state <- liftEffect $ Ref.read stateRef
      let newPat = case parse patStr of
            Right ast -> tpatToPattern ast
            Left _ -> state.pattern
      liftEffect $ Ref.write (state { pattern = newPat }) stateRef
      schedulerLoop stateRef

    UpdateCVTrack _ _ -> do
      -- Base scheduler has no concept of CV; ignore.
      schedulerLoop stateRef

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
