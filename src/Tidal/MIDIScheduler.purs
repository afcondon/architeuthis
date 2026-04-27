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
import Tidal.Binding as Binding
import Tidal.MIDI (MIDIClient, MIDIConfig, startClient, scheduleDrumOnChannel, scheduleNoteOnDevice, scheduleCCOnDevice)
import Tidal.OSC as OSC
import Tidal.Transform (Transform(..), applyTransforms)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Event(..), Pattern, Arc(..))
import Tidal.Scheduler (sendAfter, currentTimeMs, TrackInfo, Msg(..), TransformSpec(..))

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
-- |     `fanout = true`  → legacy semantics: sample name selects gate channel
-- |       via sampleGateMap (e.g. `bd → 0, sn → 1`). Used by `UpdatePattern` /
-- |       `UpdateTracks` so old single-pattern strings keep working.
-- |     `fanout = false` → prefix semantics: the channel field is taken
-- |       literally regardless of sample name. Used by `UpdateGateTrack` so
-- |       `gate 7 bd*4` fires on gate 7, not whatever `bd` maps to.
-- |   CVTrack — numeric pattern emits sustained /cv updates on a bus. Tokens
-- |     are parsed lazily from String to Number; non-numeric tokens
-- |     (including "~" for rest) skip the emit.
data ParsedTrack
  = GateTrack { pattern :: Pattern String, channel :: Int, fanout :: Boolean }
  | CVTrack   { pattern :: Pattern String, bus :: Int, transforms :: Array Transform }
  -- | ESX-8CV track on cv-router's Silent Way encoder. `slot` is 0..7,
  -- | one per ESX-8CV physical output. Tokens are numeric (-1.0..1.0).
  -- | `transforms` is a left-to-right pipe of value transforms applied
  -- | after the Tidal parser produces each numeric value: e.g. `[Offset
  -- | (-0.5)]` shifts an unsigned [0..1] LFO into bipolar [-0.5..0.5].
  | ESXTrack  { pattern :: Pattern String, slot :: Int, transforms :: Array Transform }
  -- | A pattern dispatched via a named binding. The binding is a list of
  -- | PrimActions; each pattern event fires every action. Replaces the
  -- | hardcoded `gate <ch>` / `cv <bus>` dispatch when the user has
  -- | registered a name like `kick` or `plaits`.
  | BoundTrack { pattern :: Pattern String, name :: String, binding :: Binding.Binding }
  -- | FH-2 trigger track. Each pattern token fires a MIDI note on the FH-2
  -- | for the given voice. The voice's MIDI channel is looked up from
  -- | `state.fh2VoiceChannels` at dispatch time (registered via
  -- | `fh2-envelope`). Note name in the token (e.g. `c4`) overrides the
  -- | default trigger note; bare tokens (e.g. `bd`) fall back to MIDI 60.
  | Fh2TriggerTrack { pattern :: Pattern String, voice :: Int }

-- | Internal state
type MIDISchedulerState =
  { config :: MIDISchedulerConfig
  , startTime :: Milliseconds
  , nextCycle :: R.Rational
  , tracks :: Array ParsedTrack  -- Multiple tracks, each with own channel
  , midiClient :: MIDIClient
  , oscClient :: Maybe OSC.OSCClient  -- For gate output (if enabled)
  , lastTrigger :: R.Rational  -- Avoid double-triggering (global for simplicity)
  , bindings :: Binding.BindingRegistry  -- Named-action registry (kick, plaits, …)
  , slots :: Map String Number           -- Param/input slot env (modulation values)
  , midiDevices :: Map String { name :: String, latencyMs :: Number }
                                          -- alias → device-name + latency offset.
                                          -- Latency is subtracted from the delay
                                          -- at dispatch so slow destinations fire
                                          -- on-time relative to the scheduler's tick.
  , fh2VoiceChannels :: Map Int Int       -- FH-2 voice id → MIDI channel.
                                          -- Populated by `fh2-envelope`;
                                          -- consumed by `fh2-trigger`.
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
    Right ast -> Just (GateTrack { pattern: tpatToPattern ast, channel, fanout: true })
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
          Right ast -> [GateTrack { pattern: tpatToPattern ast, channel: config.midi.channel, fanout: true }]
          Left _ -> []

    stateRef <- liftEffect $ Ref.new
      { config
      , startTime
      , nextCycle: zero
      , tracks: initialTrack
      , midiClient
      , oscClient
      , lastTrigger: R.fromInt (-1)
      , bindings: Binding.defaultRegistry
      , slots: Map.empty
      , midiDevices: Map.empty
      , fh2VoiceChannels: Map.empty
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
                ESXTrack e -> e.pattern
                BoundTrack b -> b.pattern
                Fh2TriggerTrack f -> f.pattern
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
                            let gateChannel =
                                  if g.fanout
                                    -- Legacy: sample-name fanout via sampleGateMap;
                                    -- fall back to MIDI-channel-to-gate translation.
                                    then case Map.lookup token state.config.gate.sampleGateMap of
                                      Just gc -> gc
                                      Nothing -> g.channel - 10 + state.config.gate.channelOffset
                                    -- Prefix path: take channel literally.
                                    else g.channel
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
                  -- `transforms` (e.g. [Offset -0.5]) apply post-parse.
                  case Number.fromString token of
                    Just raw -> case state.oscClient of
                      Just osc -> do
                        let value = applyTransforms c.transforms raw
                        liftEffect $ log $ "  〰 cv bus " <> show c.bus <> " = " <> show value <> " in " <> show delayInt <> "ms"
                        liftEffect $ OSC.sendCVAfter osc c.bus value delayClamped
                      Nothing -> pure unit
                    Nothing -> pure unit

                ESXTrack e ->
                  -- ESX-8CV slot — same numeric-pattern semantics as CVTrack
                  -- but reaches cv-router's Silent Way encoder via /esx.
                  case Number.fromString token of
                    Just raw -> case state.oscClient of
                      Just osc -> do
                        let value = applyTransforms e.transforms raw
                        liftEffect $ log $ "  ⌇ esx slot " <> show e.slot <> " = " <> show value <> " in " <> show delayInt <> "ms"
                        liftEffect $ OSC.sendESXAfter osc e.slot value delayClamped
                      Nothing -> pure unit
                    Nothing -> pure unit

                BoundTrack b -> do
                  -- Run the binding's PrimAction list. CVs fire first
                  -- (with cvLeadMs head start) so V/oct settles before
                  -- the gate trigger. MIDI dispatch lives alongside —
                  -- different destinations, same per-event loop.
                  let cvLead = state.config.gate.cvLeadMs
                  let cvDelay = max 0.0 (delayClamped - cvLead)
                  for_ b.binding \action -> case action of
                    Binding.CV bus mapping ->
                      case state.oscClient, interpretCV mapping token of
                        Just osc, Just value -> do
                          liftEffect $ log $ "  〰 [" <> b.name <> "] cv bus " <> show bus <> " = " <> show value
                          liftEffect $ OSC.sendCVAfter osc bus value cvDelay
                        _, _ -> pure unit
                    Binding.ESX slot ->
                      case state.oscClient, Number.fromString token of
                        Just osc, Just value -> do
                          liftEffect $ log $ "  ⌇ [" <> b.name <> "] esx slot " <> show slot <> " = " <> show value
                          liftEffect $ OSC.sendESXAfter osc slot value delayClamped
                        _, _ -> pure unit
                    Binding.Gate ch ->
                      when (token /= "~") do
                        case state.oscClient of
                          Just osc -> do
                            liftEffect $ log $ "  ⚡ [" <> b.name <> "] gate " <> show ch <> " in " <> show delayInt <> "ms"
                            liftEffect $ OSC.sendGateTrigAfter osc ch state.config.gate.gateDuration delayClamped
                          Nothing -> pure unit
                    Binding.MidiNote m ->
                      when (token /= "~") do
                        case Map.lookup m.device state.midiDevices of
                          Nothing ->
                            liftEffect $ log $ "  ✗ [" <> b.name <> "] midi-note: unknown device alias '" <> m.device <> "'"
                          Just dev -> do
                            -- Token can override the binding's defaultNote with
                            -- a note name (c4, e4, etc.). Falls back to the
                            -- binding's defaultNote for trigger-style tokens
                            -- (bd, sn, etc.) so drum patterns work.
                            let note = case Map.lookup token noteNameMidi of
                                  Just n -> n
                                  Nothing -> m.defaultNote
                            -- Latency compensation: emit earlier by the
                            -- device's reported latency so this destination
                            -- arrives in unison with faster ones.
                            let adjustedDelay = max 0 (Int.floor (delayClamped - dev.latencyMs))
                            liftEffect $ log $ "  ♪ [" <> b.name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " note " <> show note <> " (dur " <> show m.durationMs <> "ms) in " <> show adjustedDelay <> "ms"
                            liftEffect $ scheduleNoteOnDevice dev.name m.channel note m.velocity m.durationMs adjustedDelay
                    Binding.MidiCC m ->
                      case Number.fromString token of
                        Nothing -> pure unit  -- ~ rest or non-numeric → skip
                        Just raw ->
                          case Map.lookup m.device state.midiDevices of
                            Nothing ->
                              liftEffect $ log $ "  ✗ [" <> b.name <> "] midi-cc: unknown device alias '" <> m.device <> "'"
                            Just dev -> do
                              -- Pattern values 0..1 → MIDI 0..127. Clamp to
                              -- safe range; CC values >127 or <0 silently
                              -- truncated by sendmidi anyway, but explicit
                              -- clamp gives predictable behaviour.
                              let value7bit = clamp7bit (raw * 127.0)
                              let adjustedDelay = max 0 (Int.floor (delayClamped - dev.latencyMs))
                              liftEffect $ log $ "  ◇ [" <> b.name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " cc" <> show m.cc <> " = " <> show value7bit
                              liftEffect $ scheduleCCOnDevice dev.name m.channel m.cc value7bit adjustedDelay

                Fh2TriggerTrack f ->
                  -- Look up the voice's MIDI channel. If unregistered (user
                  -- forgot `fh2-envelope`), log once and skip.
                  when (token /= "~") do
                    case Map.lookup f.voice state.fh2VoiceChannels of
                      Nothing ->
                        liftEffect $ log $ "  ✗ fh2-trigger voice " <> show f.voice <> ": no fh2-envelope registration; skipping"
                      Just channel -> do
                        -- Pattern token can override the trigger note (so
                        -- `fh2-trigger 0 "c4 e4 g4"` plays a melody and the
                        -- FH-2's mcv pitch CV tracks). Plain trigger tokens
                        -- (`bd`, `1`, `x`) fall back to MIDI 60 = C4.
                        let note = case Map.lookup token noteNameMidi of
                              Just n -> n
                              Nothing -> 60
                        -- Use the same fh2 latency record if registered,
                        -- otherwise zero. Lets the user calibrate the FH-2
                        -- via `midi-device fh2 FH-2 lat <ms>` without
                        -- changing the verb shape.
                        let dev = fromMaybe { name: "FH-2", latencyMs: 0.0 }
                                    (Map.lookup "fh2" state.midiDevices)
                        let adjustedDelay = max 0 (Int.floor (delayClamped - dev.latencyMs))
                        liftEffect $ log $ "  ♪ fh2-trigger v" <> show f.voice <> " → " <> dev.name <> " ch" <> show channel <> " note " <> show note <> " in " <> show adjustedDelay <> "ms"
                        liftEffect $ scheduleNoteOnDevice dev.name channel note 100 100 adjustedDelay

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
            Right ast -> [GateTrack { pattern: tpatToPattern ast, channel, fanout: true }]
            Left _ -> state.tracks
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr
      midiSchedulerLoop stateRef

    UpdatePatternWithChannel patStr newChannel -> do
      -- Single gate pattern, replaces all existing tracks.
      state <- liftEffect $ Ref.read stateRef
      let newTracks = case parse patStr of
            Right ast -> [GateTrack { pattern: tpatToPattern ast, channel: newChannel, fanout: true }]
            Left _ -> state.tracks
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "Pattern updated: " <> patStr <> " (channel " <> show newChannel <> ")"
      midiSchedulerLoop stateRef

    UpdateGateTrack ch patStr -> do
      -- Replace just the gate track at this channel; leave others untouched.
      state <- liftEffect $ Ref.read stateRef
      case parse patStr of
        Right ast -> do
          let newTrack = GateTrack { pattern: tpatToPattern ast, channel: ch, fanout: false }
          let isOther = case _ of
                GateTrack g -> g.channel /= ch
                _           -> true
          let newTracks = Array.filter isOther state.tracks <> [newTrack]
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ "gate ch " <> show ch <> ": " <> patStr
        Left _ ->
          liftEffect $ log $ "gate parse error: " <> patStr
      midiSchedulerLoop stateRef

    UpdateCVTrack bus patStr specs -> do
      -- Replace just the CV track at this bus; leave others untouched.
      state <- liftEffect $ Ref.read stateRef
      case parse patStr of
        Right ast -> do
          let transforms = map specToTransform specs
          let newTrack = CVTrack { pattern: tpatToPattern ast, bus, transforms }
          let isOther = case _ of
                CVTrack c -> c.bus /= bus
                _         -> true
          let newTracks = Array.filter isOther state.tracks <> [newTrack]
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ "cv bus " <> show bus <> ": " <> patStr <> showTransforms transforms
        Left _ ->
          liftEffect $ log $ "cv parse error: " <> patStr
      midiSchedulerLoop stateRef

    UpdateESXTrack slot patStr specs -> do
      -- Replace just the ESX-8CV track at this slot; leave others untouched.
      state <- liftEffect $ Ref.read stateRef
      case parse patStr of
        Right ast -> do
          let transforms = map specToTransform specs
          let newTrack = ESXTrack { pattern: tpatToPattern ast, slot, transforms }
          let isOther = case _ of
                ESXTrack e -> e.slot /= slot
                _          -> true
          let newTracks = Array.filter isOther state.tracks <> [newTrack]
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ "esx slot " <> show slot <> ": " <> patStr <> showTransforms transforms
        Left _ ->
          liftEffect $ log $ "esx parse error: " <> patStr
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
        ESXTrack e -> liftEffect $ log $ "  - esx slot " <> show e.slot
        BoundTrack b -> liftEffect $ log $ "  - bound: " <> b.name
        Fh2TriggerTrack f -> liftEffect $ log $ "  - fh2-trigger v" <> show f.voice
      midiSchedulerLoop stateRef

    AddBinding name actionSpec -> do
      state <- liftEffect $ Ref.read stateRef
      case Binding.parseCompoundAction actionSpec of
        Left err ->
          liftEffect $ log $ "bind " <> name <> ": ✗ " <> err
        Right binding -> do
          let newRegistry = Map.insert name binding state.bindings
          liftEffect $ Ref.write (state { bindings = newRegistry }) stateRef
          liftEffect $ log $ "bind " <> name <> ": " <> actionSpec
      midiSchedulerLoop stateRef

    RemoveBinding name -> do
      state <- liftEffect $ Ref.read stateRef
      let newRegistry = Map.delete name state.bindings
      liftEffect $ Ref.write (state { bindings = newRegistry }) stateRef
      liftEffect $ log $ "unbind " <> name
      midiSchedulerLoop stateRef

    PlayByName name patStr fullText -> do
      state <- liftEffect $ Ref.read stateRef
      case Map.lookup name state.bindings of
        Just binding ->
          case parse patStr of
            Left _ ->
              liftEffect $ log $ "play '" <> name <> "' parse error: " <> patStr
            Right ast -> do
              let newTrack = BoundTrack
                    { pattern: tpatToPattern ast
                    , name
                    , binding
                    }
              let isOther = case _ of
                    BoundTrack b -> b.name /= name
                    _            -> true
              let newTracks = Array.filter isOther state.tracks <> [newTrack]
              liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
              liftEffect $ log $ name <> ": " <> patStr
        Nothing -> do
          -- Fallback: treat fullText as a legacy whole-message pattern.
          -- This preserves backward compat for `bd sn hh cp`-style messages
          -- when no binding has shadowed the first word. The legacy path
          -- replaces ALL tracks (gate + CV) with a single GateTrack.
          liftEffect $ log $ "(no binding '" <> name <> "', falling back to legacy pattern)"
          let firstGateChannel = Array.findMap (case _ of
                GateTrack g -> Just g.channel
                _ -> Nothing) state.tracks
          let channel = fromMaybe state.config.midi.channel firstGateChannel
          let newTracks = case parse fullText of
                Right ast -> [GateTrack { pattern: tpatToPattern ast, channel, fanout: true }]
                Left _ -> state.tracks
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ "Pattern updated (legacy): " <> fullText
      midiSchedulerLoop stateRef

    SetSlot name value -> do
      state <- liftEffect $ Ref.read stateRef
      let newSlots = Map.insert name value state.slots
      liftEffect $ Ref.write (state { slots = newSlots }) stateRef
      liftEffect $ log $ "slot " <> name <> " = " <> show value
      midiSchedulerLoop stateRef

    Hush -> do
      -- Tidal-compat: silence everything. Drop all running tracks but
      -- preserve the binding registry so the user can immediately
      -- play a name again without rebinding.
      state <- liftEffect $ Ref.read stateRef
      liftEffect $ Ref.write (state { tracks = [] }) stateRef
      liftEffect $ log "hush"
      midiSchedulerLoop stateRef

    RegisterMidiDevice alias deviceName latencyMs -> do
      state <- liftEffect $ Ref.read stateRef
      let newDevices = Map.insert alias { name: deviceName, latencyMs } state.midiDevices
      liftEffect $ Ref.write (state { midiDevices = newDevices }) stateRef
      liftEffect $ log $ "midi-device " <> alias <> " = " <> deviceName <> " (lat " <> show latencyMs <> "ms)"
      midiSchedulerLoop stateRef

    Fh2Envelope voice _output channel -> do
      -- Record voice → channel mapping so fh2-trigger can resolve the
      -- destination. Auto-register an `fh2` MIDI device alias if absent
      -- (latency 0 by default; user can override via `midi-device fh2 ...
      -- lat N`). The actual SysEx push to configure the FH-2's MCV is
      -- handled by Handler.erl as a fire-and-forget shell-out to
      -- fh2-config — keeps PureScript free of process-spawning.
      state <- liftEffect $ Ref.read stateRef
      let newVoices = Map.insert voice channel state.fh2VoiceChannels
          newDevices = case Map.lookup "fh2" state.midiDevices of
            Just _ -> state.midiDevices
            Nothing -> Map.insert "fh2" { name: "FH-2", latencyMs: 0.0 } state.midiDevices
      liftEffect $ Ref.write
        (state { fh2VoiceChannels = newVoices, midiDevices = newDevices })
        stateRef
      liftEffect $ log $ "fh2-envelope: voice " <> show voice <> " → ch " <> show channel
      midiSchedulerLoop stateRef

    UpdateFh2TriggerTrack voice patStr -> do
      state <- liftEffect $ Ref.read stateRef
      case parse patStr of
        Right ast -> do
          let newTrack = Fh2TriggerTrack { pattern: tpatToPattern ast, voice }
              isOther = case _ of
                Fh2TriggerTrack f -> f.voice /= voice
                _                 -> true
              newTracks = Array.filter isOther state.tracks <> [newTrack]
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ "fh2-trigger v" <> show voice <> ": " <> patStr
        Left _ ->
          liftEffect $ log $ "fh2-trigger v" <> show voice <> " parse error: " <> patStr
      midiSchedulerLoop stateRef

    Stop -> do
      liftEffect $ log "MIDI Scheduler stopped"

-- | Interpret a pattern token according to a CV mapping mode.
-- |   LiteralValue   → parse as Number
-- |   NoteNameVoct   → parse as note name → 1V/oct on ±10V→±1.0 scale
-- |   SampleNameMap  → lookup
interpretCV :: Binding.CVMapping -> String -> Maybe Number
interpretCV = case _ of
  Binding.LiteralValue -> Number.fromString
  Binding.NoteNameVoct -> \tok ->
    case Map.lookup tok noteNameMidi of
      Just midi -> Just (voctValue midi)
      Nothing -> Nothing
  Binding.SampleNameMap m -> \tok -> Map.lookup tok m

-- | Convert a wire-level TransformSpec into a typed Transform for use
-- | by `applyTransforms`. The two types are parallel today; if the
-- | wire spec gains constructors that need richer semantics (e.g. a
-- | spec that references a slot), this is where the translation lives.
specToTransform :: TransformSpec -> Transform
specToTransform = case _ of
  SpecOffset n  -> Offset n
  SpecInvert    -> Invert
  SpecScale a b -> Scale a b

-- | Clamp a Number to MIDI's 7-bit range [0..127] and floor it.
clamp7bit :: Number -> Int
clamp7bit n
  | n < 0.0   = 0
  | n > 127.0 = 127
  | otherwise = Int.floor n

-- | Render a transform pipeline for log output, e.g. "  | offset -0.5".
showTransforms :: Array Transform -> String
showTransforms ts =
  if Array.null ts
    then ""
    else " | " <> Array.intercalate " | " (map showTransform ts)
  where
  showTransform = case _ of
    Offset n  -> "offset " <> show n
    Invert    -> "invert"
    Scale a b -> "scale " <> show a <> " " <> show b

-- | Note name → MIDI number (C-1 = 0, C0 = 12, C4 = 60, etc.).
-- | Covers C3..C6 (the range used by `defaultSampleCVMap` previously).
noteNameMidi :: Map String Int
noteNameMidi = Map.fromFoldable
  [ Tuple "c3" 48,  Tuple "cs3" 49, Tuple "d3" 50,  Tuple "ds3" 51
  , Tuple "e3" 52,  Tuple "f3" 53,  Tuple "fs3" 54, Tuple "g3" 55
  , Tuple "gs3" 56, Tuple "a3" 57,  Tuple "as3" 58, Tuple "b3" 59
  , Tuple "c4" 60,  Tuple "cs4" 61, Tuple "d4" 62,  Tuple "ds4" 63
  , Tuple "e4" 64,  Tuple "f4" 65,  Tuple "fs4" 66, Tuple "g4" 67
  , Tuple "gs4" 68, Tuple "a4" 69,  Tuple "as4" 70, Tuple "b4" 71
  , Tuple "c5" 72,  Tuple "cs5" 73, Tuple "d5" 74,  Tuple "ds5" 75
  , Tuple "e5" 76,  Tuple "f5" 77,  Tuple "fs5" 78, Tuple "g5" 79
  , Tuple "gs5" 80, Tuple "a5" 81,  Tuple "as5" 82, Tuple "b5" 83
  , Tuple "c6" 84
  ]

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
