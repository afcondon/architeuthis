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
  , setBindingFromSpec
  , removeBinding
  , lookupBinding
  , registerMidiDevice
  , dispatchEvent
  , Snapshot
  , snapshot
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Tuple (Tuple(..))
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
import Tidal.Dispatch.Helpers (clamp7bit, interpretCV, noteNameMidi, param7bit)
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

-- | Parse a `bind <name> <action-spec>` body and install the resulting
-- | Binding. Returns Left with the parser's error message if the spec
-- | doesn't parse as a discrete binding.
-- |
-- | Continuous-binding specs (`midi-cc-cont …`, `cv-cont …`) currently
-- | return Left because the dispatcher has no `continuousBindings`
-- | field yet — they'll get a proper home in PR1.5. The Erlang shell
-- | swallows the error during the PR1.4d-i dual-write transition;
-- | MIDIScheduler still handles continuous bindings as before.
setBindingFromSpec :: String -> String -> State -> Either String State
setBindingFromSpec name spec st =
  case Binding.parseCompoundAction spec of
    Left err -> Left err
    Right binding -> Right (setBinding name binding st)

removeBinding :: String -> State -> State
removeBinding name (State s) =
  State (s { bindings = Map.delete name s.bindings })

-- | Look up a binding by name. Used by the WS handler at PR1.4d-ii-b
-- | to decide whether to install a voice in the new tree (binding
-- | exists) or fall back to MIDIScheduler's legacy whole-message
-- | pattern path (unbound name).
lookupBinding :: String -> State -> Maybe Binding
lookupBinding name (State s) = Map.lookup name s.bindings

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
  :: { name :: String
     , token :: String
     , wallTimeUs :: Number
     , params :: Map String String
     }
  -> State
  -> Effect State
dispatchEvent { name, token, wallTimeUs, params } (State s) = do
  nowUs <- nowUnixMicros
  let
    delayMsRaw = (wallTimeUs - nowUs) / 1000.0
    delayClamped = max 0.0 delayMsRaw
    delayInt = Int.floor delayClamped
  case Map.lookup name s.bindings of
    Nothing -> pure unit
    Just binding -> do
      -- 1. Per-PrimAction dispatch: each action fires once per event,
      --    consulting `params` for slot overrides where applicable.
      for_ binding
        (dispatchPrimAction (State s) name token wallTimeUs delayClamped
                            delayInt params)
      -- 2. Compositional `#` fanout: any param NAME that matches another
      --    registered binding fires that binding's MidiCC actions with
      --    the joined value as the token. Slot-override params (consumed
      --    by step 1) are skipped here to avoid double-fire.
      for_ (Map.toUnfoldable params :: Array (Tuple String String))
        \(Tuple paramName paramValue) ->
          when (not (isSlotOverride paramName binding)) do
            dispatchComposedFanout (State s) name paramName paramValue
                                   wallTimeUs delayClamped
  pure (State (s { eventCount = s.eventCount + 1 }))

dispatchPrimAction
  :: State
  -> String              -- voice name (for logging)
  -> String              -- pattern token
  -> Number              -- absolute Unix microsecond fire time
  -> Number              -- ms delay from now (clamped)
  -> Int                 -- floor of delayClamped, for human-readable logs
  -> Map String String   -- pre-sampled per-event params for slot overrides
  -> PrimAction
  -> Effect Unit
dispatchPrimAction (State s) name token wallUs delayMs _delayInt params = case _ of
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
          -- `# vel "..."` slot override: param value (already sampled
          -- at the event's cycle by the voice) overrides the binding's
          -- default velocity. Out-of-range / non-numeric tokens fall
          -- back to the binding default.
          let velocity = case Map.lookup "vel" params of
                Nothing -> m.velocity
                Just velTok -> case param7bit velTok of
                  Just v -> v
                  Nothing -> m.velocity
          let adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
          Log.debug $ "♪ [" <> name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " note " <> show note <> " vel " <> show velocity
          scheduleNoteAt s.bridgeClient dev.name m.channel note velocity m.durationMs adjustedUnixUs

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

-- | Is this `#` parameter name consumed by a slot override on any of
-- | the binding's actions? If yes, the per-PrimAction dispatch already
-- | used it; the compositional fallback skips it to avoid double-fire.
-- |
-- | Currently only `vel` is a recognised slot, applying to MidiNote
-- | actions. Extend as more slots become pattern-driven.
isSlotOverride :: String -> Binding -> Boolean
isSlotOverride paramName binding = case paramName of
  "vel" -> Array.any isMidiNote binding
    where
    isMidiNote = case _ of
      MidiNote _ -> true
      _ -> false
  _ -> false

-- | Compositional `#` fanout: when a param name matches another
-- | registered binding, fire that binding's MidiCC actions with the
-- | joined value as the token. Currently MidiCC composition only —
-- | other action types ignored. This is how `lap "x*4" #
-- | laplace-resonator-strength "0.2 0.7"` both plays the note AND
-- | sweeps the resonator CC.
dispatchComposedFanout
  :: State
  -> String   -- structure-binding name (for logging)
  -> String   -- param name
  -> String   -- pre-sampled param value
  -> Number   -- absolute Unix microsecond fire time
  -> Number   -- ms delay from now (clamped)
  -> Effect Unit
dispatchComposedFanout (State s) structName paramName paramValue wallUs delayMs =
  case Map.lookup paramName s.bindings of
    Nothing -> pure unit
    Just composedBinding -> for_ composedBinding case _ of
      MidiCC m -> case Number.fromString paramValue of
        Nothing -> pure unit
        Just raw ->
          case Map.lookup m.device s.midiDevices of
            Nothing -> pure unit
            Just dev -> do
              let v7 = clamp7bit (raw * 127.0)
              let dms = max 0.0 (delayMs - dev.latencyMs)
              let uus = wallUs - dev.latencyMs * 1000.0
              Log.debug $ "  ◇ [" <> structName <> " # " <> paramName <> "] cc " <> show m.cc <> " = " <> show v7 <> " in " <> show (Int.floor dms) <> "ms"
              scheduleCCAt s.bridgeClient dev.name m.channel m.cc v7 uus
      _ -> pure unit  -- only MidiCC composition for now

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
