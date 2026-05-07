-- | Dispatcher state — owns OSC + MIDI bridge sockets and routes voice
-- | events to the right destination(s).
-- |
-- | The dispatcher is a gen_server (`tidal_dispatcher.erl`) holding:
-- |
-- |   * `bridgeClient` — the link-spike MIDI socket (UDP 127.0.0.1:57122).
-- |   * `oscClient` — the cv-router OSC socket (Maybe; only opened when
-- |     gate output is configured).
-- |   * `bindings` — per-voice-name PrimAction lists, set by the WS
-- |     handler when a `bind` verb is processed.
-- |   * `midiDevices` — alias → device-name + latency; populated by
-- |     `midi-device` verb registrations.
-- |   * `config` — gateDuration / cvLeadMs (taken from MIDIScheduler's
-- |     defaults during the migration).
-- |
-- | Voices push `dispatchEvent` calls here on each query window with
-- | { name, token, wallTimeUs }; the dispatcher looks up `name` in
-- | `bindings`, walks the PrimAction list, and formats + sends the
-- | OSC / MIDI for each.
-- |
-- | The actual format/send logic mirrors MIDIScheduler's BoundTrack
-- | dispatch (see MIDIScheduler.purs ~line 548). This module is the
-- | extract point — once PR1.4d wires the WS handler to set bindings
-- | on the dispatcher and voices push events through it, the BoundTrack
-- | path can be deleted from MIDIScheduler.
-- |
-- | NOT YET HANDLED at PR1.4c (deferred):
-- |   * Per-event param patterns (`# vel`, `# note`, etc.) — voices
-- |     don't track these yet.
-- |   * Compositional `#` joins (cross-binding fanout) — same reason.
-- |   * Continuous voices (LFO sample-and-emit). Different code path
-- |     in MIDIScheduler; will get its own migration step.
module Tidal.Dispatcher
  ( State
  , Config
  , MidiDevice
  , initialState
  , setBinding
  , removeBinding
  , registerMidiDevice
  , dispatchEvent
  , Snapshot
  , snapshot
  ) where

import Prelude

import Data.Foldable (for_)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Effect (Effect)
import Tidal.Binding (Binding, PrimAction(..))
import Tidal.Binding as Binding
import Tidal.Log as Log
import Tidal.MIDIBridge (BridgeClient, scheduleCCAt, scheduleNoteAt)
import Tidal.MIDIScheduler (clamp7bit, interpretCV, noteNameMidi)
import Tidal.OSC (OSCClient, sendCVAfter, sendES5GateTrigAfter, sendESXAfter, sendGateTrigAfter)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

type Config =
  { gateDuration :: Number  -- ms; how long /tidal/gate stays high
  , cvLeadMs :: Number      -- ms; CV pre-set head start before gate
  }

type MidiDevice =
  { name :: String          -- physical port name (e.g. "IAC Driver Tidal")
  , latencyMs :: Number     -- compensate by emitting this much earlier
  }

newtype State = State
  { bridgeClient :: BridgeClient
  , oscClient :: Maybe OSCClient
  , bindings :: Map String Binding
  , midiDevices :: Map String MidiDevice
  , config :: Config
  , eventCount :: Int
  }

initialState
  :: { bridgeClient :: BridgeClient
     , oscClient :: Maybe OSCClient
     , gateDuration :: Number
     , cvLeadMs :: Number
     }
  -> State
initialState init = State
  { bridgeClient: init.bridgeClient
  , oscClient: init.oscClient
  , bindings: Map.empty
  , midiDevices: Map.empty
  , config: { gateDuration: init.gateDuration, cvLeadMs: init.cvLeadMs }
  , eventCount: 0
  }

-- ---------------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------------

setBinding :: String -> Binding -> State -> State
setBinding name binding (State s) =
  State (s { bindings = Map.insert name binding s.bindings })

removeBinding :: String -> State -> State
removeBinding name (State s) =
  State (s { bindings = Map.delete name s.bindings })

registerMidiDevice :: String -> MidiDevice -> State -> State
registerMidiDevice alias device (State s) =
  State (s { midiDevices = Map.insert alias device s.midiDevices })

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Route one event. Looks up the binding, walks each PrimAction, and
-- | fires the appropriate OSC / MIDI. Increments the event counter.
-- |
-- | Unknown binding name = silent no-op (count still increments). The
-- | WS handler is the source of truth for which names exist; events
-- | for unbound names mean a voice exists for a name the dispatcher
-- | hasn't been told about yet (race during reconfig). Logging would
-- | be too noisy.
dispatchEvent
  :: { name :: String, token :: String, wallTimeUs :: Number }
  -> State
  -> Effect State
dispatchEvent { name, token, wallTimeUs } (State s) = do
  nowUs <- nowUnixMicros
  let
    delayMsRaw = (wallTimeUs - nowUs) / 1000.0
    delayClamped = max 0.0 delayMsRaw
    delayInt = Int.floor delayClamped
  case Map.lookup name s.bindings of
    Nothing -> pure unit
    Just binding ->
      for_ binding (dispatchPrimAction (State s) name token wallTimeUs delayClamped delayInt)
  pure (State (s { eventCount = s.eventCount + 1 }))

dispatchPrimAction
  :: State
  -> String         -- voice name (for logging)
  -> String         -- pattern token
  -> Number         -- absolute Unix microsecond fire time
  -> Number         -- ms delay from now (clamped)
  -> Int            -- floor of delayClamped, for human-readable logs
  -> PrimAction
  -> Effect Unit
dispatchPrimAction (State s) name token wallUs delayMs _delayInt = case _ of
  CV bus mapping ->
    case s.oscClient, interpretCV mapping token of
      Just osc, Just value -> do
        -- CV pre-sets fire `cvLeadMs` earlier than the gate, so V/oct
        -- has time to settle before the gate trigger arrives.
        let cvDelay = max 0.0 (delayMs - s.config.cvLeadMs)
        Log.debug $ "〰 [" <> name <> "] cv bus " <> show bus <> " = " <> show value
        sendCVAfter osc bus value cvDelay
      _, _ -> pure unit

  ESX e ->
    case s.oscClient, Number.fromString token of
      Just osc, Just value -> do
        let adjusted = max 0.0 (delayMs - Int.toNumber e.latencyMs)
        Log.debug $ "⌇ [" <> name <> "] esx slot " <> show e.slot <> " = " <> show value
        sendESXAfter osc e.slot value adjusted
      _, _ -> pure unit

  Gate g ->
    when (token /= "~") do
      case s.oscClient of
        Just osc -> do
          let adjusted = max 0.0 (delayMs - Int.toNumber g.latencyMs)
          Log.debug $ "⚡ [" <> name <> "] gate " <> show g.channel <> " in " <> show (Int.floor adjusted) <> "ms"
          sendGateTrigAfter osc g.channel s.config.gateDuration adjusted
        Nothing -> pure unit

  ES5Gate g ->
    when (token /= "~") do
      case s.oscClient of
        Just osc -> do
          let adjusted = max 0.0 (delayMs - Int.toNumber g.latencyMs)
          Log.debug $ "✦ [" <> name <> "] es5gate " <> show g.bit
          sendES5GateTrigAfter osc g.bit s.config.gateDuration adjusted
        Nothing -> pure unit

  MidiNote m ->
    when (token /= "~") do
      case Map.lookup m.device s.midiDevices of
        Nothing ->
          Log.debug $ "✗ [" <> name <> "] midi-note: unknown device alias '" <> m.device <> "'"
        Just dev -> do
          -- Token can override the default note; falls back to default
          -- for trigger-style names like "bd", "sn".
          let note = case Map.lookup token noteNameMidi of
                Just n -> n
                Nothing -> m.defaultNote
          let adjustedDelayMs = max 0.0 (delayMs - dev.latencyMs)
          let adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
          Log.debug $ "♪ [" <> name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " note " <> show note
          scheduleNoteAt s.bridgeClient dev.name m.channel note m.velocity m.durationMs adjustedUnixUs

  MidiCC m ->
    case Number.fromString token of
      Nothing -> pure unit  -- ~ rest or non-numeric → skip
      Just raw ->
        case Map.lookup m.device s.midiDevices of
          Nothing ->
            Log.debug $ "✗ [" <> name <> "] midi-cc: unknown device alias '" <> m.device <> "'"
          Just dev -> do
            let value7bit = clamp7bit (raw * 127.0)
            let adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
            Log.debug $ "◇ [" <> name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " cc" <> show m.cc <> " = " <> show value7bit
            scheduleCCAt s.bridgeClient dev.name m.channel m.cc value7bit adjustedUnixUs

-- ---------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------

type Snapshot =
  { eventsReceived :: Int
  , bindingCount :: Int
  , midiDeviceCount :: Int
  , oscEnabled :: Boolean
  }

snapshot :: State -> Snapshot
snapshot (State s) =
  { eventsReceived: s.eventCount
  , bindingCount: Map.size s.bindings
  , midiDeviceCount: Map.size s.midiDevices
  , oscEnabled: case s.oscClient of
      Just _ -> true
      Nothing -> false
  }

-- ---------------------------------------------------------------------------
-- Foreign — system_time(microsecond) for delay computation.
-- ---------------------------------------------------------------------------

foreign import nowUnixMicros :: Effect Number
