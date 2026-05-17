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
  -- First pass: device events + content-keyed alias map.  We need the
  -- alias map to resolve each instrument's / drum-kit's inner
  -- device-tuple back to the alias the user gave their MidiDevice
  -- declaration.
  let
    devices = Array.mapMaybe pickDevice allPairs
    deviceAliases :: Map (Tuple String Int) String
    deviceAliases = Map.fromFoldable
      (map (\d -> Tuple (Tuple d.name d.latencyMs) d.alias) devices)
    devEvents = map (\d -> RegisterMidiDevice d) devices
    instrEvents = Array.mapMaybe (pickInstrument deviceAliases) allPairs
    kitEvents = Array.mapMaybe (pickDrumKit deviceAliases) allPairs
  pure (devEvents <> instrEvents <> kitEvents)

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

pickInstrument
  :: Map (Tuple String Int) String
  -> { name :: String, value :: Foreign }
  -> Maybe RegistrationEvent
pickInstrument deviceAliases { name: alias, value } = do
  tag <- constructorTag value
  if tag /= "instrument" then Nothing
  else do
    devArg <- tupleArg 0 value
    chArg <- tupleArg 1 value
    noteArg <- tupleArg 2 value
    velArg <- tupleArg 3 value
    durArg <- tupleArg 4 value
    -- Re-classify the inner device tuple to get its (name, latencyMs).
    -- An Instrument carries a MidiDevice value (not just an alias);
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

-- | Classify a `MidiDrumKit` value.  Encoding from purs-backend-erl:
-- |     data DrumKit = MidiDrumKit MidiDevice Int (Array DrumHit)
-- | becomes `{midiDrumKit, DeviceTuple, Ch, HitsArray}`.  We unpack
-- | device + channel + the full hits array; the Erlang shell turns
-- | each hit into a binding entry.
pickDrumKit
  :: Map (Tuple String Int) String
  -> { name :: String, value :: Foreign }
  -> Maybe RegistrationEvent
pickDrumKit deviceAliases { name: alias, value } = do
  tag <- constructorTag value
  if tag /= "midiDrumKit" then Nothing
  else do
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
