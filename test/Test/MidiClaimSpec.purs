-- | Tests for `Tidal.MidiClaim` — MIDI dup detection on
-- | (deviceAlias, channel) pairs.  Phase 1 surface; Phase 2
-- | (2026-05-17) refactored these through `Tidal.PortClaim` so the
-- | underlying machinery is now shared with future ES-9 / FH-2
-- | claim handling.  Per-bank `SwapPolicy` (BankMidi = SwapError)
-- | makes "two synths on iac ch 1" an `ExactMatchRejected` error
-- | from the unified validator.
-- |
-- | Semantics shift vs Phase 1a: the validator now folds claims
-- | through `applyClaim` against a running `ClaimTable`, so a
-- | three-way collision produces two errors (claim 2 vs the
-- | accepted claim 1, claim 3 vs the accepted claim 1) rather than
-- | one grouped error.  This matches the actual "first declaration
-- | wins, later ones flagged" semantics of the registration path.
module Test.MidiClaimSpec
  ( runMidiClaimTests
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.MidiClaim
  ( describeClaimError
  , validateMidiClaims
  )
import Tidal.PortClaim
  ( ClaimError(..)
  , OwnerId(..)
  , OwnerKind(..)
  )

runMidiClaimTests :: Effect Unit
runMidiClaimTests = do
  log ""
  log "--- Tidal.MidiClaim (Phase 2 — through PortClaim) ---"

  -- Disjoint claims: no error.
  let disjoint =
        [ { owner: "bass1", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "bass2", deviceAlias: "iac", channel: 2, ownerKind: OwnInstrument }
        ]
  expectNone "disjoint instruments" (validateMidiClaims disjoint)

  -- Same channel on different devices: no error (different BankMidi
  -- banks; no overlap).
  let differentDevices =
        [ { owner: "bass1", deviceAlias: "iac",   channel: 1, ownerKind: OwnInstrument }
        , { owner: "kick",  deviceAlias: "fh2qd", channel: 1, ownerKind: OwnInstrument }
        ]
  expectNone "same channel on different devices" (validateMidiClaims differentDevices)

  -- Two instruments on the same (device, channel): the second's
  -- ExactMatch on BankMidi (SwapError) produces an ExactMatchRejected
  -- naming the second claim as the new owner, first as the existing.
  let dupInstruments =
        [ { owner: "bass1",  deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "bass1b", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        ]
  case validateMidiClaims dupInstruments of
    [ExactMatchRejected r]
      | r.owner == OwnerId OwnInstrument "bass1b"
      , r.conflict.with == OwnerId OwnInstrument "bass1" ->
        log "  ✓ duplicate instruments on iac ch 1: bass1b rejected (bass1 wins)"
    other ->
      log $ "  ✗ duplicate instruments — unexpected: " <> show (Array.length other) <> " errors"

  -- Instrument + drum kit on the same channel: the kit's ExactMatch
  -- on BankMidi produces ExactMatchRejected naming both kinds.
  let mixedKinds =
        [ { owner: "bass1", deviceAlias: "iac", channel: 14, ownerKind: OwnInstrument }
        , { owner: "qd1",   deviceAlias: "iac", channel: 14, ownerKind: OwnDrumKit }
        ]
  case validateMidiClaims mixedKinds of
    [ExactMatchRejected r]
      | r.owner == OwnerId OwnDrumKit "qd1"
      , r.conflict.with == OwnerId OwnInstrument "bass1" ->
        log "  ✓ instrument + drum kit on iac ch 14: kit rejected against instrument"
    _ -> log "  ✗ mixed-kinds case — unexpected error shape"

  -- Three-way collision: a wins, b and c are each separately
  -- rejected against a.
  let triple =
        [ { owner: "a", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "b", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "c", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        ]
  case validateMidiClaims triple of
    errs | Array.length errs == 2 ->
      let
        ownersIfReject e = case e of
          ExactMatchRejected r ->
            let
              OwnerId _ newName = r.owner
              OwnerId _ existName = r.conflict.with
            in Just { new: newName, exist: existName }
          _ -> Nothing
        rows = Array.mapMaybe ownersIfReject errs
      in
        if rows == [ { new: "b", exist: "a" }, { new: "c", exist: "a" } ]
          then log "  ✓ three-way collision: b and c each rejected vs a"
          else log $ "  ✗ three-way collision — wrong owners: " <> show rows
    other -> log $ "  ✗ three-way collision: " <> show (Array.length other) <> " errors (expected 2)"

  -- describeClaimError renders a one-liner.  The exact format is
  -- new in Phase 2 (Phase 1a's grouped form is gone with the
  -- group-validator); we pin the new format here so any future
  -- regression is obvious.
  case validateMidiClaims dupInstruments of
    [err] ->
      let
        expected =
          "instrument `bass1b`: duplicate claim on `iac` ch 1 — already claimed by instrument `bass1`"
        actual = describeClaimError err
      in
        if actual == expected
          then log "  ✓ describeClaimError renders expected one-liner"
          else log $ "  ✗ describeClaimError:\n     got:      " <> actual
                                                 <> "\n     expected: " <> expected
    _ -> log "  ✗ describeClaimError test — no error to render"

expectNone :: String -> Array ClaimError -> Effect Unit
expectNone desc errs =
  if Array.null errs
    then log $ "  ✓ " <> desc <> ": no errors"
    else log $ "  ✗ " <> desc <> ": " <> show (Array.length errs) <> " errors (expected 0)"
