-- | The PureScript-side session walker — PR 1.5 of the DSL naming
-- | refactor.  Embodies the PureScript/Erlang boundary principle:
-- |
-- |   *Type-discrimination logic lives in PureScript; OTP/ETS/IO/
-- |   scheduling lives in Erlang.  The boundary between them is a
-- |   small set of flat registration-event ADTs.*
-- |
-- | The Erlang shell (`src/tidal_session_walker.erl`) calls
-- | `walkBaseline/0` here, gets back an `Array RegistrationEvent`,
-- | and folds each event into the dispatcher via `apply_event/1`.
-- | The shell never reaches into purs-backend-erl-encoded ADT
-- | shapes (no `element/2` against an `Instrument` tuple, no
-- | `maps:keys` against a `PitchedPart` newtype-elided record).
-- |
-- | When a new destination kind lands (PR 2: DrumKit,
-- | VPerOctInstrument), the additions live in **one** place: the
-- | `classify` function below + the corresponding `apply_event/1`
-- | clause on the Erlang shell side.  Two coordinated edits, no
-- | scattered structural checks.
-- |
-- | Companion: `src/Tidal/SessionWalker.erl` (FFI primitives only).
module Tidal.SessionWalker
  ( RegistrationEvent(..)
  , walkBaseline
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Foreign (Foreign)
import Tidal.MidiClaim
  ( MidiClaim
  , claimErrorToBoundary
  , validateMidiClaims
  )
import Tidal.PortClaim (ClaimError, OwnerKind(..))
import Tidal.PolySignal as PolySignal

-- ---------------------------------------------------------------------------
-- The boundary ADT
-- ---------------------------------------------------------------------------

-- | The flat, intentional ADT that crosses the PureScript ↔ Erlang
-- | boundary.  Adding a new kind here is one constructor + one
-- | `classify` clause + one Erlang `apply_event/1` clause.  No
-- | other code needs to change.
data RegistrationEvent
  = RegisterMidiDevice
      { alias :: String
      , name :: String
      , latencyMs :: Int
      }
  -- | PR 2c: a named cv-router endpoint declared in Studio.  Today
  -- | informational only (the runtime routes all OSC through a
  -- | singleton client opened against the default host:port);
  -- | PR 2c.2 will hook this up to per-alias OSCClients.
  | RegisterCvRouter
      { alias :: String
      , host :: String
      , port :: Int
      }
  | RegisterMidiInstrument
      { alias :: String
      , deviceAlias :: String
      , channel :: Int
      , defNote :: Int
      , defVel :: Int
      , defDurMs :: Int
      -- The raw Instrument value, passed through opaquely so the
      -- Erlang shell can use it as the key in the `lookup_channel_
      -- alias/1` ETS table without structurally inspecting it.
      , instrumentValue :: Foreign
      }
  -- | PR 2c: a V/oct instrument routed through cv-router.  Walks to
  -- | a compound `gate <gateChannel> + cv <voctBus> voct` binding
  -- | spec that the dispatcher already understands via existing
  -- | Gate + CV NoteNameVoct PrimActions.
  | RegisterVPerOctInstrument
      { alias :: String
      , routerAlias :: String
      , gateChannel :: Int
      , voctBus :: Int
      , instrumentValue :: Foreign
      }
  | RegisterMidiDrumKit
      { alias :: String
      , deviceAlias :: String
      , channel :: Int
      -- PR 2b: the kit registers as a single `MidiDrumKit` PrimAction
      -- binding carrying ALL hits.  Each hit's (name, note, vel,
      -- durMs) becomes an entry in the dispatcher's per-binding hits
      -- map; per-event dispatch looks up the event's token string
      -- (the hit name) at emit time.
      , hits :: Array
          { name :: String, note :: Int, vel :: Int, durMs :: Int }
      -- The raw DrumKit value — same opaque-ETS-key role as
      -- `instrumentValue` above.  Lets the conductor resolve
      -- `lookup_channel_alias(DrumKitValue)` for arm dispatch.
      , drumKitValue :: Foreign
      }
  -- | PR 2c: a gate-emitting drum kit routed through cv-router.
  -- | Parallel to MidiDrumKit but each hit is a cv-router gate
  -- | channel + duration; dispatcher fires `/cv/trig`-style gate
  -- | pulses per event via the existing GateDrumKit PrimAction
  -- | (added in PR 2c).
  | RegisterGateDrumKit
      { alias :: String
      , routerAlias :: String
      , hits :: Array
          { name :: String, gateChannel :: Int, durMs :: Int }
      , drumKitValue :: Foreign
      }
  -- | Slab C step 1 (2026-05-18): an autonomous FH-2 polysignal
  -- | (LFO bank, clock-bus, ADSR cluster, euclid machine, random
  -- | sequencer) declared as a typed Session-level binding.  The
  -- | walker classifies by constructor tag, projects the value to
  -- | the JSON envelope the daemon already understands, and emits
  -- | this event.  Erlang side hands the envelope verbatim to
  -- | `fh2_daemon_call("apply-polysignal <json>")` — claim happens
  -- | at the daemon's `Rig.applyWithClaims` boundary, conflicts
  -- | surface as boot-time errors via the daemon's reply.
  | RegisterPolySignal
      { alias :: String
      , family :: String
      , jsonEnvelope :: String
      }
  -- | Front-end reservations Phase 1: emitted when two or more Studio
  -- | declarations land on the same MIDI (device, channel).  Erlang
  -- | shell logs the `message` via `tidal_log:err` and bumps a
  -- | claimErrors counter; registration of the conflicting bindings
  -- | still proceeds (warn-only — the last write wins as before, the
  -- | user just learns about the collision now).
  | ReportClaimError
      { errorKind :: String
      , deviceAlias :: String
      , channel :: Int
      , owners :: Array { name :: String, kind :: String }
      , message :: String
      }

-- ---------------------------------------------------------------------------
-- Walk
-- ---------------------------------------------------------------------------

-- | Enumerate the Studio + Session modules' nullary exports,
-- | classify each, return a flat array of registration events.
-- | Erlang's shell invokes this via the Effect thunk.
walkBaseline :: Effect (Array RegistrationEvent)
walkBaseline = do
  studioPairs <- enumerateExports "studio@ps"
  sessionPairs <- enumerateExports "calypso_generated_session@ps"
  let allPairs = studioPairs <> sessionPairs
  -- First pass: device + cv-router events + content-keyed alias maps.
  -- We need the alias maps to resolve each instrument's / drum-kit's
  -- inner device / cv-router tuple back to the alias the user gave
  -- their MidiDevice / CvRouter declaration.
  let
    devices = Array.mapMaybe pickDevice allPairs
    deviceAliases :: Map (Tuple String Int) String
    deviceAliases = Map.fromFoldable
      (map (\d -> Tuple (Tuple d.name d.latencyMs) d.alias) devices)
    routers = Array.mapMaybe pickCvRouter allPairs
    routerAliases :: Map (Tuple String Int) String
    routerAliases = Map.fromFoldable
      (map (\r -> Tuple (Tuple r.host r.port) r.alias) routers)
    devEvents = map (\d -> RegisterMidiDevice d) devices
    routerEvents = map (\r -> RegisterCvRouter r) routers
    instrEvents = Array.mapMaybe
      (pickInstrument deviceAliases routerAliases) allPairs
    kitEvents = Array.mapMaybe
      (pickDrumKit deviceAliases routerAliases) allPairs
    -- Slab C step 1: polysignals.  Self-contained typed values
    -- whose alias is the binding name; no device/router lookup
    -- needed.  The walker only projects to a JSON envelope, the
    -- daemon does the real claim work at apply-time.
    polySigEvents = Array.mapMaybe pickPolySignal allPairs
    -- Phase 1: collect implicit (device, channel) claims from
    -- registration events, group by (device, channel), report any
    -- duplicates as `ReportClaimError` events.  Errors are emitted
    -- BEFORE registration events so the Erlang log shows them ahead
    -- of the binding installs they conflict with.
    claims = Array.mapMaybe registrationToClaim (instrEvents <> kitEvents)
    claimErrorEvents = Array.mapMaybe claimErrorToEvent (validateMidiClaims claims)
  pure (claimErrorEvents <> devEvents <> routerEvents
        <> instrEvents <> kitEvents <> polySigEvents)

registrationToClaim :: RegistrationEvent -> Maybe MidiClaim
registrationToClaim = case _ of
  RegisterMidiInstrument r -> Just
    { owner: r.alias
    , deviceAlias: r.deviceAlias
    , channel: r.channel
    , ownerKind: OwnInstrument
    }
  RegisterMidiDrumKit r -> Just
    { owner: r.alias
    , deviceAlias: r.deviceAlias
    , channel: r.channel
    , ownerKind: OwnDrumKit
    }
  _ -> Nothing

-- | Lift a `Tidal.PortClaim.ClaimError` into a wire-shaped
-- | `ReportClaimError` registration event.  Drops claim errors that
-- | don't flatten to MIDI's (device, channel) shape — Phase 2 only
-- | walks MIDI claims, but the machinery accepts richer shapes for
-- | when ES-9 / FH-2 claims start flowing through here.
claimErrorToEvent :: ClaimError -> Maybe RegistrationEvent
claimErrorToEvent err = case claimErrorToBoundary err of
  Just r -> Just $ ReportClaimError r
  Nothing -> Nothing

-- | The classifier — the only place that knows what purs-backend-erl
-- | tags map to what application meaning.  Returns Nothing for any
-- | export shape we don't recognise (helpers, top-level pattern
-- | values, the Session record itself).
pickDevice
  :: { name :: String, value :: Foreign }
  -> Maybe { alias :: String, name :: String, latencyMs :: Int }
pickDevice { name: alias, value } = do
  tag <- constructorTag value
  if tag /= "midiDevice" then Nothing
  else do
    nameArg <- tupleArg 0 value
    latArg <- tupleArg 1 value
    devName <- asBinary nameArg
    devLat <- asInt latArg
    Just { alias, name: devName, latencyMs: devLat }

-- | Classify a `CvRouter` value.  Encoding from purs-backend-erl:
-- |     data CvRouter = CvRouter String Int
-- | becomes `{cvRouter, <<"127.0.0.1">>, 57120}`.
pickCvRouter
  :: { name :: String, value :: Foreign }
  -> Maybe { alias :: String, host :: String, port :: Int }
pickCvRouter { name: alias, value } = do
  tag <- constructorTag value
  if tag /= "cvRouter" then Nothing
  else do
    hostArg <- tupleArg 0 value
    portArg <- tupleArg 1 value
    host <- asBinary hostArg
    port <- asInt portArg
    Just { alias, host, port }

-- | Classify an `Instrument` value.  Dispatches on the constructor
-- | tag to MidiInstrument vs VPerOctInstrument variants.
pickInstrument
  :: Map (Tuple String Int) String
  -> Map (Tuple String Int) String
  -> { name :: String, value :: Foreign }
  -> Maybe RegistrationEvent
pickInstrument deviceAliases routerAliases { name: alias, value } = do
  tag <- constructorTag value
  case tag of
    "midiInstrument" -> pickMidiInstrument deviceAliases alias value
    "vPerOctInstrument" -> pickVPerOctInstrument routerAliases alias value
    _ -> Nothing

pickMidiInstrument
  :: Map (Tuple String Int) String
  -> String
  -> Foreign
  -> Maybe RegistrationEvent
pickMidiInstrument deviceAliases alias value = do
  devArg <- tupleArg 0 value
  chArg <- tupleArg 1 value
  noteArg <- tupleArg 2 value
  velArg <- tupleArg 3 value
  durArg <- tupleArg 4 value
  -- Re-classify the inner device tuple to get its (name, latencyMs).
  -- A MidiInstrument carries a MidiDevice value (not just an alias);
  -- we look up the alias from the content-keyed map.
  devTag <- constructorTag devArg
  if devTag /= "midiDevice" then Nothing
  else do
    devNameArg <- tupleArg 0 devArg
    devLatArg <- tupleArg 1 devArg
    devName <- asBinary devNameArg
    devLat <- asInt devLatArg
    ch <- asInt chArg
    note <- asInt noteArg
    vel <- asInt velArg
    dur <- asInt durArg
    let deviceAlias = fromMaybe ""
          (Map.lookup (Tuple devName devLat) deviceAliases)
    Just $ RegisterMidiInstrument
      { alias
      , deviceAlias
      , channel: ch
      , defNote: note
      , defVel: vel
      , defDurMs: dur
      , instrumentValue: value
      }

-- | Classify a `VPerOctInstrument` value.  Encoding:
-- |   data Instrument = ... | VPerOctInstrument CvRouter { gateChannel, voctBus }
-- | becomes `{vPerOctInstrument, CvRouterTuple, #{gateChannel, voctBus}}`.
pickVPerOctInstrument
  :: Map (Tuple String Int) String
  -> String
  -> Foreign
  -> Maybe RegistrationEvent
pickVPerOctInstrument routerAliases alias value = do
  routerArg <- tupleArg 0 value
  recArg <- tupleArg 1 value
  routerTag <- constructorTag routerArg
  if routerTag /= "cvRouter" then Nothing
  else do
    hostArg <- tupleArg 0 routerArg
    portArg <- tupleArg 1 routerArg
    host <- asBinary hostArg
    port <- asInt portArg
    { gateChannel, voctBus } <- vPerOctFields recArg
    let routerAlias = fromMaybe ""
          (Map.lookup (Tuple host port) routerAliases)
    Just $ RegisterVPerOctInstrument
      { alias
      , routerAlias
      , gateChannel
      , voctBus
      , instrumentValue: value
      }

-- | Classify a `DrumKit` value.  Dispatches on tag to MidiDrumKit
-- | vs GateDrumKit variants.
pickDrumKit
  :: Map (Tuple String Int) String
  -> Map (Tuple String Int) String
  -> { name :: String, value :: Foreign }
  -> Maybe RegistrationEvent
pickDrumKit deviceAliases routerAliases { name: alias, value } = do
  tag <- constructorTag value
  case tag of
    "midiDrumKit" -> pickMidiDrumKit deviceAliases alias value
    "gateDrumKit" -> pickGateDrumKit routerAliases alias value
    _ -> Nothing

-- | Classify a `MidiDrumKit` value.  Encoding from purs-backend-erl:
-- |     data DrumKit = MidiDrumKit MidiDevice Int (Array DrumHit) | ...
-- | becomes `{midiDrumKit, DeviceTuple, Ch, HitsArray}`.  We unpack
-- | device + channel + the full hits array; the Erlang shell turns
-- | each hit into a binding entry.
pickMidiDrumKit
  :: Map (Tuple String Int) String
  -> String
  -> Foreign
  -> Maybe RegistrationEvent
pickMidiDrumKit deviceAliases alias value = do
  devArg <- tupleArg 0 value
  chArg <- tupleArg 1 value
  hitsArg <- tupleArg 2 value
  devTag <- constructorTag devArg
  if devTag /= "midiDevice" then Nothing
  else do
    devNameArg <- tupleArg 0 devArg
    devLatArg <- tupleArg 1 devArg
    devName <- asBinary devNameArg
    devLat <- asInt devLatArg
    ch <- asInt chArg
    let deviceAlias = fromMaybe ""
          (Map.lookup (Tuple devName devLat) deviceAliases)
    -- Hits encode as records `#{name, note, vel, durMs}` carried
    -- inside an Erlang `array`.  `drumKitHits` decodes the whole
    -- array; empty / malformed input returns an empty array.  The
    -- Erlang shell then builds `midi-drum-kit <device> <channel>
    -- name:note:vel:dur,…` and installs the binding.
    let hits = drumKitHits hitsArg
    Just $ RegisterMidiDrumKit
      { alias
      , deviceAlias
      , channel: ch
      , hits
      , drumKitValue: value
      }

-- | Classify a `GateDrumKit` value.  Encoding from purs-backend-erl:
-- |   data DrumKit = ... | GateDrumKit CvRouter (Array GateHit)
-- | becomes `{gateDrumKit, CvRouterTuple, HitsArray}`.
pickGateDrumKit
  :: Map (Tuple String Int) String
  -> String
  -> Foreign
  -> Maybe RegistrationEvent
pickGateDrumKit routerAliases alias value = do
  routerArg <- tupleArg 0 value
  hitsArg <- tupleArg 1 value
  routerTag <- constructorTag routerArg
  if routerTag /= "cvRouter" then Nothing
  else do
    hostArg <- tupleArg 0 routerArg
    portArg <- tupleArg 1 routerArg
    host <- asBinary hostArg
    port <- asInt portArg
    let routerAlias = fromMaybe ""
          (Map.lookup (Tuple host port) routerAliases)
    let hits = gateDrumKitHits hitsArg
    Just $ RegisterGateDrumKit
      { alias
      , routerAlias
      , hits
      , drumKitValue: value
      }

-- ---------------------------------------------------------------------------
-- PolySignal classifier (Slab C step 1)
-- ---------------------------------------------------------------------------

-- | Classify a `PolySignal` value declared at the Session level.
-- | Today: PolyLfoConfig only.  Other four families land in step 2
-- | (PolyClock, PolyEnv, PolyEuclid, PolyRand) with the same pattern:
-- | one classifier clause per constructor tag, projecting to the
-- | shared JSON envelope shape.
pickPolySignal
  :: { name :: String, value :: Foreign }
  -> Maybe RegistrationEvent
pickPolySignal { name: alias, value } = do
  tag <- constructorTag value
  case tag of
    "polyLfoConfig" -> do
      fields <- polyLfoConfigFields value
      let polysig = PolySignal.polyLfo fields.bank fields.slots fields.range
          envelopeJson = PolySignal.polySignalAsJson alias polysig
          family = PolySignal.polySignalFamily polysig
      Just $ RegisterPolySignal
        { alias, family, jsonEnvelope: envelopeJson }
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- FFI primitives — minimal, knowledge-free
-- ---------------------------------------------------------------------------
--
-- These primitives encapsulate the *only* structural knowledge of
-- purs-backend-erl's encoding that exists on the Erlang side: tagged
-- tuples have a tag atom in element 1, fields in 2..N; binaries and
-- ints are themselves.  Everything else (which tags mean what,
-- which fields mean what) is in the PureScript classifier above.

-- | Enumerate the 0-arity exports of a loaded BEAM module.  Returns
-- | `name` (the PureScript identifier — used as alias) and `value`
-- | (the export's runtime value, as Foreign).
foreign import enumerateExports
  :: String -> Effect (Array { name :: String, value :: Foreign })

-- | If the value is a tagged tuple (tuple with an atom in element 1),
-- | return the tag as a String.  Used to dispatch on PureScript
-- | constructor names.
foreign import constructorTag :: Foreign -> Maybe String

-- | If the value is a tuple with at least N+1 elements (1 for the
-- | tag plus N constructor args), return the Nth (0-indexed)
-- | constructor argument as Foreign.
foreign import tupleArg :: Int -> Foreign -> Maybe Foreign

-- | Convert a Foreign that's actually a binary into a String.
foreign import asBinary :: Foreign -> Maybe String

-- | Convert a Foreign that's actually an integer into an Int.
foreign import asInt :: Foreign -> Maybe Int

-- | Decode every DrumHit in a kit's `Array DrumHit` (Erlang stdlib
-- | `array`) to a flat PureScript array of `{name, note, vel, durMs}`
-- | records.  Empty / malformed / missing input returns `[]`.  The
-- | caller then encodes each hit into the `midi-drum-kit` spec.
foreign import drumKitHits
  :: Foreign
  -> Array { name :: String, note :: Int, vel :: Int, durMs :: Int }

-- | Decode every GateHit in a gate-kit's `Array GateHit` to a flat
-- | PureScript array of `{name, gateChannel, durMs}` records.
-- | Parallel to `drumKitHits` but for the gate-side drum kit
-- | (PR 2c).  Empty / malformed / missing input returns `[]`.
foreign import gateDrumKitHits
  :: Foreign
  -> Array { name :: String, gateChannel :: Int, durMs :: Int }

-- | Decode the inner `{ gateChannel :: Int, voctBus :: Int }` record
-- | of a VPerOctInstrument.  Returns Nothing if the value isn't a
-- | map with the two expected integer keys.
foreign import vPerOctFields
  :: Foreign
  -> Maybe { gateChannel :: Int, voctBus :: Int }

-- | Decode the inner record of a `PolyLfoConfig` value.  The encoding
-- | from purs-backend-erl is bit-compatible with the typed PureScript
-- | record, so the FFI just passes the inner map through after
-- | verifying it carries the three expected keys.  See the Erlang
-- | clause for the structural details.
foreign import polyLfoConfigFields
  :: Foreign
  -> Maybe
       { bank :: PolySignal.Bank
       , slots :: Array PolySignal.LfoSlot
       , range :: Maybe PolySignal.OutputRange
       }
