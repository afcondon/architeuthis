-- | State publisher — produces the JSON snapshot Calypso reads via
-- | the `state` verb.
-- |
-- | Was inlined in `Tidal.MIDIScheduler.publishState` until PR1.7c.
-- | Now driven by a separate `tidal_state_pub` gen_server that
-- | gathers data from `tidal_clock` + `tidal_dispatcher` on a timer
-- | and writes the rendered JSON to the StateBus ETS row.
-- |
-- | This module is pure — no Effect, no foreign — so it's easy to
-- | smoke-test and to evolve the JSON shape without touching the
-- | gen_server.
-- |
-- | ## JSON shape (PR1.7c — trimmed)
-- |
-- | ```json
-- | {
-- |   "config": {
-- |     "bpm": 120.0,
-- |     "tickIntervalMs": 50,
-- |     "lookAheadMs": 200.0,
-- |     "gate": {
-- |       "enabled": true,
-- |       "gateDurationMs": 50.0,
-- |       "cvLeadMs": 5.0
-- |     }
-- |   },
-- |   "midiDevices":        [ { alias, name, latencyMs }, … ],
-- |   "bindingNames":       [ "kick", "plaits", … ],
-- |   "voices":             [ { name, signature, sinks }, … ],
-- |   "continuousBindings": [ { name, dest }, … ],
-- |   "fh2VoiceChannels":   [ { voice, channel }, … ]
-- | }
-- | ```
-- |
-- | The pre-PR1.7c shape had additional `tracks`, `continuousTracks`,
-- | `midi.*`, `gate.{oscHost,oscPort,channelOffset}`, and
-- | `noteDurationMs` fields — all dropped because they referenced
-- | obsolete state (legacy track types, default MIDI device, gate-
-- | channel arithmetic). Calypso's only structural read is
-- | `config.bpm`; everything else is rendered as raw JSON for the
-- | config pane.
module Tidal.StatePublisher
  ( PublisherInputs
  , ClockInputs
  , DispatcherInputs
  , serializeSnapshot
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.String as String
import Data.String (joinWith) as Str
import Data.Tuple (Tuple(..))
import Tidal.Binding (Binding, ContDest(..))
import Tidal.Sink as Sink

-- ---------------------------------------------------------------------------
-- Inputs the gen_server gathers and passes to `serializeSnapshot`
-- ---------------------------------------------------------------------------

-- | Everything the publisher needs in one record. The Erlang shell
-- | shuttles the dispatcher and clock snapshots into this shape on
-- | each publish tick.
type PublisherInputs =
  { clock :: ClockInputs
  , dispatcher :: DispatcherInputs
  }

-- | Subset of `Tidal.Clock.Snapshot` the publisher reads. Mirrored
-- | here so the publisher doesn't have to import `Tidal.Clock`
-- | directly (avoids a layer-skipping dependency).
type ClockInputs =
  { bpm :: Number
  , tickIntervalMs :: Int
  , lookAheadMs :: Number
  }

-- | Mirror of `Tidal.Dispatcher.PublisherSnapshot`. The Erlang
-- | dispatcher exposes this via `get_publisher_snapshot/0`; the
-- | publisher gen_server passes it through verbatim.
type DispatcherInputs =
  { bindings :: Map String Binding
  , continuousBindings :: Map String ContDest
  , midiDevices :: Map String { name :: String, latencyMs :: Number }
  , fh2VoiceChannels :: Map Int Int
  , gateEnabled :: Boolean
  , gateDurationMs :: Number
  , cvLeadMs :: Number
  }

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

serializeSnapshot :: PublisherInputs -> String
serializeSnapshot inputs =
  "{\"config\":" <> renderConfig inputs.clock inputs.dispatcher
    <> ",\"midiDevices\":" <> renderMidiDevices inputs.dispatcher.midiDevices
    <> ",\"bindingNames\":" <> renderBindingNames inputs.dispatcher.bindings
                                                  inputs.dispatcher.continuousBindings
    <> ",\"voices\":" <> renderVoices inputs.dispatcher.bindings
                                      inputs.dispatcher.continuousBindings
    <> ",\"continuousBindings\":" <> renderContinuousBindings inputs.dispatcher.continuousBindings
    <> ",\"fh2VoiceChannels\":" <> renderFh2VoiceChannels inputs.dispatcher.fh2VoiceChannels
    <> "}"

renderConfig :: ClockInputs -> DispatcherInputs -> String
renderConfig clock disp =
  "{"
    <> "\"bpm\":" <> show clock.bpm
    <> ",\"tickIntervalMs\":" <> show clock.tickIntervalMs
    <> ",\"lookAheadMs\":" <> show clock.lookAheadMs
    <> ",\"gate\":{"
    <>   "\"enabled\":" <> jsBool disp.gateEnabled
    <>   ",\"gateDurationMs\":" <> show disp.gateDurationMs
    <>   ",\"cvLeadMs\":" <> show disp.cvLeadMs
    <> "}"
    <> "}"

renderMidiDevices
  :: Map String { name :: String, latencyMs :: Number }
  -> String
renderMidiDevices devices =
  jsArrOf entry
    (Map.toUnfoldable devices :: Array (Tuple String { name :: String, latencyMs :: Number }))
  where
    entry (Tuple alias dev) =
      "{\"alias\":" <> jsStr alias
        <> ",\"name\":" <> jsStr dev.name
        <> ",\"latencyMs\":" <> show dev.latencyMs <> "}"

-- | Union of discrete + continuous binding names. Sorted-by-Map keys
-- | from each, concatenated. Calypso's `bindingNames` consumer is a
-- | flat list either way.
renderBindingNames
  :: Map String Binding
  -> Map String ContDest
  -> String
renderBindingNames bindings contBindings =
  jsArrOf jsStr
    ( Array.fromFoldable (Map.keys bindings)
   <> Array.fromFoldable (Map.keys contBindings)
    )

-- | Voices array: one entry per binding name (discrete + continuous).
-- | Each entry carries the binding's sink-type signature for Calypso's
-- | Voices pane rendering.
renderVoices
  :: Map String Binding
  -> Map String ContDest
  -> String
renderVoices bindings contBindings =
  let
    discreteEntries =
      map
        (\(Tuple name b) ->
          renderVoiceEntry name (Sink.bindingSinkTypes b))
        (Map.toUnfoldable bindings :: Array (Tuple String Binding))
    continuousEntries =
      map
        (\(Tuple name d) ->
          renderVoiceEntry name [contDestToSinkType d])
        (Map.toUnfoldable contBindings :: Array (Tuple String ContDest))
  in
    "[" <> Str.joinWith "," (discreteEntries <> continuousEntries) <> "]"

renderVoiceEntry :: String -> Array Sink.SinkType -> String
renderVoiceEntry name sinks =
  "{\"name\":" <> jsStr name
    <> ",\"signature\":" <> jsStr (Str.joinWith " ⊕ " (map Sink.renderSinkType sinks))
    <> ",\"sinks\":" <> jsArrOf Sink.renderSinkTypeJSON sinks
    <> "}"

renderContinuousBindings :: Map String ContDest -> String
renderContinuousBindings contBindings =
  jsArrOf
    (\(Tuple n d) ->
      "{\"name\":" <> jsStr n <> ",\"dest\":" <> renderContDest d <> "}")
    (Map.toUnfoldable contBindings :: Array (Tuple String ContDest))

renderContDest :: ContDest -> String
renderContDest = case _ of
  ContMidiCC m ->
    "{\"kind\":\"midi-cc-cont\",\"device\":" <> jsStr m.device
      <> ",\"channel\":" <> show m.channel
      <> ",\"cc\":" <> show m.cc <> "}"
  ContCV c ->
    "{\"kind\":\"cv-cont\",\"bus\":" <> show c.bus <> "}"

renderFh2VoiceChannels :: Map Int Int -> String
renderFh2VoiceChannels chans =
  jsArrOf entry (Map.toUnfoldable chans :: Array (Tuple Int Int))
  where
    entry (Tuple voice channel) =
      "{\"voice\":" <> show voice
        <> ",\"channel\":" <> show channel <> "}"

-- | Convert a `ContDest` to its `SinkType` for the voices array.
-- | Mirrors `Tidal.MIDIScheduler.contDestToSinkType` (was the only
-- | consumer pre-PR1.7c).
contDestToSinkType :: ContDest -> Sink.SinkType
contDestToSinkType = case _ of
  ContMidiCC m -> Sink.SinkContMidiCC
    { device: m.device, channel: m.channel, cc: m.cc }
  ContCV c -> Sink.SinkContCV { bus: c.bus }

-- ---------------------------------------------------------------------------
-- JSON helpers (private — copied from MIDIScheduler.publishState)
-- ---------------------------------------------------------------------------

jsStr :: String -> String
jsStr s = "\"" <> escapeJson s <> "\""

jsBool :: Boolean -> String
jsBool b = if b then "true" else "false"

jsArrOf :: forall a. (a -> String) -> Array a -> String
jsArrOf f xs = "[" <> Str.joinWith "," (map f xs) <> "]"

escapeJson :: String -> String
escapeJson s0 =
  let s1 = String.replaceAll (String.Pattern "\\") (String.Replacement "\\\\") s0
      s2 = String.replaceAll (String.Pattern "\"") (String.Replacement "\\\"") s1
  in s2
