-- | MIDI-enabled scheduler for Tidal patterns
-- |
-- | Maps sample names to MIDI notes and sends them via sendmidi
module Tidal.MIDIScheduler
  ( MIDISchedulerConfig
  , startMIDIScheduler
  , sampleToNote
  , defaultDrumMap
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int (floor) as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Rational (Rational, fromInt, toNumber) as R
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Erl.Kernel.Erlang (monotonicTime, monotonicStartTime, monotonicTimeDelta, nativeTimeToMilliseconds)
import Erl.Process (Process, ProcessM, spawn, receive)
import Erl.Process.Raw as Raw
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.MIDI (MIDIClient, MIDIConfig, startClient, scheduleDrumOnChannel)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Event(..), Pattern, Arc(..))
import Tidal.Scheduler (sendAfter, currentTimeMs, TrackInfo, Msg(..))

-- | MIDI scheduler configuration
type MIDISchedulerConfig =
  { bpm :: Number           -- Beats per minute
  , lookAhead :: Number     -- Look-ahead in ms
  , scheduleInterval :: Int -- Tick interval in ms
  , midi :: MIDIConfig      -- MIDI output config
  , noteMap :: Map String Int  -- Sample name -> MIDI note
  , noteDuration :: Int     -- Note duration in ms
  }

-- | A parsed track with its pattern and channel
type ParsedTrack = { pattern :: Pattern String, channel :: Int }

-- | Internal state
type MIDISchedulerState =
  { config :: MIDISchedulerConfig
  , startTime :: Milliseconds
  , nextCycle :: R.Rational
  , tracks :: Array ParsedTrack  -- Multiple tracks, each with own channel
  , midiClient :: MIDIClient
  , lastTrigger :: R.Rational  -- Avoid double-triggering (global for simplicity)
  }

-- | Default drum map (General MIDI drum notes)
-- | Maps Tidal sample names to GM drum notes
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
  , Tuple "tom" 45
  , Tuple "mt" 47    -- Mid Tom
  , Tuple "ht" 50    -- High Tom
  , Tuple "cy" 49    -- Crash Cymbal
  , Tuple "crash" 49
  , Tuple "rd" 51    -- Ride Cymbal
  , Tuple "ride" 51
  , Tuple "cb" 56    -- Cowbell
  , Tuple "~" 0      -- Silence (no note)
  ]

-- | Convert sample name to MIDI note
sampleToNote :: Map String Int -> String -> Int
sampleToNote noteMap sample =
  fromMaybe 60 (Map.lookup sample noteMap)  -- Default to middle C

-- | Parse a TrackInfo into a ParsedTrack
parseTrack :: TrackInfo -> Maybe ParsedTrack
parseTrack { pattern: patStr, channel } =
  case parse patStr of
    Right ast -> Just { pattern: tpatToPattern ast, channel }
    Left _ -> Nothing

-- | Start MIDI scheduler
startMIDIScheduler :: MIDISchedulerConfig -> String -> Effect (Process Msg)
startMIDIScheduler config patternStr = do
  midiClient <- startClient config.midi
  spawn do
    startTime <- liftEffect currentTimeMs

    -- Initialize with a single track using default channel
    let initialTrack = case parse patternStr of
          Right ast -> [{ pattern: tpatToPattern ast, channel: config.midi.channel }]
          Left _ -> []

    stateRef <- liftEffect $ Ref.new
      { config
      , startTime
      , nextCycle: zero
      , tracks: initialTrack
      , midiClient
      , lastTrigger: R.fromInt (-1)
      }

    liftEffect $ log $ "MIDI Scheduler started"
    liftEffect $ log $ "Device: " <> config.midi.device
    liftEffect $ log $ "BPM: " <> show config.bpm
    liftEffect $ log $ "Pattern: " <> patternStr

    pid <- liftEffect Raw.self
    liftEffect $ sendAfter config.scheduleInterval pid Tick

    midiSchedulerLoop stateRef

-- | Main loop
midiSchedulerLoop :: Ref MIDISchedulerState -> ProcessM Msg Unit
midiSchedulerLoop stateRef = do
  msg <- receive
  case msg of
    Tick -> do
      state <- liftEffect $ Ref.read stateRef
      now <- liftEffect currentTimeMs

      -- 1 cycle = 1 bar = 4 beats, so multiply by 4
      let cycleDurationMs = 240000.0 / state.config.bpm
      let elapsedMs = case now, state.startTime of
            Milliseconds n, Milliseconds s -> n - s

      let currentCycle = elapsedMs / cycleDurationMs
      let lookAheadCycles = state.config.lookAhead / cycleDurationMs
      let endCycle = currentCycle + lookAheadCycles

      let fromCycleNum = max (R.toNumber state.nextCycle) currentCycle
      let toCycleNum = endCycle
      let fromCycle = R.fromInt (Int.floor fromCycleNum)
      let toCycle = R.fromInt (Int.floor toCycleNum + 1)

      when (fromCycle < toCycle) do
        -- Iterate over all tracks, scheduling each on its own channel
        for_ state.tracks \track -> do
          let events = queryArc track.pattern fromCycle toCycle
          for_ events \event -> do
            let eventCycle = eventStartCycle event
            let sample = eventSample event

            -- Trigger if in window and not already triggered
            when (eventCycle >= fromCycle && eventCycle < toCycle && eventCycle > state.lastTrigger) do
              let note = sampleToNote state.config.noteMap sample
              when (note > 0) do
                -- Calculate when this event should play
                let eventCycleNum = R.toNumber eventCycle
                let eventTimeMs = eventCycleNum * cycleDurationMs
                let delayMs = eventTimeMs - elapsedMs
                let delayInt = max 0 (Int.floor delayMs)

                liftEffect $ log $ "  ♪ " <> sample <> " → ch" <> show track.channel <> " note " <> show note <> " in " <> show delayInt <> "ms"
                liftEffect $ scheduleDrumOnChannel state.midiClient track.channel note state.config.midi.defaultVelocity state.config.noteDuration delayInt

              -- Update last trigger
              liftEffect $ Ref.modify_ (_ { lastTrigger = eventCycle }) stateRef

      liftEffect $ Ref.modify_ (_ { nextCycle = toCycle }) stateRef

      pid <- liftEffect Raw.self
      liftEffect $ sendAfter state.config.scheduleInterval pid Tick
      midiSchedulerLoop stateRef

    UpdatePattern patStr -> do
      -- Legacy: single pattern, use first track's channel or default
      state <- liftEffect $ Ref.read stateRef
      let channel = case Array.head state.tracks of
            Just t -> t.channel
            Nothing -> state.config.midi.channel
      let newTracks = case parse patStr of
            Right ast -> [{ pattern: tpatToPattern ast, channel }]
            Left _ -> state.tracks
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr
      midiSchedulerLoop stateRef

    UpdatePatternWithChannel patStr newChannel -> do
      -- Single pattern with specific channel
      state <- liftEffect $ Ref.read stateRef
      let newTracks = case parse patStr of
            Right ast -> [{ pattern: tpatToPattern ast, channel: newChannel }]
            Left _ -> state.tracks
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr <> " (channel " <> show newChannel <> ")"
      midiSchedulerLoop stateRef

    UpdateTracks trackInfos -> do
      -- Multiple tracks, each with own channel
      state <- liftEffect $ Ref.read stateRef
      let newTracks = Array.mapMaybe parseTrack trackInfos
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Tracks updated: " <> show (Array.length newTracks) <> " tracks"
      for_ newTracks \t -> liftEffect $ log $ "  - channel " <> show t.channel
      midiSchedulerLoop stateRef

    Stop -> do
      liftEffect $ log "MIDI Scheduler stopped"

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
