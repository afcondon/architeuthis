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
  , noteEntry
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int (floor, fromString, toNumber) as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number (fromString) as Number
import Data.String (joinWith) as Str
import Data.String as String
import Data.String.CodeUnits as SCU
import Data.Rational (Rational, fromInt, toNumber) as R
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Tidal.Log as Log
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Erl.Process (Process, ProcessM, spawn, receive)
import Erl.Process.Raw as Raw
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Expr as Expr
import Tidal.Binding as Binding
import Tidal.Dispatch.Helpers (noteNameMidi, voctValue, clamp7bit, samplePatternAt)
import Tidal.Sink as Sink
import Tidal.MIDI (MIDIConfig)
import Tidal.MIDIBridge (BridgeClient, scheduleNoteAt, scheduleCCAt)
import Tidal.MIDIBridge as MIDIBridge
import Tidal.LinkAnchor as LinkAnchor
import Tidal.OSC as OSC
import Tidal.Transform (Transform(..), applyTransforms)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Event(..), Pattern, Arc(..))
import Tidal.Scheduler (sendAfter, currentTimeMs, TrackInfo, Msg(..), TransformSpec(..))
import Tidal.StateBus as StateBus

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
  -- | FH-2 trigger track. Each pattern token fires a MIDI note on the FH-2
  -- | for the given voice. The voice's MIDI channel is looked up from
  -- | `state.fh2VoiceChannels` at dispatch time (registered via
  -- | `fh2-envelope`). Note name in the token (e.g. `c4`) overrides the
  -- | default trigger note; bare tokens (e.g. `bd`) fall back to MIDI 60.
  | Fh2TriggerTrack { pattern :: Pattern String, voice :: Int }

-- | Where a continuous (LFO-style) voice sends its sampled value.
-- |
-- | A continuous voice runs at the scheduler tick rate (one sample per
-- | tick, default 50ms = 20Hz) and emits one MIDI CC or CV update per
-- | sample.
data ContDest
  = ContMidiCC { device :: String, channel :: Int, cc :: Int }
  | ContCV     { bus :: Int, transforms :: Array Transform }

-- | A continuous-sampling voice.  Held in `MIDISchedulerState.continuousTracks`
-- | rather than `tracks` because the pattern type differs (`Pattern Number`
-- | vs the discrete `Pattern String` used by every other track variant).
-- | Each scheduler tick samples the pattern at the current cycle position
-- | and emits one CC/CV value to `dest`.
type ContinuousTrackData =
  { pattern :: Pattern Number
  , name :: String
  , dest :: ContDest
  }

-- | Internal state
type MIDISchedulerState =
  { config :: MIDISchedulerConfig
  , startTime :: Milliseconds
  , nextCycle :: R.Rational
  , tracks :: Array ParsedTrack  -- Multiple tracks, each with own channel
  , continuousTracks :: Array ContinuousTrackData
                                          -- LFO-style voices sampled once
                                          -- per scheduler tick.  Held
                                          -- separately because the pattern
                                          -- type is `Pattern Number`.
  , continuousBindings :: Map String ContDest
                                          -- Registry of named continuous
                                          -- voices (`bind plaits-cutoff
                                          -- midi-cc-cont …`).  When a cell
                                          -- writes `<name> :<expr>` and the
                                          -- name is in this map, the expr
                                          -- evaluates as `Pattern Number`
                                          -- and a `ContinuousTrack` is
                                          -- installed pointing at the
                                          -- recorded `ContDest`.
  , bridgeClient :: BridgeClient        -- UDP socket to link-spike's MIDI dispatcher
  , oscClient :: Maybe OSC.OSCClient  -- For gate output (if enabled)
  , lastTrigger :: R.Rational  -- Avoid double-triggering (global for simplicity)
  , bindings :: Binding.BindingRegistry  -- Named-action registry (kick, plaits, …)
  , sinkTypes :: Map String (Array Sink.SinkType)
                                          -- Inferred typed signature for each
                                          -- binding name (discrete + continuous
                                          -- both end up here).  Populated at
                                          -- AddBinding install; consulted at
                                          -- PlayByName* to type-check the
                                          -- incoming pattern against expected
                                          -- element shape.  An array because a
                                          -- discrete Binding can carry several
                                          -- PrimActions (e.g. plaits = gate +
                                          -- cv-voct); continuous bindings
                                          -- always have a singleton.
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

-- | Convert a `ContDest` into a `SinkType` for the typed registry.
-- | Pure, no I/O — the SinkType captures the same destination info in
-- | a form Sink.checkPattern / Sink.renderSinkType understand.
contDestToSinkType :: ContDest -> Sink.SinkType
contDestToSinkType = case _ of
  ContMidiCC m -> Sink.SinkContMidiCC
    { device: m.device, channel: m.channel, cc: m.cc }
  ContCV c -> Sink.SinkContCV { bus: c.bus }

-- | Inferred sink types for the names installed by `defaultRegistry`.
-- | Every default binding (drum aliases, plaits) gets its types here so
-- | the registry has full coverage from boot, not just for user-installed
-- | bindings.
defaultSinkTypes :: Map String (Array Sink.SinkType)
defaultSinkTypes =
  Map.fromFoldable
    $ map
        (\(Tuple name binding) ->
          Tuple name (Sink.bindingSinkTypes binding))
        (Map.toUnfoldable Binding.defaultRegistry :: Array (Tuple String Binding.Binding))

-- | Parse a TrackInfo into a GateTrack (legacy multi-track update path).
parseTrack :: TrackInfo -> Maybe ParsedTrack
parseTrack { pattern: patStr, channel } =
  case parse patStr of
    Right ast -> Just (GateTrack { pattern: tpatToPattern ast, channel, fanout: true })
    Left _ -> Nothing

-- | Start MIDI scheduler
-- |
-- | NOTE: The bridgeClient and oscClient sockets MUST be opened inside
-- | the spawned scheduler process, not in the calling Main process.
-- | Erlang ports (gen_udp sockets) are linked to their owning process
-- | and close when that process exits. If we opened them out here, the
-- | Main process exiting (after its `sleep` in Main.purs) would close
-- | the sockets while the scheduler kept running with a stale handle —
-- | manifested as `gen_udp:send FAILED: closed` after the sleep
-- | duration.
startMIDIScheduler :: MIDISchedulerConfig -> String -> Effect (Process Msg)
startMIDIScheduler config patternStr = do
  spawn do
    bridgeClient <- liftEffect MIDIBridge.startClient

    oscClient <- liftEffect $
      if config.gate.enabled
        then do
          client <- OSC.startClient { host: config.gate.oscHost, port: config.gate.oscPort }
          pure (Just client)
        else pure Nothing

    startTime <- liftEffect currentTimeMs

    -- Initialize with a single gate track using default channel
    let initialTrack = case parse patternStr of
          Right ast -> [GateTrack { pattern: tpatToPattern ast, channel: config.midi.channel, fanout: true }]
          Left _ -> []

    liftEffect StateBus.init

    stateRef <- liftEffect $ Ref.new
      { config
      , startTime
      , nextCycle: zero
      , tracks: initialTrack
      , continuousTracks: []
      , continuousBindings: Map.empty
      , bridgeClient
      , oscClient
      , lastTrigger: R.fromInt (-1)
      , bindings: Binding.defaultRegistry
      , sinkTypes: defaultSinkTypes
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

-- | Main loop. Each iteration publishes the current state to the
-- | StateBus before blocking on `receive` — that way Calypso's
-- | `state` verb (read via ETS) always sees the post-handle state
-- | of the most recent message. ~20 writes/sec from Tick is fine
-- | (ETS insert of a few-KB binary is sub-microsecond).
midiSchedulerLoop :: Ref MIDISchedulerState -> ProcessM Msg Unit
midiSchedulerLoop stateRef = do
  liftEffect (publishState stateRef)
  msg <- receive
  case msg of
    Tick -> do
      state <- liftEffect $ Ref.read stateRef

      -- Time + tempo source: prefers Link if a fresh anchor is available,
      -- otherwise free-runs from startTime + config.bpm. All policy lives
      -- in Erlang (tidal_link_anchor:scheduler_clock/2) — this scheduler
      -- doesn't know or care which mode it's in.
      clock <- liftEffect $ LinkAnchor.schedulerClock
        { startTimeMs: case state.startTime of Milliseconds m -> m
        , freeRunBpm: state.config.bpm
        }
      let cycleDurationMs = clock.cycleDurationMs
      let elapsedMs = clock.elapsedMs

      -- Capture wall-clock once per tick. Each scheduled event fires at
      -- `nowUnixUs + delayMs * 1000` — link-spike's CoreMIDI dispatcher
      -- consumes Unix microseconds, mirroring the anchor wire format.
      nowUnixUs <- liftEffect LinkAnchor.nowUnixUs

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
              -- Absolute Unix-microsecond fire time for link-spike's
              -- CoreMIDI dispatcher.
              let unixUsAt = nowUnixUs + delayClamped * 1000.0

              case track of
                GateTrack g ->
                  when (eventCycle > state.lastTrigger) do
                    let note = sampleToNote state.config.noteMap token
                    when (note > 0) do
                      liftEffect $ Log.debug $ "♪ " <> token <> " → ch" <> show g.channel <> " note " <> show note <> " in " <> show delayInt <> "ms"
                      liftEffect $ scheduleNoteAt state.bridgeClient state.config.midi.device g.channel note state.config.midi.defaultVelocity state.config.noteDuration unixUsAt
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
                                  liftEffect $ Log.debug $ "🎛 " <> token <> " → CV bus " <> show bus <> " = " <> show value <> " in " <> show (Int.floor cvDelay) <> "ms"
                                  liftEffect $ OSC.sendCVAfter osc bus value cvDelay
                                Nothing -> pure unit
                              liftEffect $ Log.debug $ "⚡ " <> token <> " → gate " <> show gateChannel <> " in " <> show delayInt <> "ms (dur " <> show state.config.gate.gateDuration <> "ms)"
                              liftEffect $ OSC.sendGateTrigAfter osc gateChannel state.config.gate.gateDuration delayClamped
                          Nothing -> pure unit
                    liftEffect $ Ref.modify_ (_ { lastTrigger = eventCycle }) stateRef

                CVTrack c ->
                  -- CVTrack tokens are either numeric (literal voltages) or
                  -- note names (translated to V/oct via noteNameMidi). `~` and
                  -- unknown tokens skip the emit so the bus stays at its last
                  -- value (S&H). `transforms` (e.g. [Offset -0.5]) apply
                  -- post-parse, post-translation.
                  let mRaw = case Number.fromString token of
                        Just n -> Just n
                        Nothing -> voctValue <$> Map.lookup token noteNameMidi
                  in case mRaw of
                    Just raw -> case state.oscClient of
                      Just osc -> do
                        let value = applyTransforms c.transforms raw
                        liftEffect $ Log.debug $ "〰 cv bus " <> show c.bus <> " = " <> show value <> " in " <> show delayInt <> "ms"
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
                        liftEffect $ Log.debug $ "⌇ esx slot " <> show e.slot <> " = " <> show value <> " in " <> show delayInt <> "ms"
                        liftEffect $ OSC.sendESXAfter osc e.slot value delayClamped
                      Nothing -> pure unit
                    Nothing -> pure unit

                Fh2TriggerTrack f ->
                  -- Look up the voice's MIDI channel. If unregistered (user
                  -- forgot `fh2-envelope`), log once and skip.
                  when (token /= "~") do
                    case Map.lookup f.voice state.fh2VoiceChannels of
                      Nothing ->
                        liftEffect $ Log.debug $ "  x fh2-trigger voice " <> show f.voice <> ": no fh2-envelope registration; skipping"
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
                        let adjustedDelayMs = max 0.0 (delayClamped - dev.latencyMs)
                        let adjustedUnixUs = nowUnixUs + adjustedDelayMs * 1000.0
                        -- Note duration is 200ms — short enough for any envelope
                        -- shape; FH-2 envelopes restart on each note-on so the
                        -- envelope plays in full regardless of duration.
                        liftEffect $ Log.debug $ "♪ fh2-trigger v" <> show f.voice <> " → " <> dev.name <> " ch" <> show channel <> " note " <> show note <> " in " <> show (Int.floor adjustedDelayMs) <> "ms"
                        liftEffect $ scheduleNoteAt state.bridgeClient dev.name channel note 100 200 adjustedUnixUs

      liftEffect $ Ref.modify_ (_ { nextCycle = toCycle }) stateRef

      -- Continuous (LFO-style) voices: sampled once per tick regardless
      -- of whether any discrete events fired this window.  The window
      -- machinery above is irrelevant for these — they don't have a
      -- discrete "next event" to look ahead toward; they're a function
      -- of current cycle time, end of story.
      let cycleAt = numberToCycleRat currentCycle
      for_ state.continuousTracks \ct ->
        case samplePatternAt cycleAt ct.pattern of
          Nothing -> pure unit
          Just rawValue ->
            liftEffect $ dispatchContValue state ct.dest ct.name rawValue nowUnixUs

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

    UpdateGateTrackP ch pat -> do
      -- Pre-parsed gate track from the host-language evaluator.
      -- Same as UpdateGateTrack but skips the mini-notation parse step.
      state <- liftEffect $ Ref.read stateRef
      let newTrack = GateTrack { pattern: pat, channel: ch, fanout: false }
      let isOther = case _ of
            GateTrack g -> g.channel /= ch
            _           -> true
      let newTracks = Array.filter isOther state.tracks <> [newTrack]
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "gate ch " <> show ch <> ": <expr>"
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
        GateTrack g -> liftEffect $ Log.debug $ "- gate ch " <> show g.channel
        CVTrack c -> liftEffect $ Log.debug $ "- cv bus " <> show c.bus
        ESXTrack e -> liftEffect $ Log.debug $ "- esx slot " <> show e.slot
        Fh2TriggerTrack f -> liftEffect $ Log.debug $ "- fh2-trigger v" <> show f.voice
      midiSchedulerLoop stateRef

    AddBinding name actionSpec -> do
      state <- liftEffect $ Ref.read stateRef
      -- Try the continuous-voice declaration first (`midi-cc-cont` /
      -- `cv-cont`).  If it matches, the name lives in continuousBindings
      -- — distinct registry from discrete bindings — and a cell writing
      -- `<name> :<expr>` will install a ContinuousTrack against the
      -- recorded destination.  Falls through to the existing discrete
      -- binding parser if the spec doesn't match a continuous shape.
      case parseContBinding actionSpec of
        Just dest -> do
          let newCont = Map.insert name dest state.continuousBindings
          let newSinks = Map.insert name [contDestToSinkType dest] state.sinkTypes
          liftEffect $ Ref.write (state { continuousBindings = newCont
                                        , sinkTypes = newSinks }) stateRef
          liftEffect $ log $ "bind " <> name <> " : "
            <> Sink.renderSinkType (contDestToSinkType dest)
        Nothing ->
          case Binding.parseCompoundAction actionSpec of
            Left err ->
              liftEffect $ log $ "bind " <> name <> ": ✗ " <> err
            Right binding -> do
              let newRegistry = Map.insert name binding state.bindings
              let sinks = Sink.bindingSinkTypes binding
              let newSinks = Map.insert name sinks state.sinkTypes
              liftEffect $ Ref.write (state { bindings = newRegistry
                                            , sinkTypes = newSinks }) stateRef
              liftEffect $ log $ "bind " <> name <> " : "
                <> Str.joinWith " ⊕ " (map Sink.renderSinkType sinks)
      midiSchedulerLoop stateRef

    RemoveBinding name -> do
      state <- liftEffect $ Ref.read stateRef
      let newRegistry = Map.delete name state.bindings
      let newCont = Map.delete name state.continuousBindings
      let newSinks = Map.delete name state.sinkTypes
      let newCTs = Array.filter (\ct -> ct.name /= name) state.continuousTracks
      liftEffect $ Ref.write (state { bindings = newRegistry
                                    , continuousBindings = newCont
                                    , sinkTypes = newSinks
                                    , continuousTracks = newCTs
                                    }) stateRef
      liftEffect $ log $ "unbind " <> name
      midiSchedulerLoop stateRef

    PlayByName name _patStr fullText _paramSpecs -> do
      -- Legacy whole-text fallback path. After PR1.4d-ii-b the WS
      -- handler only routes here when the name has NO discrete
      -- binding (otherwise the play installs on the new voice tree
      -- instead). The fallback installs a single GateTrack from the
      -- full message text — preserves `bd sn hh cp`-without-bind.
      state <- liftEffect $ Ref.read stateRef
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

    PlayByNameP _name _pat _fullText -> do
      -- Dead constructor — no Erlang call site builds it. Kept on
      -- the Msg sum for type completeness; cleaned up when the Msg
      -- type itself shrinks (post-PR1.4e cleanup).
      midiSchedulerLoop stateRef

    PlayByNameExpr name exprSrc fullText -> do
      -- After PR1.4d-ii-c the WS handler routes the discrete-binding
      -- case to the new voice tree directly. This handler only sees
      -- the colon-expr form when the name is continuous-bound (or
      -- unbound, in which case we log "no binding"). Continuous voices
      -- migrate to the new tree in PR1.5; until then they live here.
      state <- liftEffect $ Ref.read stateRef
      case Expr.parseExpr exprSrc >>= Expr.evalExpr of
        Left err ->
          liftEffect $ log $ "✗ " <> name <> ": eval error: " <> err
        Right result ->
          case patternTypeOfEval result of
            Nothing ->
              liftEffect $ log $ "✗ " <> name <> ": :expr did not evaluate to a pattern"
            Just patType ->
              case checkPatternForName state name patType of
                Left msg ->
                  liftEffect $ log $ "✗ " <> msg
                Right _ -> case Map.lookup name state.continuousBindings, result of
                  Just dest, Expr.VNumPattern p -> do
                    let newCT = { pattern: p, name, dest }
                    let isOther ct = ct.name /= name
                    let newCTs = Array.filter isOther state.continuousTracks <> [newCT]
                    liftEffect $ Ref.write (state { continuousTracks = newCTs }) stateRef
                    liftEffect $ log $ "≈ " <> name <> ": " <> fullText
                  _, _ ->
                    liftEffect $ log $ "(no binding '" <> name <> "', :expr ignored)"
      midiSchedulerLoop stateRef

    PlayMultiByName _entries _fullText -> do
      -- Dead handler — the WS handler routes :<expr> multi-bare-expr
      -- entirely through the new voice tree as of PR1.4d-ii-d. Kept
      -- on the Msg sum for type completeness; cleaned up when the
      -- Msg type itself shrinks (post-PR1.4e cleanup).
      midiSchedulerLoop stateRef

    Hush -> do
      -- Tidal-compat: silence everything. Drop all running tracks
      -- (discrete and continuous) but preserve the binding registry so
      -- the user can immediately play a name again without rebinding.
      state <- liftEffect $ Ref.read stateRef
      liftEffect $ Ref.write (state { tracks = [], continuousTracks = [] }) stateRef
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

    Fh2Shape voice a d s r -> do
      -- Live ADSR: send 4 CCs on the voice's MIDI channel. CC numbers are
      -- offset per-MCV so each voice has its own ADSR controls:
      --   MCV 0 -> 70/71/72/73, MCV 1 -> 74/75/76/77, MCV 2 -> 78..81, etc.
      -- The user sets up the mapping once in the FH-2 Configurator's
      -- Envelopes form; thereafter fh2-shape drives them from Tidal.
      state <- liftEffect $ Ref.read stateRef
      case Map.lookup voice state.fh2VoiceChannels of
        Nothing ->
          liftEffect $ Log.debug $ "fh2-shape v" <> show voice <> ": no fh2-envelope registration; skipping"
        Just channel -> do
          let dev = fromMaybe { name: "FH-2", latencyMs: 0.0 }
                      (Map.lookup "fh2" state.midiDevices)
              clamp v = if v < 0 then 0 else if v > 127 then 127 else v
              ccA = 70 + 4 * voice
              ccD = ccA + 1
              ccS = ccA + 2
              ccR = ccA + 3
          -- Fire all four CCs immediately. nowUnixUs is the same instant
          -- for all four — link-spike will dispatch them on the same
          -- audio frame.
          nowUnixUs <- liftEffect LinkAnchor.nowUnixUs
          liftEffect $ log $ "fh2-shape v" <> show voice <> " ch" <> show channel
            <> " CCs " <> show ccA <> "-" <> show ccR
            <> ": A=" <> show a <> " D=" <> show d <> " S=" <> show s <> " R=" <> show r
          liftEffect $ scheduleCCAt state.bridgeClient dev.name channel ccA (clamp a) nowUnixUs
          liftEffect $ scheduleCCAt state.bridgeClient dev.name channel ccD (clamp d) nowUnixUs
          liftEffect $ scheduleCCAt state.bridgeClient dev.name channel ccS (clamp s) nowUnixUs
          liftEffect $ scheduleCCAt state.bridgeClient dev.name channel ccR (clamp r) nowUnixUs
      midiSchedulerLoop stateRef

    SetBpm bpm -> do
      -- Update the local fallback (used when no Link peer broadcasts
      -- a tempo) AND send /link/set-tempo to link-spike. With Link
      -- active, the broadcast wins on the next anchor; without Link,
      -- the fallback is what the cycle counter uses.
      state <- liftEffect $ Ref.read stateRef
      liftEffect $ MIDIBridge.setLinkTempo state.bridgeClient bpm
      liftEffect $ Ref.modify_ (\s -> s { config = s.config { bpm = bpm } }) stateRef
      liftEffect $ log $ "bpm: " <> show bpm <> " (sent to link-spike + updated fallback)"
      midiSchedulerLoop stateRef

    SetDefaultMidiDevice deviceName -> do
      liftEffect $ Ref.modify_ (\s -> s { config = s.config { midi = s.config.midi { device = deviceName } } }) stateRef
      liftEffect $ log $ "config: midi-device = " <> deviceName
      midiSchedulerLoop stateRef

    SetGateEnabled enabled -> do
      liftEffect $ Ref.modify_ (\s -> s { config = s.config { gate = s.config.gate { enabled = enabled } } }) stateRef
      liftEffect $ log $ "config: gate-enabled = " <> show enabled
      midiSchedulerLoop stateRef

    SetLookAheadMs lookAhead -> do
      liftEffect $ Ref.modify_ (\s -> s { config = s.config { lookAhead = lookAhead } }) stateRef
      liftEffect $ log $ "config: look-ahead-ms = " <> show lookAhead
      midiSchedulerLoop stateRef

    Stop -> do
      liftEffect $ log "MIDI Scheduler stopped"

-- | Check whether a pattern is type-compatible with the registered
-- | sink(s) for `name`.  A binding can have multiple actions (e.g.
-- | `plaits = gate 6 + cv 15 voct`); the pattern must satisfy ALL of
-- | them.  Errors return `Left <message>` with the failing sink's
-- | unaliased signature included so the user knows what was expected.
checkPatternForName
  :: MIDISchedulerState
  -> String
  -> Sink.PatternType
  -> Either String Unit
checkPatternForName state name patType =
  case Map.lookup name state.sinkTypes of
    Nothing -> Right unit  -- unknown name; let the existing dispatch handle it
    Just sinks ->
      let
        results = map (\s -> Sink.checkPattern s patType) sinks
        firstErr = Array.findMap (case _ of
          Left msg -> Just msg
          Right _ -> Nothing) results
      in case firstErr of
        Nothing -> Right unit
        Just msg -> Left $ "voice '" <> name <> "': " <> msg

-- | Coarse-grained `PatternType` for an `Expr.EvalResult`.  Only
-- | distinguishes Number vs String at this layer; can't classify
-- | string-token content because the original TPat isn't preserved
-- | through Expr-layer transformations.
patternTypeOfEval :: Expr.EvalResult -> Maybe Sink.PatternType
patternTypeOfEval = case _ of
  Expr.VPattern _ -> Just (Sink.PatString Sink.ContentMixed)
  Expr.VNumPattern _ -> Just Sink.PatNumber
  _ -> Nothing

-- | Try to parse a binding spec as a continuous-voice declaration.
-- | Recognised shapes:
-- |
-- |   `midi-cc-cont <device> <channel> <cc>`
-- |     Each scheduler tick the voice's pattern is sampled and the
-- |     resulting 0..1 value is scaled to a 0..127 MIDI CC.
-- |
-- |   `cv-cont <bus>`
-- |     Each tick samples the pattern and emits the raw value as a
-- |     CV update on the given bus (cv-router OSC).  No scaling —
-- |     the user controls the range via `range` in the expression.
-- |
-- | Returns `Nothing` for any other shape, letting the caller fall
-- | through to the discrete binding parser.
parseContBinding :: String -> Maybe ContDest
parseContBinding s =
  case Array.filter (_ /= "") (String.split (String.Pattern " ") (String.trim s)) of
    ["midi-cc-cont", device, chStr, ccStr] -> do
      ch <- Int.fromString chStr
      cc <- Int.fromString ccStr
      Just (ContMidiCC { device, channel: ch, cc })
    ["cv-cont", busStr] -> do
      bus <- Int.fromString busStr
      Just (ContCV { bus, transforms: [] })
    _ -> Nothing

-- | Convert a fractional-cycle Number into a Rational with microcycle
-- | precision.  Used by the continuous-voice sampler so we can call
-- | `samplePatternAt :: Rational -> Pattern a -> Maybe a` against the
-- | scheduler's `currentCycle :: Number`.  Microcycle precision (one
-- | part in a million per cycle) is plenty: at BPM 120 that's 1µs,
-- | well below the ~50ms sample period.
numberToCycleRat :: Number -> R.Rational
numberToCycleRat c =
  R.fromInt (Int.floor (c * 1000000.0)) / R.fromInt 1000000

-- | Dispatch a single sampled continuous value to its MIDI CC or CV
-- | destination.  No latency adjustment, no event-time book-keeping —
-- | continuous voices fire at "now", every tick, and whoever they
-- | reach interpolates / smooths.  For MIDI CC the raw value is
-- | scaled 0..1 → 0..127 (oscillators land in 0..1; users `range`
-- | them outside that to widen).  For CV the raw value passes through
-- | the binding's `transforms` pipeline unchanged.
dispatchContValue
  :: MIDISchedulerState
  -> ContDest
  -> String
  -> Number
  -> Number
  -> Effect Unit
dispatchContValue state dest name rawValue nowUnixUs = case dest of
  ContMidiCC m ->
    case Map.lookup m.device state.midiDevices of
      Nothing -> pure unit
      Just dev -> do
        let v7 = clamp7bit (rawValue * 127.0)
        let adjustedUnixUs = nowUnixUs - dev.latencyMs * 1000.0
        Log.debug $ "≈ [" <> name <> "] cc " <> show m.cc <> " = " <> show v7
        scheduleCCAt state.bridgeClient dev.name m.channel m.cc v7 adjustedUnixUs
  ContCV c ->
    case state.oscClient of
      Nothing -> pure unit
      Just osc -> do
        let value = applyTransforms c.transforms rawValue
        Log.debug $ "≈ [" <> name <> "] cv bus " <> show c.bus <> " = " <> show value
        OSC.sendCVAfter osc c.bus value 0.0

-- | Convert a wire-level TransformSpec into a typed Transform for use
-- | by `applyTransforms`. The two types are parallel today; if the
-- | wire spec gains constructors that need richer semantics (e.g. a
-- | spec that references a slot), this is where the translation lives.
specToTransform :: TransformSpec -> Transform
specToTransform = case _ of
  SpecOffset n  -> Offset n
  SpecInvert    -> Invert
  SpecScale a b -> Scale a b

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

-- | Get the cycle time to fire this event AT.
-- |
-- | For Digital events use `whole.start` — the actual onset. Using
-- | `part.start` re-fires events whose `whole` spans multiple scheduler
-- | cycles (`slow N` over a stack pattern is the canonical case: every
-- | chord member's `whole` already spans the inner cycle, so after `slow N`
-- | it spans N scheduler cycles, and `part.start` would land at every
-- | one of them).
-- |
-- | Analog events have no `whole` (they're continuous), so `part.start`
-- | is the right reading there.
eventStartCycle :: Event String -> R.Rational
eventStartCycle = case _ of
  Digital { whole: Arc { start } } -> start
  Analog { part: Arc { start } } -> start

-- | Get sample name from event
eventSample :: Event String -> String
eventSample = case _ of
  Digital { value } -> value
  Analog { value } -> value

-- ---------------------------------------------------------------------------
-- State publication for the `state` debug verb
-- ---------------------------------------------------------------------------

-- | Read the current scheduler state and publish a JSON snapshot to
-- | the StateBus ETS table.  Called at the top of every loop
-- | iteration so the latest snapshot reflects the post-handle state
-- | of the most recent message.
publishState :: Ref MIDISchedulerState -> Effect Unit
publishState stateRef = do
  s <- Ref.read stateRef
  StateBus.write (serializeState s)

-- | Serialize a `MIDISchedulerState` as a JSON string.  Hand-rolled
-- | because Argonaut isn't currently in the purerl-tidal dep set;
-- | the shape is small and stable enough that the cost is fine.
-- | Handles standard JSON-string escaping for `\` and `"`; other
-- | control chars are unlikely in the values we produce (device
-- | names, binding names, etc.).
serializeState :: MIDISchedulerState -> String
serializeState s =
  let
    cfg = s.config
    mc = cfg.midi
    gc = cfg.gate

    configObj = "{"
      <> "\"bpm\":" <> show cfg.bpm
      <> ",\"lookAheadMs\":" <> show cfg.lookAhead
      <> ",\"scheduleIntervalMs\":" <> show cfg.scheduleInterval
      <> ",\"noteDurationMs\":" <> show cfg.noteDuration
      <> ",\"midi\":{"
      <>   "\"device\":" <> jsStr mc.device
      <>   ",\"channel\":" <> show mc.channel
      <>   ",\"defaultVelocity\":" <> show mc.defaultVelocity
      <> "}"
      <> ",\"gate\":{"
      <>   "\"enabled\":" <> jsBool gc.enabled
      <>   ",\"oscHost\":" <> jsStr gc.oscHost
      <>   ",\"oscPort\":" <> show gc.oscPort
      <>   ",\"gateDurationMs\":" <> show gc.gateDuration
      <>   ",\"cvLeadMs\":" <> show gc.cvLeadMs
      <>   ",\"channelOffset\":" <> show gc.channelOffset
      <> "}"
      <> "}"

    midiDeviceEntry (Tuple alias dev) =
      "{\"alias\":" <> jsStr alias
        <> ",\"name\":" <> jsStr dev.name
        <> ",\"latencyMs\":" <> show dev.latencyMs <> "}"
    midiDevicesArr = jsArrOf midiDeviceEntry
      (Map.toUnfoldable s.midiDevices :: Array (Tuple String { name :: String, latencyMs :: Number }))

    bindingNamesArr = jsArrOf jsStr
      (Array.fromFoldable (Map.keys s.bindings))

    -- Voices: each name with its sink type signature (full unaliased
    -- form) so the eventual Calypso Voices pane can render them.
    voiceEntry (Tuple name sinks) =
      "{\"name\":" <> jsStr name
        <> ",\"signature\":" <> jsStr (Str.joinWith " ⊕ " (map Sink.renderSinkType sinks))
        <> ",\"sinks\":" <> jsArrOf Sink.renderSinkTypeJSON sinks
        <> "}"
    voicesArr = jsArrOf voiceEntry
      (Map.toUnfoldable s.sinkTypes :: Array (Tuple String (Array Sink.SinkType)))

    trackEntry track = case track of
      GateTrack g ->
        "{\"kind\":\"gate\",\"channel\":" <> show g.channel
          <> ",\"fanout\":" <> jsBool g.fanout <> "}"
      CVTrack c ->
        "{\"kind\":\"cv\",\"bus\":" <> show c.bus <> "}"
      ESXTrack e ->
        "{\"kind\":\"esx\",\"slot\":" <> show e.slot <> "}"
      Fh2TriggerTrack f ->
        "{\"kind\":\"fh2-trigger\",\"voice\":" <> show f.voice <> "}"
    tracksArr = jsArrOf trackEntry s.tracks

    contTrackEntry ct =
      "{\"name\":" <> jsStr ct.name <> ",\"dest\":" <> contDestEntry ct.dest <> "}"
    contDestEntry = case _ of
      ContMidiCC m ->
        "{\"kind\":\"midi-cc-cont\",\"device\":" <> jsStr m.device
          <> ",\"channel\":" <> show m.channel
          <> ",\"cc\":" <> show m.cc <> "}"
      ContCV c ->
        "{\"kind\":\"cv-cont\",\"bus\":" <> show c.bus <> "}"
    contTracksArr = jsArrOf contTrackEntry s.continuousTracks
    contBindingsArr = jsArrOf
      (\(Tuple n d) ->
        "{\"name\":" <> jsStr n <> ",\"dest\":" <> contDestEntry d <> "}")
      (Map.toUnfoldable s.continuousBindings :: Array (Tuple String ContDest))

    fh2Entry (Tuple voice channel) =
      "{\"voice\":" <> show voice <> ",\"channel\":" <> show channel <> "}"
    fh2Arr = jsArrOf fh2Entry
      (Map.toUnfoldable s.fh2VoiceChannels :: Array (Tuple Int Int))

  in
    "{\"config\":" <> configObj
      <> ",\"midiDevices\":" <> midiDevicesArr
      <> ",\"bindingNames\":" <> bindingNamesArr
      <> ",\"voices\":" <> voicesArr
      <> ",\"tracks\":" <> tracksArr
      <> ",\"continuousTracks\":" <> contTracksArr
      <> ",\"continuousBindings\":" <> contBindingsArr
      <> ",\"fh2VoiceChannels\":" <> fh2Arr
      <> "}"

-- | JSON string literal — escape `\` and `"` and wrap in double quotes.
jsStr :: String -> String
jsStr s = "\"" <> escapeJson s <> "\""

jsBool :: Boolean -> String
jsBool b = if b then "true" else "false"

-- | Build a JSON array literal by mapping a per-element renderer
-- | over an `Array a`.  Handles the empty-array case (`[]`) cleanly.
jsArrOf :: forall a. (a -> String) -> Array a -> String
jsArrOf f xs = "[" <> Str.joinWith "," (map f xs) <> "]"

-- | Replace JSON-string-relevant escapes.  Order matters: backslash
-- | first so the doubled `\\` doesn't get re-escaped on the quote pass.
escapeJson :: String -> String
escapeJson s0 =
  let s1 = String.replaceAll (String.Pattern "\\") (String.Replacement "\\\\") s0
      s2 = String.replaceAll (String.Pattern "\"") (String.Replacement "\\\"") s1
  in s2
