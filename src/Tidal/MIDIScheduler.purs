-- | MIDI-enabled scheduler for Tidal patterns
-- |
-- | Maps sample names to MIDI notes and sends them via sendmidi
-- | Also sends gate triggers via OSC to SuperCollider for CV output
module Tidal.MIDIScheduler
  ( MIDISchedulerConfig
  , GateConfig
  , startMIDIScheduler
  , sampleToNote
  , defaultDrumMap
  , defaultGateConfig
  , defaultSampleGateMap
  , defaultSampleCVMap
  , voctValue
  , noteEntry
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int (floor, toNumber) as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number (fromString) as Number
import Data.Rational (Rational, fromInt, toNumber) as R
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Erl.Process (Process, ProcessM, spawn, receive)
import Erl.Process.Raw as Raw
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.MIDI (MIDIClient, MIDIConfig, startClient, scheduleDrumOnChannel)
import Tidal.OSC as OSC
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Event(..), Pattern, Arc(..))
import Tidal.Scheduler (sendAfter, currentTimeMs, TrackInfo, Msg(..))

-- | Gate output configuration (for Expert Sleepers ES-9 via cv-router)
type GateConfig =
  { enabled :: Boolean      -- Whether to send gates
  , oscHost :: String       -- cv-router host
  , oscPort :: Int          -- cv-router OSC port
  , channelOffset :: Int    -- Fallback gate channel = MIDI channel - 10 + offset
                            -- (used when the sample isn't in sampleGateMap)
  , gateDuration :: Number  -- Gate duration in ms
  , sampleGateMap :: Map String Int
                            -- Sample name -> gate channel. Lookup wins over
                            -- the channelOffset arithmetic when present, so
                            -- `bd sn hh cp` fans out to distinct cv-router
                            -- channels even on a single track.
  , sampleCVMap :: Map String { bus :: Int, value :: Number }
                            -- Sample name -> (bus, CV value). When a token
                            -- has a CV mapping, the scheduler emits a /cv
                            -- update on `bus` set to `value` shortly before
                            -- the gate trigger, so destinations like Plaits
                            -- V/oct have the pitch settled by the time the
                            -- trigger arrives. The same token can also have
                            -- a sampleGateMap entry — typical pairing for
                            -- pitched-voice modules: note name → V/oct CV +
                            -- trigger gate channel.
  , cvLeadMs :: Number      -- How many ms before the gate trigger to send
                            -- the CV update. ~5 ms is enough for V/oct to
                            -- settle on most modules.
  }

-- | Default gate configuration (disabled by default)
defaultGateConfig :: GateConfig
defaultGateConfig =
  { enabled: false
  , oscHost: "127.0.0.1"
  , oscPort: 57120
  , channelOffset: 0        -- Channel 10 -> gate 0, channel 11 -> gate 1, etc.
  , gateDuration: 50.0      -- 50ms gate pulse
  , sampleGateMap: defaultSampleGateMap
  , sampleCVMap: defaultSampleCVMap
  , cvLeadMs: 5.0           -- Send V/oct 5ms before the gate trigger
  }

-- | Default sample-name -> gate channel.
-- |
-- | Maps GM-drum aliases (used by `defaultDrumMap`) to channels 0..5/7,
-- | and one octave of note names (`c4 cs4 d4 ds4 e4 f4 fs4 g4 gs4 a4
-- | as4 b4 c5`) to channel 6 — Plaits' trigger input on jack 7. The
-- | accompanying `defaultSampleCVMap` sends V/oct on bus 15 (jack 8)
-- | for the same note names so Plaits plays the right pitch.
-- |
-- | Channel 0 lines up with ES-9 panel jack 1 (cv-router buses 8-15
-- | are panel jacks 1-8, and the cv-router OSC protocol indexes 0..7
-- | within that block).
defaultSampleGateMap :: Map String Int
defaultSampleGateMap = Map.fromFoldable $
  [ Tuple "bd"    0
  , Tuple "kick"  0
  , Tuple "sn"    1
  , Tuple "snare" 1
  , Tuple "hh"    2
  , Tuple "hihat" 2
  , Tuple "ho"    3
  , Tuple "oh"    3
  , Tuple "cp"    3
  , Tuple "clap"  3
  , Tuple "rim"   4
  , Tuple "lt"    5
  , Tuple "tom"   5
  , Tuple "mt"    5
  , Tuple "ht"    6
  , Tuple "cy"    7
  , Tuple "crash" 7
  , Tuple "rd"    7
  , Tuple "ride"  7
  ]
  -- note-name tokens trigger Plaits (gate ch 6 = panel jack 7)
  <> map (\n -> Tuple n 6)
       [ "c3", "cs3", "d3", "ds3", "e3", "f3", "fs3", "g3", "gs3", "a3", "as3", "b3"
       , "c4", "cs4", "d4", "ds4", "e4", "f4", "fs4", "g4", "gs4", "a4", "as4", "b4"
       , "c5", "cs5", "d5", "ds5", "e5", "f5", "fs5", "g5", "gs5", "a5", "as5", "b5"
       , "c6"
       ]

-- | Convert a MIDI note number to a digital CV value at 1V/octave on
-- | the ES-9's ±10V → digital ±1.0 scale: `value = midiNote / 120.0`.
-- | Examples: MIDI 0 (C-1) → 0.0 (0V), MIDI 60 (C4 / middle C) → 0.5
-- | (5V), MIDI 120 (C9) → 1.0 (10V).
voctValue :: Int -> Number
voctValue midiNote = Int.toNumber midiNote / 120.0

-- | Build a (sample-name, sampleCVMap entry) tuple for a pitched voice.
-- | `noteEntry "c4" 60 15` gives `Tuple "c4" { bus: 15, value: 0.5 }`.
noteEntry :: String -> Int -> Int -> Tuple String { bus :: Int, value :: Number }
noteEntry name midiNote bus = Tuple name { bus, value: voctValue midiNote }

-- | Default sample-name -> CV (bus, value).
-- |
-- | Three octaves of note names (C3..C6) mapped to V/oct on bus 15
-- | (= ES-9 panel jack 8 in the standard cv-router layout). Used in
-- | tandem with `defaultSampleGateMap` which sends those same tokens
-- | to gate channel 6 (jack 7). Together: `c4 e4 g4 c5` triggers
-- | Plaits on each step with the corresponding pitch.
defaultSampleCVMap :: Map String { bus :: Int, value :: Number }
defaultSampleCVMap = Map.fromFoldable
  [ noteEntry "c3"  48 15, noteEntry "cs3" 49 15, noteEntry "d3"  50 15
  , noteEntry "ds3" 51 15, noteEntry "e3"  52 15, noteEntry "f3"  53 15
  , noteEntry "fs3" 54 15, noteEntry "g3"  55 15, noteEntry "gs3" 56 15
  , noteEntry "a3"  57 15, noteEntry "as3" 58 15, noteEntry "b3"  59 15
  , noteEntry "c4"  60 15, noteEntry "cs4" 61 15, noteEntry "d4"  62 15
  , noteEntry "ds4" 63 15, noteEntry "e4"  64 15, noteEntry "f4"  65 15
  , noteEntry "fs4" 66 15, noteEntry "g4"  67 15, noteEntry "gs4" 68 15
  , noteEntry "a4"  69 15, noteEntry "as4" 70 15, noteEntry "b4"  71 15
  , noteEntry "c5"  72 15, noteEntry "cs5" 73 15, noteEntry "d5"  74 15
  , noteEntry "ds5" 75 15, noteEntry "e5"  76 15, noteEntry "f5"  77 15
  , noteEntry "fs5" 78 15, noteEntry "g5"  79 15, noteEntry "gs5" 80 15
  , noteEntry "a5"  81 15, noteEntry "as5" 82 15, noteEntry "b5"  83 15
  , noteEntry "c6"  84 15
  ]

-- | MIDI scheduler configuration
type MIDISchedulerConfig =
  { bpm :: Number           -- Beats per minute
  , lookAhead :: Number     -- Look-ahead in ms
  , scheduleInterval :: Int -- Tick interval in ms
  , midi :: MIDIConfig      -- MIDI output config
  , noteMap :: Map String Int  -- Sample name -> MIDI note
  , noteDuration :: Int     -- Note duration in ms
  , gate :: GateConfig      -- Gate output config (optional)
  }

-- | A parsed track. Two flavors:
-- |   GateTrack — sample-name pattern fires gates (and optional pre-set CVs
-- |     via sampleCVMap) at a given gate channel.
-- |   CVTrack — numeric pattern emits sustained /cv updates on a bus. Tokens
-- |     are parsed lazily from String to Number; non-numeric tokens
-- |     (including "~" for rest) skip the emit.
data ParsedTrack
  = GateTrack { pattern :: Pattern String, channel :: Int }
  | CVTrack   { pattern :: Pattern String, bus :: Int }

-- | Internal state
type MIDISchedulerState =
  { config :: MIDISchedulerConfig
  , startTime :: Milliseconds
  , nextCycle :: R.Rational
  , tracks :: Array ParsedTrack  -- Multiple tracks, each with own channel
  , midiClient :: MIDIClient
  , oscClient :: Maybe OSC.OSCClient  -- For gate output (if enabled)
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

-- | Parse a TrackInfo into a GateTrack (legacy multi-track update path).
parseTrack :: TrackInfo -> Maybe ParsedTrack
parseTrack { pattern: patStr, channel } =
  case parse patStr of
    Right ast -> Just (GateTrack { pattern: tpatToPattern ast, channel })
    Left _ -> Nothing

-- | Start MIDI scheduler
startMIDIScheduler :: MIDISchedulerConfig -> String -> Effect (Process Msg)
startMIDIScheduler config patternStr = do
  midiClient <- startClient config.midi

  -- Initialize OSC client if gate output is enabled
  oscClient <- if config.gate.enabled
    then do
      client <- OSC.startClient { host: config.gate.oscHost, port: config.gate.oscPort }
      pure (Just client)
    else pure Nothing

  spawn do
    startTime <- liftEffect currentTimeMs

    -- Initialize with a single gate track using default channel
    let initialTrack = case parse patternStr of
          Right ast -> [GateTrack { pattern: tpatToPattern ast, channel: config.midi.channel }]
          Left _ -> []

    stateRef <- liftEffect $ Ref.new
      { config
      , startTime
      , nextCycle: zero
      , tracks: initialTrack
      , midiClient
      , oscClient
      , lastTrigger: R.fromInt (-1)
      }

    liftEffect $ log $ "MIDI Scheduler started"
    liftEffect $ log $ "Device: " <> config.midi.device
    liftEffect $ log $ "BPM: " <> show config.bpm
    liftEffect $ log $ "Pattern: " <> patternStr
    when config.gate.enabled do
      liftEffect $ log $ "Gate output: enabled (OSC " <> config.gate.oscHost <> ":" <> show config.gate.oscPort <> ")"

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
        -- Iterate over all tracks. GateTrack and CVTrack are dispatched
        -- separately: GateTrack fires sample-name → MIDI + gate (with
        -- optional V/oct pre-set); CVTrack parses tokens as Number and
        -- emits sustained /cv updates on its bus. Independent cycle
        -- lengths between tracks are fine — Tidal's queryArc is
        -- pattern-relative, so different patterns drift in/out of phase
        -- naturally.
        for_ state.tracks \track -> do
          let pattern = case track of
                GateTrack g -> g.pattern
                CVTrack c -> c.pattern
          let events = queryArc pattern fromCycle toCycle
          for_ events \event -> do
            let eventCycle = eventStartCycle event
            let token = eventSample event

            when (eventCycle >= fromCycle && eventCycle < toCycle) do
              let eventCycleNum = R.toNumber eventCycle
              let eventTimeMs = eventCycleNum * cycleDurationMs
              let delayMs = eventTimeMs - elapsedMs
              let delayInt = max 0 (Int.floor delayMs)
              let delayClamped = max 0.0 delayMs

              case track of
                GateTrack g ->
                  when (eventCycle > state.lastTrigger) do
                    let note = sampleToNote state.config.noteMap token
                    when (note > 0) do
                      liftEffect $ log $ "  ♪ " <> token <> " → ch" <> show g.channel <> " note " <> show note <> " in " <> show delayInt <> "ms"
                      liftEffect $ scheduleDrumOnChannel state.midiClient g.channel note state.config.midi.defaultVelocity state.config.noteDuration delayInt
                      when state.config.gate.enabled do
                        case state.oscClient of
                          Just osc -> do
                            let gateChannel = case Map.lookup token state.config.gate.sampleGateMap of
                                  Just gc -> gc
                                  Nothing -> g.channel - 10 + state.config.gate.channelOffset
                            when (gateChannel >= 0 && gateChannel < 8) do
                              -- Pre-set CV (V/oct etc.) before the gate trigger
                              case Map.lookup token state.config.gate.sampleCVMap of
                                Just { bus, value } -> do
                                  let cvDelay = max 0.0 (delayClamped - state.config.gate.cvLeadMs)
                                  liftEffect $ log $ "  🎛 " <> token <> " → CV bus " <> show bus <> " = " <> show value <> " in " <> show (Int.floor cvDelay) <> "ms"
                                  liftEffect $ OSC.sendCVAfter osc bus value cvDelay
                                Nothing -> pure unit
                              liftEffect $ log $ "  ⚡ " <> token <> " → gate " <> show gateChannel <> " in " <> show delayInt <> "ms (dur " <> show state.config.gate.gateDuration <> "ms)"
                              liftEffect $ OSC.sendGateTrigAfter osc gateChannel state.config.gate.gateDuration delayClamped
                          Nothing -> pure unit
                    liftEffect $ Ref.modify_ (_ { lastTrigger = eventCycle }) stateRef

                CVTrack c ->
                  -- CVTrack tokens are numeric; non-numeric (incl. ~ rest)
                  -- skip the emit and the bus stays at its last value (S&H).
                  case Number.fromString token of
                    Just value -> case state.oscClient of
                      Just osc -> do
                        liftEffect $ log $ "  〰 cv bus " <> show c.bus <> " = " <> show value <> " in " <> show delayInt <> "ms"
                        liftEffect $ OSC.sendCVAfter osc c.bus value delayClamped
                      Nothing -> pure unit
                    Nothing -> pure unit

      liftEffect $ Ref.modify_ (_ { nextCycle = toCycle }) stateRef

      pid <- liftEffect Raw.self
      liftEffect $ sendAfter state.config.scheduleInterval pid Tick
      midiSchedulerLoop stateRef

    UpdatePattern patStr -> do
      -- Legacy: single gate pattern. Replaces ALL existing tracks (gate + CV)
      -- with one gate track using the first existing gate-track's channel
      -- or the default. Use UpdateGateTrack/UpdateCVTrack for the live-coding
      -- shape (per-track replacement).
      state <- liftEffect $ Ref.read stateRef
      let firstGateChannel = Array.findMap (case _ of
            GateTrack g -> Just g.channel
            _ -> Nothing) state.tracks
      let channel = fromMaybe state.config.midi.channel firstGateChannel
      let newTracks = case parse patStr of
            Right ast -> [GateTrack { pattern: tpatToPattern ast, channel }]
            Left _ -> state.tracks
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr
      midiSchedulerLoop stateRef

    UpdatePatternWithChannel patStr newChannel -> do
      -- Single gate pattern, replaces all existing tracks.
      state <- liftEffect $ Ref.read stateRef
      let newTracks = case parse patStr of
            Right ast -> [GateTrack { pattern: tpatToPattern ast, channel: newChannel }]
            Left _ -> state.tracks
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr <> " (channel " <> show newChannel <> ")"
      midiSchedulerLoop stateRef

    UpdateGateTrack ch patStr -> do
      -- Replace just the gate track at this channel; leave others untouched.
      state <- liftEffect $ Ref.read stateRef
      case parse patStr of
        Right ast -> do
          let newTrack = GateTrack { pattern: tpatToPattern ast, channel: ch }
          let isOther = case _ of
                GateTrack g -> g.channel /= ch
                CVTrack _ -> true
          let newTracks = Array.filter isOther state.tracks <> [newTrack]
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ "gate ch " <> show ch <> ": " <> patStr
        Left _ ->
          liftEffect $ log $ "gate parse error: " <> patStr
      midiSchedulerLoop stateRef

    UpdateCVTrack bus patStr -> do
      -- Replace just the CV track at this bus; leave others untouched.
      state <- liftEffect $ Ref.read stateRef
      case parse patStr of
        Right ast -> do
          let newTrack = CVTrack { pattern: tpatToPattern ast, bus }
          let isOther = case _ of
                CVTrack c -> c.bus /= bus
                GateTrack _ -> true
          let newTracks = Array.filter isOther state.tracks <> [newTrack]
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ "cv bus " <> show bus <> ": " <> patStr
        Left _ ->
          liftEffect $ log $ "cv parse error: " <> patStr
      midiSchedulerLoop stateRef

    UpdateTracks trackInfos -> do
      -- Multiple tracks, each with own channel — interpreted as gate tracks.
      state <- liftEffect $ Ref.read stateRef
      let newTracks = Array.mapMaybe parseTrack trackInfos
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Tracks updated: " <> show (Array.length newTracks) <> " tracks"
      for_ newTracks \t -> case t of
        GateTrack g -> liftEffect $ log $ "  - gate ch " <> show g.channel
        CVTrack c -> liftEffect $ log $ "  - cv bus " <> show c.bus
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
