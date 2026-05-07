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
  | BoundTrack
      { pattern :: Pattern String
      , name :: String
      , binding :: Binding.Binding
      , params :: Map String (Pattern String)
        -- ^ Joined parameter patterns from `#` segments.  At dispatch
        -- time, each is queried at the same `eventCycle` as the
        -- structure pattern; the resulting per-event values override
        -- corresponding fields on the bound PrimActions.
      }
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
-- | sample.  Distinct from the discrete event-driven dispatch path of
-- | `BoundTrack`.
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
                          liftEffect $ Log.debug $ "〰 [" <> b.name <> "] cv bus " <> show bus <> " = " <> show value
                          liftEffect $ OSC.sendCVAfter osc bus value cvDelay
                        _, _ -> pure unit
                    Binding.ESX e ->
                      case state.oscClient, Number.fromString token of
                        Just osc, Just value -> do
                          let adjusted = max 0.0 (delayClamped - Int.toNumber e.latencyMs)
                          liftEffect $ Log.debug $ "⌇ [" <> b.name <> "] esx slot " <> show e.slot <> " = " <> show value <> " (lat " <> show e.latencyMs <> "ms)"
                          liftEffect $ OSC.sendESXAfter osc e.slot value adjusted
                        _, _ -> pure unit
                    Binding.Gate g ->
                      when (token /= "~") do
                        case state.oscClient of
                          Just osc -> do
                            let adjusted = max 0.0 (delayClamped - Int.toNumber g.latencyMs)
                            liftEffect $ Log.debug $ "⚡ [" <> b.name <> "] gate " <> show g.channel <> " in " <> show delayInt <> "ms (lat " <> show g.latencyMs <> "ms)"
                            liftEffect $ OSC.sendGateTrigAfter osc g.channel state.config.gate.gateDuration adjusted
                          Nothing -> pure unit
                    Binding.ES5Gate g ->
                      when (token /= "~") do
                        case state.oscClient of
                          Just osc -> do
                            let adjusted = max 0.0 (delayClamped - Int.toNumber g.latencyMs)
                            liftEffect $ Log.debug $ "✦ [" <> b.name <> "] es5gate " <> show g.bit <> " in " <> show delayInt <> "ms (lat " <> show g.latencyMs <> "ms)"
                            liftEffect $ OSC.sendES5GateTrigAfter osc g.bit state.config.gate.gateDuration adjusted
                          Nothing -> pure unit
                    Binding.MidiNote m ->
                      when (token /= "~") do
                        case Map.lookup m.device state.midiDevices of
                          Nothing ->
                            liftEffect $ Log.debug $ "✗ [" <> b.name <> "] midi-note: unknown device alias '" <> m.device <> "'"
                          Just dev -> do
                            -- Token can override the binding's defaultNote with
                            -- a note name (c4, e4, etc.). Falls back to the
                            -- binding's defaultNote for trigger-style tokens
                            -- (bd, sn, etc.) so drum patterns work.
                            let note = case Map.lookup token noteNameMidi of
                                  Just n -> n
                                  Nothing -> m.defaultNote
                            -- `# vel "..."` — query the velocity pattern at
                            -- this event's cycle time and override the
                            -- binding's default.  Out-of-range / non-numeric
                            -- tokens (rest `~`, words) fall back to default.
                            let velocity = case Map.lookup "vel" b.params of
                                  Nothing -> m.velocity
                                  Just velPat -> case samplePatternAt eventCycle velPat of
                                    Just velTok -> case param7bit velTok of
                                      Just v -> v
                                      Nothing -> m.velocity
                                    Nothing -> m.velocity
                            -- Latency compensation: emit earlier by the
                            -- device's reported latency so this destination
                            -- arrives in unison with faster ones.
                            let adjustedDelayMs = max 0.0 (delayClamped - dev.latencyMs)
                            let adjustedUnixUs = nowUnixUs + adjustedDelayMs * 1000.0
                            liftEffect $ Log.debug $ "  [" <> b.name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " note " <> show note <> " vel " <> show velocity <> " (dur " <> show m.durationMs <> "ms) in " <> show (Int.floor adjustedDelayMs) <> "ms"
                            liftEffect $ scheduleNoteAt state.bridgeClient dev.name m.channel note velocity m.durationMs adjustedUnixUs
                    Binding.MidiCC m ->
                      case Number.fromString token of
                        Nothing -> pure unit  -- ~ rest or non-numeric → skip
                        Just raw ->
                          case Map.lookup m.device state.midiDevices of
                            Nothing ->
                              liftEffect $ Log.debug $ "✗ [" <> b.name <> "] midi-cc: unknown device alias '" <> m.device <> "'"
                            Just dev -> do
                              -- Pattern values 0..1 → MIDI 0..127. Clamp to
                              -- safe range; CC values >127 or <0 silently
                              -- truncated by sendmidi anyway, but explicit
                              -- clamp gives predictable behaviour.
                              let value7bit = clamp7bit (raw * 127.0)
                              let adjustedDelayMs = max 0.0 (delayClamped - dev.latencyMs)
                              let adjustedUnixUs = nowUnixUs + adjustedDelayMs * 1000.0
                              liftEffect $ Log.debug $ "◇ [" <> b.name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " cc" <> show m.cc <> " = " <> show value7bit
                              liftEffect $ scheduleCCAt state.bridgeClient dev.name m.channel m.cc value7bit adjustedUnixUs

                  -- Compositional `#` joins: any param NAME that matches
                  -- another registered binding fires that binding's actions
                  -- at the same event time, with the value drawn from the
                  -- joined pattern.  This is how cross-binding chaining
                  -- works — `lap "x*4" # laplace-resonator-strength "0.2 0.7"`
                  -- both plays the note AND sweeps the resonator CC.
                  --
                  -- Slot-override params (currently just "vel") are skipped
                  -- here because they were already consumed by the matching
                  -- PrimAction case above.  Names that don't match any
                  -- registered binding are silently ignored — the user may
                  -- have a typo, but a noisy log per-event would drown the
                  -- useful traces.
                  let composed = Map.toUnfoldable b.params
                          :: Array (Tuple String (Pattern String))
                  for_ composed \(Tuple paramName paramPat) ->
                    when (not (isSlotOverride paramName b.binding)) do
                      case Map.lookup paramName state.bindings of
                        Nothing -> pure unit
                        Just composedBinding ->
                          case samplePatternAt eventCycle paramPat of
                            Nothing -> pure unit  -- rest token → no fire
                            Just composedToken ->
                              for_ composedBinding \action -> case action of
                                Binding.MidiCC m -> case Number.fromString composedToken of
                                  Nothing -> pure unit
                                  Just raw ->
                                    case Map.lookup m.device state.midiDevices of
                                      Nothing -> pure unit
                                      Just dev -> do
                                        let v7 = clamp7bit (raw * 127.0)
                                        let dms = max 0.0 (delayClamped - dev.latencyMs)
                                        let uus = nowUnixUs + dms * 1000.0
                                        liftEffect $ Log.debug $ "  ◇ [" <> b.name <> " # " <> paramName <> "] cc " <> show m.cc <> " = " <> show v7
                                        liftEffect $ scheduleCCAt state.bridgeClient dev.name m.channel m.cc v7 uus
                                _ -> pure unit  -- only MidiCC composition for now

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
        BoundTrack b -> liftEffect $ Log.debug $ "- bound: " <> b.name
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

    PlayByName name patStr fullText paramSpecs -> do
      state <- liftEffect $ Ref.read stateRef
      case checkPatternForName state name (classifyPatString patStr) of
        Left msg -> liftEffect $ log $ "✗ " <> msg
        Right _ -> pure unit
      case Map.lookup name state.bindings of
        Just binding ->
          case parse patStr of
            Left _ ->
              liftEffect $ log $ "play '" <> name <> "' parse error: " <> patStr
            Right ast -> do
              -- Parse each `# <name> <pat>` segment.  Spec entries that
              -- don't parse are silently dropped — the structure pattern
              -- still fires; the user just doesn't get that override.
              let parsedParams = Map.fromFoldable
                    $ Array.mapMaybe
                        (\ps -> case parse ps.pat of
                          Right p -> Just (Tuple ps.name (tpatToPattern p))
                          Left _ -> Nothing)
                        paramSpecs
              let newTrack = BoundTrack
                    { pattern: tpatToPattern ast
                    , name
                    , binding
                    , params: parsedParams
                    }
              let isOther = case _ of
                    BoundTrack b -> b.name /= name
                    _            -> true
              let newTracks = Array.filter isOther state.tracks <> [newTrack]
              liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
              let paramSummary = case Array.length paramSpecs of
                    0 -> ""
                    n -> "  (+" <> show n <> " param"
                      <> (if n == 1 then "" else "s") <> ": "
                      <> Str.joinWith ", " (map _.name paramSpecs) <> ")"
              liftEffect $ log $ name <> ": " <> patStr <> paramSummary
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

    PlayByNameP name pat fullText -> do
      state <- liftEffect $ Ref.read stateRef
      case Map.lookup name state.bindings of
        Just binding -> do
          let newTrack = BoundTrack
                { pattern: pat
                , name
                , binding
                , params: Map.empty
                }
          let isOther = case _ of
                BoundTrack b -> b.name /= name
                _            -> true
          let newTracks = Array.filter isOther state.tracks <> [newTrack]
          liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
          liftEffect $ log $ name <> ": " <> fullText
        Nothing ->
          liftEffect $ log $ "(no binding '" <> name <> "', :expr ignored)"
      midiSchedulerLoop stateRef

    PlayByNameExpr name exprSrc fullText -> do
      -- Carrier for the colon-prefix `<name> :<expr>` form.  Three
      -- steps: evaluate the expression; type-check the result against
      -- the registered sink; route to either a ContinuousTrack
      -- (continuous binding) or a BoundTrack (discrete binding).  All
      -- errors logged with the unaliased sink signature so the user
      -- can see what was expected.
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
                    case Map.lookup name state.bindings, Expr.asPattern result of
                      Just binding, Right pat -> do
                        let newTrack = BoundTrack
                              { pattern: pat
                              , name
                              , binding
                              , params: Map.empty
                              }
                        let isOther = case _ of
                              BoundTrack b -> b.name /= name
                              _            -> true
                        let newTracks = Array.filter isOther state.tracks <> [newTrack]
                        liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
                        liftEffect $ log $ name <> ": " <> fullText
                      _, _ ->
                        liftEffect $ log $ "(no binding '" <> name <> "', :expr ignored)"
      midiSchedulerLoop stateRef

    PlayMultiByName entries fullText -> do
      -- Bare `:<expr>` form. Each entry is (binding-name, transformed
      -- pattern); each becomes a BoundTrack so the binding's note
      -- resolver applies and the destination is the binding's
      -- channel.  Atomic replacement: drop all existing BoundTracks
      -- whose name appears in the incoming entries, then append the
      -- new ones.  Entries whose name has no binding are logged and
      -- dropped.
      state <- liftEffect $ Ref.read stateRef
      let
        resolved = Array.mapMaybe
          (\(Tuple n p) -> case Map.lookup n state.bindings of
              Just binding -> Just
                ( BoundTrack
                    { pattern: p
                    , name: n
                    , binding
                    , params: Map.empty
                    }
                )
              Nothing -> Nothing)
          entries
        unresolved = Array.mapMaybe
          (\(Tuple n _) -> case Map.lookup n state.bindings of
              Just _  -> Nothing
              Nothing -> Just n)
          entries
        replacing = Array.mapMaybe
          (\(Tuple n _) -> case Map.lookup n state.bindings of
              Just _  -> Just n
              Nothing -> Nothing)
          entries
        isReplaced = case _ of
          BoundTrack b -> Array.elem b.name replacing
          _            -> false
        newTracks = Array.filter (not <<< isReplaced) state.tracks <> resolved
      liftEffect $ Ref.write (state { tracks = newTracks }) stateRef
      liftEffect $ log $ "multi: " <> fullText
      for_ unresolved \n ->
        liftEffect $ log $ "(no binding '" <> n <> "', voice skipped)"
      midiSchedulerLoop stateRef

    SetSlot name value -> do
      state <- liftEffect $ Ref.read stateRef
      let newSlots = Map.insert name value state.slots
      liftEffect $ Ref.write (state { slots = newSlots }) stateRef
      liftEffect $ log $ "slot " <> name <> " = " <> show value
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

-- | Sample a parameter pattern at a single cycle time.  Used for `#`
-- | parameter joins: the structure pattern's event determines `when`;
-- | each `# <name> <pat>` segment's pattern, queried at that same time,
-- | provides the parameter value used to override a binding-default
-- | field (velocity, note, duration, …) for this one event.
samplePatternAt :: forall a. R.Rational -> Pattern a -> Maybe a
samplePatternAt cycleAt pat =
  let
    -- A thin window starting AT `cycleAt`. An event whose arc covers
    -- this point is returned; if none cover (e.g. a rest token), Nothing.
    -- The epsilon must be positive so digital event lookup hits — Tidal
    -- digital events span half-open arcs, so a zero-width query at the
    -- arc start would return [].
    epsilon = R.fromInt 1 / R.fromInt 1000000
    events = queryArc pat cycleAt (cycleAt + epsilon)
  in case Array.head events of
    Just (Digital ev) -> Just ev.value
    Just (Analog ev) -> Just ev.value
    Nothing -> Nothing

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

-- | Classify a `Pattern String` (mini-notation) by re-parsing the
-- | source text.  We do this rather than introspecting the live
-- | Pattern because Pattern is opaque (a function); the source text
-- | is preserved at the WS-handler level.
classifyPatString :: String -> Sink.PatternType
classifyPatString src = case parse src of
  Right ast -> Sink.PatString (Sink.classifyTPat ast)
  Left _ -> Sink.PatString Sink.ContentMixed  -- parse-failure can't be classified

-- | Coarse-grained `PatternType` for an `Expr.EvalResult`.  Only
-- | distinguishes Number vs String at this layer; can't classify
-- | string-token content because the original TPat isn't preserved
-- | through Expr-layer transformations.  For bare-pattern dispatch
-- | (`PlayByName`) the source string is available and
-- | `classifyPatString` does the finer classification; here we
-- | accept ContentMixed as a permissive default.
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

-- | Parse a parameter token as a 7-bit integer in [0..127].  Used for
-- | the `# vel ...` and (future) `# cc... ...` overrides where the
-- | wire byte is bounded.  Out-of-range values fall back to Nothing
-- | so the dispatcher uses the binding default rather than wrap.
param7bit :: String -> Maybe Int
param7bit tok = case Number.fromString tok of
  Just n | n >= 0.0 && n <= 127.0 -> Just (Int.floor n)
  _ -> Nothing

-- | Is this `#` parameter name consumed by a slot override on any of
-- | the binding's actions?  If yes, the BoundTrack's per-PrimAction
-- | dispatch already used it; the compositional fallback should skip
-- | it to avoid double-dispatch.
-- |
-- | Currently only `vel` is a recognised slot, applying to MidiNote
-- | actions.  Add cases as more slots become pattern-driven (`note`,
-- | `dur`, MIDI CC value scaling, etc.).
isSlotOverride :: String -> Binding.Binding -> Boolean
isSlotOverride name binding = case name of
  "vel" -> Array.any isMidiNote binding
    where
    isMidiNote = case _ of
      Binding.MidiNote _ -> true
      _ -> false
  _ -> false

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
-- | Covers C0..C8. Tokens outside this range fall back to the binding's
-- | `defaultNote`, so add octaves here when a session needs them.
-- |
-- | Each sharp (`cs`, `ds`, `fs`, `gs`, `as`) is also registered with
-- | the conventional `#` spelling (`c#`, `d#`, `f#`, `g#`, `a#`) so
-- | users who don't know Tidal's `s`-suffix idiom can still get a
-- | sharp.  Both spellings resolve to the same MIDI number.
noteNameMidi :: Map String Int
noteNameMidi = Map.fromFoldable (entries <> sharpAliases entries)
  where
    entries :: Array (Tuple String Int)
    entries =
      [ Tuple "c0"  12, Tuple "cs0" 13, Tuple "d0"  14, Tuple "ds0" 15
      , Tuple "e0"  16, Tuple "f0"  17, Tuple "fs0" 18, Tuple "g0"  19
      , Tuple "gs0" 20, Tuple "a0"  21, Tuple "as0" 22, Tuple "b0"  23
      , Tuple "c1"  24, Tuple "cs1" 25, Tuple "d1"  26, Tuple "ds1" 27
      , Tuple "e1"  28, Tuple "f1"  29, Tuple "fs1" 30, Tuple "g1"  31
      , Tuple "gs1" 32, Tuple "a1"  33, Tuple "as1" 34, Tuple "b1"  35
      , Tuple "c2"  36, Tuple "cs2" 37, Tuple "d2"  38, Tuple "ds2" 39
      , Tuple "e2"  40, Tuple "f2"  41, Tuple "fs2" 42, Tuple "g2"  43
      , Tuple "gs2" 44, Tuple "a2"  45, Tuple "as2" 46, Tuple "b2"  47
      , Tuple "c3"  48, Tuple "cs3" 49, Tuple "d3"  50, Tuple "ds3" 51
      , Tuple "e3"  52, Tuple "f3"  53, Tuple "fs3" 54, Tuple "g3"  55
      , Tuple "gs3" 56, Tuple "a3"  57, Tuple "as3" 58, Tuple "b3"  59
      , Tuple "c4"  60, Tuple "cs4" 61, Tuple "d4"  62, Tuple "ds4" 63
      , Tuple "e4"  64, Tuple "f4"  65, Tuple "fs4" 66, Tuple "g4"  67
      , Tuple "gs4" 68, Tuple "a4"  69, Tuple "as4" 70, Tuple "b4"  71
      , Tuple "c5"  72, Tuple "cs5" 73, Tuple "d5"  74, Tuple "ds5" 75
      , Tuple "e5"  76, Tuple "f5"  77, Tuple "fs5" 78, Tuple "g5"  79
      , Tuple "gs5" 80, Tuple "a5"  81, Tuple "as5" 82, Tuple "b5"  83
      , Tuple "c6"  84, Tuple "cs6" 85, Tuple "d6"  86, Tuple "ds6" 87
      , Tuple "e6"  88, Tuple "f6"  89, Tuple "fs6" 90, Tuple "g6"  91
      , Tuple "gs6" 92, Tuple "a6"  93, Tuple "as6" 94, Tuple "b6"  95
      , Tuple "c7"  96, Tuple "cs7" 97, Tuple "d7"  98, Tuple "ds7" 99
      , Tuple "e7" 100, Tuple "f7" 101, Tuple "fs7" 102, Tuple "g7" 103
      , Tuple "gs7" 104, Tuple "a7" 105, Tuple "as7" 106, Tuple "b7" 107
      , Tuple "c8" 108
      ]

    -- | For each `<letter>s<octave>` entry, also expose `<letter>#<octave>`
    -- | so `f#2` and `fs2` both resolve to MIDI 30.
    sharpAliases :: Array (Tuple String Int) -> Array (Tuple String Int)
    sharpAliases = Array.mapMaybe \(Tuple name n) ->
      case SCU.toCharArray name of
        [ letter, 's', oct ] -> Just (Tuple (SCU.fromCharArray [letter, '#', oct]) n)
        _ -> Nothing

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
      BoundTrack b ->
        "{\"kind\":\"bound\",\"name\":" <> jsStr b.name <> "}"
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

    slotEntry (Tuple name value) =
      "{\"name\":" <> jsStr name <> ",\"value\":" <> show value <> "}"
    slotsArr = jsArrOf slotEntry
      (Map.toUnfoldable s.slots :: Array (Tuple String Number))

  in
    "{\"config\":" <> configObj
      <> ",\"midiDevices\":" <> midiDevicesArr
      <> ",\"bindingNames\":" <> bindingNamesArr
      <> ",\"voices\":" <> voicesArr
      <> ",\"tracks\":" <> tracksArr
      <> ",\"continuousTracks\":" <> contTracksArr
      <> ",\"continuousBindings\":" <> contBindingsArr
      <> ",\"fh2VoiceChannels\":" <> fh2Arr
      <> ",\"slots\":" <> slotsArr
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
