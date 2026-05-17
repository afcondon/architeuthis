-- | Front-end resource reservations — MIDI channel layer.
-- |
-- | Each Studio.purs MIDI declaration is *implicitly a claim* on a
-- | (deviceAlias, channel) pair.  Two declarations on the same pair
-- | is a configuration error: both bindings hit the dispatcher,
-- | both emit to the same MIDI channel, and the destination synth
-- | merges their note streams silently.  The user hears chaos and
-- | has nothing in the log to grep.
-- |
-- | This module collects those implicit claims from the walker's
-- | registration events and runs duplicate detection.
-- |
-- | Phase 1 scope.  The design plan
-- | (`docs/frontend-reservations-plan.md`) calls for the full
-- | bitmask + capability + overlap-shape machinery from
-- | `port-claims-design.md` (used by fh2-config for FH-2 banks);
-- | for MIDI claims each declaration is single-slot and capability-
-- | trivial, so a flat group-and-count over `(device, channel)` is
-- | enough.  Phase 2 (ES-9 banks) is when the bigger machinery gets
-- | ported in; MIDI claims will thread through it then.
module Tidal.MidiClaim
  ( ClaimOwnerKind(..)
  , MidiClaim
  , ClaimError(..)
  , validateMidiClaims
  , describeClaimError
  , claimOwnerKindLabel
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String.Common (joinWith)
import Data.Tuple (Tuple(..))

-- | What kind of Studio declaration produced a claim.  Carried in
-- | error messages so a name collision between an Instrument and a
-- | DrumKit on the same channel reads correctly ("instrument `x` vs
-- | drum kit `y`" rather than "x vs y").
data ClaimOwnerKind = OwnInstrument | OwnDrumKit

derive instance eqClaimOwnerKind :: Eq ClaimOwnerKind

claimOwnerKindLabel :: ClaimOwnerKind -> String
claimOwnerKindLabel OwnInstrument = "instrument"
claimOwnerKindLabel OwnDrumKit    = "drum kit"

-- | One implicit MIDI claim — the (device, channel) pair a Studio
-- | declaration is reserving, plus the alias that did the reserving.
type MidiClaim =
  { owner :: String
  , deviceAlias :: String
  , channel :: Int
  , ownerKind :: ClaimOwnerKind
  }

-- | Conflict between two or more claims on the same channel.
data ClaimError = DuplicateMidiClaim
  { deviceAlias :: String
  , channel :: Int
  , owners :: Array { owner :: String, ownerKind :: ClaimOwnerKind }
  }

-- | Group claims by (deviceAlias, channel); any group of size ≥ 2 is
-- | a duplicate.  Within-group order mirrors declaration order so the
-- | log line reads in the same direction the user wrote Studio.purs.
validateMidiClaims :: Array MidiClaim -> Array ClaimError
validateMidiClaims claims =
  let
    grouped :: Map (Tuple String Int) (Array { owner :: String, ownerKind :: ClaimOwnerKind })
    grouped = Array.foldl insertClaim Map.empty claims

    insertClaim acc c =
      Map.alter
        (\existing ->
            Just (Array.snoc (fromMaybe [] existing)
                             { owner: c.owner, ownerKind: c.ownerKind }))
        (Tuple c.deviceAlias c.channel)
        acc

    pairs :: Array (Tuple (Tuple String Int) (Array { owner :: String, ownerKind :: ClaimOwnerKind }))
    pairs = Map.toUnfoldable grouped

    toError (Tuple (Tuple dev ch) owners)
      | Array.length owners >= 2 =
          Just $ DuplicateMidiClaim
            { deviceAlias: dev, channel: ch, owners }
      | otherwise = Nothing
  in
    Array.mapMaybe toError pairs

-- | One-line human-readable rendering for the BEAM log + structured
-- | error events crossing into Erlang.  Rendering happens in
-- | PureScript so the boundary primitive stays a flat String.
describeClaimError :: ClaimError -> String
describeClaimError (DuplicateMidiClaim r) =
  "duplicate MIDI claim on `"
    <> r.deviceAlias
    <> "` ch "
    <> show r.channel
    <> " — claimed by "
    <> joinWith ", " (map prettyOwner r.owners)
  where
  prettyOwner o =
    claimOwnerKindLabel o.ownerKind <> " `" <> o.owner <> "`"
