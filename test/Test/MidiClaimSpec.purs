-- | Tests for `Tidal.MidiClaim` — duplicate detection on (deviceAlias,
-- | channel) pairs.  Phase 1 of the frontend reservations work.
module Test.MidiClaimSpec
  ( runMidiClaimTests
  ) where

import Prelude

import Data.Array as Array
import Effect (Effect)
import Effect.Console (log)
import Tidal.MidiClaim
  ( ClaimError(..)
  , ClaimOwnerKind(..)
  , describeClaimError
  , validateMidiClaims
  )

runMidiClaimTests :: Effect Unit
runMidiClaimTests = do
  log ""
  log "--- Tidal.MidiClaim ---"

  -- Disjoint claims: no error.
  let disjoint =
        [ { owner: "bass1", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "bass2", deviceAlias: "iac", channel: 2, ownerKind: OwnInstrument }
        ]
  expectNone "disjoint instruments" (validateMidiClaims disjoint)

  -- Same channel on different devices: no error.
  let differentDevices =
        [ { owner: "bass1", deviceAlias: "iac",   channel: 1, ownerKind: OwnInstrument }
        , { owner: "kick",  deviceAlias: "fh2qd", channel: 1, ownerKind: OwnInstrument }
        ]
  expectNone "same channel on different devices" (validateMidiClaims differentDevices)

  -- Two instruments on the same (device, channel): one error, both
  -- listed in declaration order.
  let dupInstruments =
        [ { owner: "bass1",  deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "bass1b", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        ]
  case validateMidiClaims dupInstruments of
    [DuplicateMidiClaim r]
      | r.deviceAlias == "iac"
      , r.channel == 1
      , map _.owner r.owners == ["bass1", "bass1b"]
      , Array.all (\o -> o.ownerKind == OwnInstrument) r.owners ->
        log "  ✓ duplicate instruments on iac ch 1 reported"
    other -> log $ "  ✗ duplicate instruments — unexpected: " <> show (Array.length other) <> " errors"

  -- Instrument + drum kit on the same channel: one error, both listed
  -- with their distinct kinds.
  let mixedKinds =
        [ { owner: "bass1", deviceAlias: "iac", channel: 14, ownerKind: OwnInstrument }
        , { owner: "qd1",   deviceAlias: "iac", channel: 14, ownerKind: OwnDrumKit }
        ]
  case validateMidiClaims mixedKinds of
    [DuplicateMidiClaim r]
      | r.deviceAlias == "iac"
      , r.channel == 14
      , map _.owner r.owners == ["bass1", "qd1"]
      , map _.ownerKind r.owners == [OwnInstrument, OwnDrumKit] ->
        log "  ✓ instrument + drum kit on same channel reported"
    _ -> log "  ✗ mixed-kinds case — unexpected error shape"

  -- Three-way collision: one error listing all three owners.
  let triple =
        [ { owner: "a", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "b", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        , { owner: "c", deviceAlias: "iac", channel: 1, ownerKind: OwnInstrument }
        ]
  case validateMidiClaims triple of
    [DuplicateMidiClaim r]
      | Array.length r.owners == 3
      , map _.owner r.owners == ["a", "b", "c"] ->
        log "  ✓ three-way collision: all owners listed"
    _ -> log "  ✗ three-way collision — unexpected shape"

  -- describeClaimError renders a stable one-liner.
  let err = DuplicateMidiClaim
        { deviceAlias: "iac"
        , channel: 1
        , owners:
            [ { owner: "bass1",  ownerKind: OwnInstrument }
            , { owner: "bass1b", ownerKind: OwnInstrument }
            ]
        }
      expected =
        "duplicate MIDI claim on `iac` ch 1 — claimed by instrument `bass1`, instrument `bass1b`"
  if describeClaimError err == expected
    then log "  ✓ describeClaimError renders expected one-liner"
    else log $ "  ✗ describeClaimError: got " <> describeClaimError err

expectNone :: String -> Array ClaimError -> Effect Unit
expectNone desc errs =
  if Array.null errs
    then log $ "  ✓ " <> desc <> ": no errors"
    else log $ "  ✗ " <> desc <> ": " <> show (Array.length errs) <> " errors (expected 0)"
