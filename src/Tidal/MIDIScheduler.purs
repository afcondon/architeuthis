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
import Tidal.Expr as Expr
import Tidal.Binding (ContDest(..), parseContBinding)
import Tidal.Binding as Binding
import Tidal.Pattern.Types (Pattern)
import Tidal.Dispatch.Helpers (voctValue, clamp7bit)
import Tidal.Sink as Sink
import Tidal.MIDI (MIDIConfig)
import Tidal.MIDIBridge (BridgeClient)
import Tidal.MIDIBridge as MIDIBridge
import Tidal.LinkAnchor as LinkAnchor
import Tidal.OSC as OSC
import Tidal.Scheduler (sendAfter, currentTimeMs, Msg(..))

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
startMIDIScheduler config _initialPatternStr = do
  spawn do
    bridgeClient <- liftEffect MIDIBridge.startClient

    oscClient <- liftEffect $
      if config.gate.enabled
        then do
          client <- OSC.startClient { host: config.gate.oscHost, port: config.gate.oscPort }
          pure (Just client)
        else pure Nothing

    startTime <- liftEffect currentTimeMs

    stateRef <- liftEffect $ Ref.new
      { config
      , startTime
      , nextCycle: zero
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
    liftEffect $ log $ "BPM: " <> show config.bpm
    when config.gate.enabled do
      liftEffect $ log $ "Gate output: enabled (OSC " <> config.gate.oscHost <> ":" <> show config.gate.oscPort <> ")"

    pid <- liftEffect Raw.self
    liftEffect $ sendAfter config.scheduleInterval pid Tick

    midiSchedulerLoop stateRef

-- | Main loop. Receives Msg and updates state. As of PR1.7c the
-- | StateBus snapshot is published by `tidal_state_pub` rather than
-- | from inside this loop; the MIDIScheduler's remaining state is
-- | a husk awaiting full deletion in PR1.7d.
midiSchedulerLoop :: Ref MIDISchedulerState -> ProcessM Msg Unit
midiSchedulerLoop stateRef = do
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

      -- Legacy GateTrack/CVTrack/ESXTrack dispatch lived here pre-PR1.7a.
      -- The track verbs now install bound voices in tidal_voice_sup
      -- under reserved names; `state.tracks` is gone. The window
      -- arithmetic above still feeds the publishState snapshot via
      -- `nextCycle`.

      liftEffect $ Ref.modify_ (_ { nextCycle = toCycle }) stateRef

      -- Continuous voices live entirely on the new voice tree as of
      -- PR1.5-b. MIDIScheduler keeps the `continuousBindings` /
      -- `continuousTracks` fields for snapshot shape stability until
      -- PR1.8, but no tick-side dispatch happens here anymore.

      pid <- liftEffect Raw.self
      liftEffect $ sendAfter state.config.scheduleInterval pid Tick
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

    PlayByNameP _name _pat _fullText -> do
      -- Dead constructor — no Erlang call site builds it. Kept on
      -- the Msg sum for type completeness; cleaned up when the Msg
      -- type itself shrinks (post-PR1.4e cleanup).
      midiSchedulerLoop stateRef

    PlayByNameExpr name exprSrc _fullText -> do
      -- After PR1.5-b the WS handler routes both discrete and
      -- continuous-bound names through the new voice tree. The
      -- handler still receives this message for the diagnostic path:
      -- the new tree's parse failed, the name is unbound, or the
      -- expression's type doesn't match the binding. Surface the
      -- relevant log line; no track install happens here.
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
                Right _ ->
                  liftEffect $ log $ "(no binding '" <> name <> "', :expr ignored)"
      midiSchedulerLoop stateRef

    PlayMultiByName _entries _fullText -> do
      -- Dead handler — the WS handler routes :<expr> multi-bare-expr
      -- entirely through the new voice tree as of PR1.4d-ii-d. Kept
      -- on the Msg sum for type completeness; cleaned up when the
      -- Msg type itself shrinks (post-PR1.4e cleanup).
      midiSchedulerLoop stateRef

    Hush -> do
      -- Tidal-compat: clear MIDIScheduler-side residual state.
      -- The new voice tree is hushed by the WS handler's parallel
      -- voice_sup:hush_all/0 call; this branch only resets
      -- continuousTracks (always empty after PR1.5-c, but harmless).
      state <- liftEffect $ Ref.read stateRef
      liftEffect $ Ref.write (state { continuousTracks = [] }) stateRef
      liftEffect $ log "hush"
      midiSchedulerLoop stateRef

    RegisterMidiDevice alias deviceName latencyMs -> do
      state <- liftEffect $ Ref.read stateRef
      let newDevices = Map.insert alias { name: deviceName, latencyMs } state.midiDevices
      liftEffect $ Ref.write (state { midiDevices = newDevices }) stateRef
      liftEffect $ log $ "midi-device " <> alias <> " = " <> deviceName <> " (lat " <> show latencyMs <> "ms)"
      midiSchedulerLoop stateRef

    Fh2Envelope _voice _output _channel -> do
      -- Dead handler — the dispatcher owns fh2VoiceChannels as of
      -- PR1.7b; the WS handler calls tidal_dispatcher:set_fh2_voice_
      -- channel directly. Msg variant kept until post-PR1.7d cleanup.
      midiSchedulerLoop stateRef

    Fh2Shape _voice _a _d _s _r -> do
      -- Dead handler — the dispatcher owns Fh2Shape as of PR1.7b
      -- (tidal_dispatcher:dispatch_fh2_shape). Msg variant kept until
      -- post-PR1.7d cleanup.
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

-- State publication moved to `tidal_state_pub` gen_server in PR1.7c.
-- The publisher reads from `tidal_dispatcher` (bindings, midiDevices,
-- continuousBindings, fh2VoiceChannels) and `tidal_clock` (bpm,
-- tickInterval, lookAhead) directly; MIDIScheduler is no longer in the
-- snapshot path.
