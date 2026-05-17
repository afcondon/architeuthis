-- | MIDI-channel layer of the frontend reservation system.
-- |
-- | Phase 2 (2026-05-17): refactored to share types with
-- | `Tidal.PortClaim`.  MidiClaim is now the MIDI-specific *adapter*
-- | between SessionWalker registration events and the unified
-- | port-claim machinery — the flat `MidiClaim` record carries what
-- | a Studio.purs `Instrument` / `DrumKit` implicitly reserves; the
-- | validator builds `PortClaim.Claim` values, drives
-- | `PortClaim.applyClaim` against a running `ClaimTable`, and
-- | surfaces the resulting `ClaimError` values.
-- |
-- | The per-bank `SwapPolicy` machinery means MIDI dup detection
-- | falls out for free: each MIDI declaration's claim is a single-
-- | slot `BankMask` on a `BankMidi <alias>` bank whose policy is
-- | `SwapError`, so two different aliases on the same channel
-- | produce an `ExactMatchRejected` error.
-- |
-- | What the boundary looks like to the rest of the rig:
-- |
-- |   * `Tidal.SessionWalker` builds `Array MidiClaim` from
-- |     `RegisterMidiInstrument` + `RegisterMidiDrumKit` events.
-- |   * `validateMidiClaims` returns `Array PortClaim.ClaimError`.
-- |   * `claimErrorToBoundary` flattens each error into the wire
-- |     shape the Erlang shell logs (preserves the existing
-- |     `ReportClaimError` event fields — no protocol break).
-- |
-- | Companion: `Tidal.PortClaim` for the device-agnostic machinery.
module Tidal.MidiClaim
  ( MidiClaim
  , toClaim
  , validateMidiClaims
  , claimErrorToBoundary
  -- Re-exports so SessionWalker and tests can use one import.
  , module PortClaim
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

import Tidal.PortClaim
  ( Bank(..)
  , Claim
  , ClaimError(..)
  , ClaimMask(..)
  , ClaimTable
  , NeedKind(..)
  , OwnerId(..)
  , OwnerKind
  , applyClaim
  , describeClaimError
  , describeOwnerKind
  , emptyTable
  , maskBits
  , singleSlot
  , singletonClaim
  ) as PortClaim
import Tidal.PortClaim
  ( Bank(..)
  , Claim
  , ClaimError(..)
  , ClaimMask(..)
  , ClaimTable
  , NeedKind(..)
  , OwnerId(..)
  , OwnerKind
  , applyClaim
  , describeClaimError
  , describeOwnerKind
  , emptyTable
  , maskBits
  , singleSlot
  , singletonClaim
  )

-- ---------------------------------------------------------------------------
-- The flat MIDI claim — SessionWalker's intermediate form.
-- ---------------------------------------------------------------------------

-- | A Studio.purs declaration's implicit MIDI claim.  Carries just
-- | the device alias + channel + owner identity; the `ownerKind`
-- | distinguishes Instrument (`midi iac 1`) from DrumKit
-- | (`midiDrumKit fh2qd 14 […]`).
type MidiClaim =
  { owner :: String
  , deviceAlias :: String
  , channel :: Int        -- 1-16, user-facing
  , ownerKind :: OwnerKind
  }

-- | Convert a flat MidiClaim into a `PortClaim.Claim`.  The
-- | (alias, channel) pair becomes `BankMidi alias` + `singleSlot
-- | (channel - 1)`; the implicit need is `NeedGate` (MIDI is
-- | symbolic — capability check is trivially satisfied since
-- | `BankMidi` reports `GateOrCV`).
toClaim :: MidiClaim -> Claim
toClaim mc =
  let
    bank = BankMidi mc.deviceAlias
    slotIdx = mc.channel - 1
    mask = singletonClaim bank (singleSlot slotIdx)
    slots = Map.singleton bank [{ slot: slotIdx, need: NeedGate }]
  in
    { owner: OwnerId mc.ownerKind mc.owner
    , mask
    , slots
    }

-- | Validate every MIDI claim by folding it through `applyClaim`.
-- | Errors from each step accumulate in declaration order; a
-- | rejected claim is *not* added to the table (so a third
-- | duplicate doesn't conflict against a duplicate that was already
-- | rejected).  Warn-only at the SessionWalker level — the binding
-- | is still installed in the dispatcher, the user just sees the
-- | conflict in the log.
validateMidiClaims :: Array MidiClaim -> Array ClaimError
validateMidiClaims = go [] emptyTable
  where
  go :: Array ClaimError -> ClaimTable -> Array MidiClaim -> Array ClaimError
  go errs table claims = case Array.uncons claims of
    Nothing -> errs
    Just { head, tail } ->
      case applyClaim (toClaim head) table of
        Left err -> go (Array.snoc errs err) table tail
        Right table' -> go errs table' tail

-- ---------------------------------------------------------------------------
-- Boundary translation — flatten ClaimError to SessionWalker's wire shape.
-- ---------------------------------------------------------------------------

-- | The flat shape carried across the PureScript ↔ Erlang boundary
-- | by `ReportClaimError` registration events.  Preserved verbatim
-- | from Phase 1a so the Erlang log line + Calypso Studio pane
-- | parser keep working.
-- |
-- | Returns `Nothing` for any ClaimError that doesn't have a clean
-- | (device, channel) breakdown — e.g. an error that spans multiple
-- | banks at once (not produced by today's MIDI-only path; future-
-- | proof against the same machinery being used for richer claims).
claimErrorToBoundary
  :: ClaimError
  -> Maybe
       { errorKind :: String
       , deviceAlias :: String
       , channel :: Int
       , owners :: Array { name :: String, kind :: String }
       , message :: String
       }
claimErrorToBoundary err = case err of
  ExactMatchRejected r -> case midiBankAndChannel r.conflict.slots of
    Just { deviceAlias, channel } ->
      let
        OwnerId newKind newName = r.owner
        OwnerId existKind existName = r.conflict.with
        owners =
          [ { name: newName, kind: describeOwnerKind newKind }
          , { name: existName, kind: describeOwnerKind existKind }
          ]
      in
        Just
          { errorKind: "duplicate-midi-channel"
          , deviceAlias
          , channel
          , owners
          , message: describeClaimError err
          }
    Nothing -> Nothing

  PartialConflict r -> case Array.uncons r.conflicts of
    Just { head, tail: _ } -> case midiBankAndChannel head.slots of
      Just { deviceAlias, channel } ->
        let
          OwnerId newKind newName = r.owner
          OwnerId existKind existName = head.with
          owners =
            [ { name: newName, kind: describeOwnerKind newKind }
            , { name: existName, kind: describeOwnerKind existKind }
            ]
        in
          Just
            { errorKind: "partial-midi-overlap"
            , deviceAlias
            , channel
            , owners
            , message: describeClaimError err
            }
      Nothing -> Nothing
    Nothing -> Nothing

  CapabilityError _ ->
    -- Not produced by the MIDI path today (BankMidi is GateOrCV).
    -- If a future caller threads MIDI through with an unsatisfiable
    -- NeedKind, surface a generic capability-error event upstream.
    Nothing

-- | Pull the (deviceAlias, channel) pair out of a single-bank
-- | single-slot MIDI claim mask.  Returns Nothing for masks that
-- | aren't shaped like a MIDI single-slot claim.
midiBankAndChannel
  :: ClaimMask
  -> Maybe { deviceAlias :: String, channel :: Int }
midiBankAndChannel (ClaimMask m) = case Map.toUnfoldable m :: Array _ of
  [Tuple (BankMidi alias) mask] -> case maskBits mask of
    [slotIdx] -> Just { deviceAlias: alias, channel: slotIdx + 1 }
    _ -> Nothing
  _ -> Nothing
