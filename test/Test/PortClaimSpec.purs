-- | Tests for `Tidal.PortClaim` — the device-agnostic port-claim
-- | machinery (Phase 2 of frontend reservations, 2026-05-17).
-- |
-- | Covers:
-- |
-- |   * BankMask arithmetic — single-slot / range / union /
-- |     intersect / difference / subset / popCount.
-- |   * Capability rule — `needFitsBank`'s asymmetric satisfiability
-- |     (NeedGate on any bank OK; NeedCV on Gate-only bank fails).
-- |   * `classifyOverlap` — five distinguishable shapes.
-- |   * `applyClaim` — capability check, idempotent same-owner
-- |     update, per-bank SwapPolicy (BankMidi rejects exact-match,
-- |     ES-9 banks accept it as a clean eviction), partial-conflict
-- |     detection.
-- |   * ES-9 bank coverage — declaring two single-slot claims on the
-- |     same ES-9 panel jack produces a PartialConflict (since
-- |     single-slot exact-match on ES-9's SwapOk policy would just
-- |     evict; we test the partial case via multi-slot claims).
module Test.PortClaimSpec
  ( runPortClaimTests
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.PortClaim
  ( Bank(..)
  , Capability(..)
  , ClaimError(..)
  , ClaimMask(..)
  , OverlapShape(..)
  , OwnerId(..)
  , OwnerKind(..)
  , NeedKind(..)
  , SwapPolicy(..)
  , applyClaim
  , bankCapability
  , bankSwapPolicy
  , bankWidth
  , classifyOverlap
  , differenceMask
  , emptyMask
  , emptyTable
  , fullMaskForBank
  , intersectMask
  , isEmptyMask
  , isSubsetMask
  , maskBits
  , needFitsBank
  , popCount
  , singleSlot
  , singletonClaim
  , slotRange
  , slotsOf
  , tableClaims
  , unionMask
  )

runPortClaimTests :: Effect Unit
runPortClaimTests = do
  log ""
  log "--- Tidal.PortClaim ---"

  bankMaskTests
  capabilityTests
  overlapTests
  applyMidiTests
  applyEs9Tests

-- ---------------------------------------------------------------------------
-- BankMask arithmetic
-- ---------------------------------------------------------------------------

bankMaskTests :: Effect Unit
bankMaskTests = do
  log "  BankMask arithmetic:"

  expectEq "singleSlot 0 sets bit 0"
    (maskBits (singleSlot 0)) [0]
  expectEq "singleSlot 7 sets bit 7"
    (maskBits (singleSlot 7)) [7]
  expectEq "slotRange 0 3 = 0b1111"
    (maskBits (slotRange 0 3)) [0, 1, 2, 3]
  expectEq "slotsOf [1, 3, 5]"
    (maskBits (slotsOf [1, 3, 5])) [1, 3, 5]
  expectEq "union of singleSlot 0 + 3"
    (maskBits (singleSlot 0 `unionMask` singleSlot 3)) [0, 3]
  expectEq "intersect of slotsOf [0,1,2] and [1,2,3]"
    (maskBits (slotsOf [0,1,2] `intersectMask` slotsOf [1,2,3])) [1, 2]
  expectEq "difference of slotsOf [0,1,2,3] minus [1,2]"
    (maskBits (slotsOf [0,1,2,3] `differenceMask` slotsOf [1,2])) [0, 3]
  expectBool "emptyMask is empty" (isEmptyMask emptyMask) true
  expectBool "singleSlot 0 is non-empty" (isEmptyMask (singleSlot 0)) false
  expectBool "subset: [0,1] ⊂ [0,1,2]"
    (isSubsetMask (slotsOf [0,1]) (slotsOf [0,1,2])) true
  expectBool "subset: [0,1] ⊄ [1,2]"
    (isSubsetMask (slotsOf [0,1]) (slotsOf [1,2])) false
  expectEq "popCount [0, 3, 5, 7]" (popCount (slotsOf [0,3,5,7])) 4
  expectEq "fullMaskForBank BankEs9Panel"
    (maskBits (fullMaskForBank BankEs9Panel))
    [0, 1, 2, 3, 4, 5, 6, 7]
  expectEq "fullMaskForBank (BankMidi \"iac\")"
    (maskBits (fullMaskForBank (BankMidi "iac")))
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

  expectEq "bankWidth MIDI = 16" (bankWidth (BankMidi "iac")) 16
  expectEq "bankWidth ES-9 panel = 8" (bankWidth BankEs9Panel) 8
  expectEq "bankWidth ES-9 cv 0 = 8" (bankWidth (BankEs9Cv 0)) 8

-- ---------------------------------------------------------------------------
-- Capability
-- ---------------------------------------------------------------------------

capabilityTests :: Effect Unit
capabilityTests = do
  log "  Capability:"
  expectEq "bankCapability BankMidi = GateOrCV"
    (bankCapability (BankMidi "iac")) GateOrCV
  expectEq "bankCapability BankEs9Panel = GateOrCV"
    (bankCapability BankEs9Panel) GateOrCV
  expectEq "bankCapability BankEs9Cv = CV"
    (bankCapability (BankEs9Cv 0)) CV
  expectEq "bankCapability BankEs9Gt = Gate"
    (bankCapability (BankEs9Gt 0)) Gate
  expectEq "bankCapability BankEs9Es5 = Gate"
    (bankCapability (BankEs9Es5 0)) Gate

  expectBool "NeedGate fits Gate" (needFitsBank NeedGate Gate) true
  expectBool "NeedGate fits CV" (needFitsBank NeedGate CV) true
  expectBool "NeedGate fits GateOrCV" (needFitsBank NeedGate GateOrCV) true
  expectBool "NeedCV does NOT fit Gate" (needFitsBank NeedCV Gate) false
  expectBool "NeedCV fits CV" (needFitsBank NeedCV CV) true
  expectBool "NeedCV fits GateOrCV" (needFitsBank NeedCV GateOrCV) true

  expectEq "BankMidi swap policy = SwapError"
    (bankSwapPolicy (BankMidi "iac")) SwapError
  expectEq "BankEs9Panel swap policy = SwapOk"
    (bankSwapPolicy BankEs9Panel) SwapOk
  expectEq "BankEs9Gt swap policy = SwapOk"
    (bankSwapPolicy (BankEs9Gt 0)) SwapOk

-- ---------------------------------------------------------------------------
-- classifyOverlap
-- ---------------------------------------------------------------------------

overlapTests :: Effect Unit
overlapTests = do
  log "  classifyOverlap:"
  let cm bits = singletonClaim BankEs9Panel (slotsOf bits)

  expectEq "disjoint" (classifyOverlap (cm [0,1]) (cm [2,3])) Disjoint
  expectEq "exact-match"
    (classifyOverlap (cm [0,1,2]) (cm [0,1,2])) ExactMatch
  expectEq "new ⊂ old"
    (classifyOverlap (cm [0,1,2,3]) (cm [1,2])) NewSubsetsOld
  expectEq "old ⊂ new"
    (classifyOverlap (cm [1,2]) (cm [0,1,2,3])) OldSubsetsNew
  expectEq "partial overlap"
    (classifyOverlap (cm [0,1,2]) (cm [1,2,3])) PartialOverlap

  -- Cross-bank disjoint — two different banks are always disjoint.
  let panelClaim = singletonClaim BankEs9Panel (singleSlot 0)
      cvClaim = singletonClaim (BankEs9Cv 0) (singleSlot 0)
  expectEq "different banks are disjoint"
    (classifyOverlap panelClaim cvClaim) Disjoint

-- ---------------------------------------------------------------------------
-- applyClaim — MIDI (SwapError policy)
-- ---------------------------------------------------------------------------

applyMidiTests :: Effect Unit
applyMidiTests = do
  log "  applyClaim — MIDI (SwapError policy):"

  -- Two different aliases, different channels → both applied.
  let
    bass1 = midiClaim "bass1" OwnInstrument "iac" 1
    bass2 = midiClaim "bass2" OwnInstrument "iac" 2
  case applyClaim bass1 emptyTable >>= applyClaim bass2 of
    Right table ->
      expectEq "two MIDI claims, disjoint channels: both installed"
        (Array.length (tableClaims table)) 2
    Left err -> log $ "    ✗ disjoint MIDI claims failed: " <> show err

  -- Two different aliases, same channel → second produces ExactMatchRejected.
  let bass1b = midiClaim "bass1b" OwnInstrument "iac" 1
  case applyClaim bass1 emptyTable >>= applyClaim bass1b of
    Left (ExactMatchRejected r)
      | r.owner == OwnerId OwnInstrument "bass1b"
      , r.conflict.with == OwnerId OwnInstrument "bass1" ->
        log "    ✓ duplicate MIDI claim rejected (SwapError) with named conflict"
    other -> log $ "    ✗ duplicate MIDI claim: unexpected " <> show other

  -- Same alias re-fires (same OwnerId, same channel) → idempotent
  -- replace, no error.
  case applyClaim bass1 emptyTable >>= applyClaim bass1 of
    Right table | Array.length (tableClaims table) == 1 ->
      log "    ✓ same-owner update is idempotent"
    other -> log $ "    ✗ idempotent same-owner: " <> show (eitherToShape other)

  -- Same alias, different channel → moves the claim (old slot released).
  let bass1ch3 =
        { owner: OwnerId OwnInstrument "bass1"
        , mask: singletonClaim (BankMidi "iac") (singleSlot 2)
        , slots: Map.singleton (BankMidi "iac") [{ slot: 2, need: NeedGate }]
        }
  case applyClaim bass1 emptyTable >>= applyClaim bass1ch3 of
    Right table ->
      let
        claims = tableClaims table
        soleClaim = Array.head claims
      in case soleClaim of
        Just c | c.mask == singletonClaim (BankMidi "iac") (singleSlot 2)
              , Array.length claims == 1 ->
          log "    ✓ same-owner re-channel: previous claim released, new installed"
        _ -> log $ "    ✗ same-owner re-channel: wrong table state"
    Left err -> log $ "    ✗ same-owner re-channel failed: " <> show err

-- ---------------------------------------------------------------------------
-- applyClaim — ES-9 (SwapOk policy + partial conflicts + capability)
-- ---------------------------------------------------------------------------

applyEs9Tests :: Effect Unit
applyEs9Tests = do
  log "  applyClaim — ES-9 (SwapOk policy):"

  let
    octoLfo =
      es9Claim OwnSelene "myLfo" BankEs9Panel [0,1,2,3,4,5,6,7] NeedCV
    polyClk =
      es9Claim OwnSelene "myClk" BankEs9Panel [0,1,2,3,4,5,6,7] NeedGate

  -- Exact-match across owners on ES-9: SwapOk evicts the previous claim.
  case applyClaim octoLfo emptyTable >>= applyClaim polyClk of
    Right table ->
      let
        owners = map _.owner (tableClaims table)
      in
        if owners == [OwnerId OwnSelene "myClk"]
          then log "    ✓ ES-9 exact-match across owners: previous evicted (SwapOk)"
          else log $ "    ✗ ES-9 exact-match: wrong owners after swap: " <> show owners
    Left err -> log $ "    ✗ ES-9 exact-match unexpectedly failed: " <> show err

  -- Partial overlap on ES-9 panel: error regardless of swap policy.
  let
    halfA =
      es9Claim OwnSelene "myLfo" BankEs9Panel [0,1,2,3] NeedCV
    crossB =
      es9Claim OwnSelene "myKit" BankEs9Panel [2,3,4,5] NeedGate
  case applyClaim halfA emptyTable >>= applyClaim crossB of
    Left (PartialConflict r)
      | r.owner == OwnerId OwnSelene "myKit"
      , Array.length r.conflicts == 1 ->
        log "    ✓ partial overlap on ES-9 panel: PartialConflict raised"
    other -> log $ "    ✗ partial overlap: unexpected " <> show (eitherToShape other)

  -- Capability error: NeedCV on a gate-only bank.
  let
    cvOnGt =
      es9Claim OwnSelene "myEnv" (BankEs9Gt 0) [0,1,2,3] NeedCV
  case applyClaim cvOnGt emptyTable of
    Left (CapabilityError r) ->
      let slotsBad = map _.slot r.conflicts
      in if slotsBad == [0,1,2,3]
           then log "    ✓ NeedCV on Gate-only bank: CapabilityError lists offending slots"
           else log $ "    ✗ NeedCV on Gate-only: wrong slots " <> show slotsBad
    other -> log $ "    ✗ NeedCV on Gate-only: unexpected " <> show (eitherToShape other)

  -- Capability OK: NeedGate on a CV-only bank passes (CV jack as 0/+5V gate).
  let
    gateOnCv =
      es9Claim OwnTvoice "kick" (BankEs9Cv 0) [3] NeedGate
  case applyClaim gateOnCv emptyTable of
    Right table | Array.length (tableClaims table) == 1 ->
      log "    ✓ NeedGate on CV-only bank: accepted (CV-as-gate)"
    other -> log $ "    ✗ NeedGate on CV-only: unexpected " <> show (eitherToShape other)

  -- Two single-slot ES-9 claims on the same panel jack: with SwapOk,
  -- the second EVICTS the first.  (This is the "the user knows what
  -- they're doing for like-for-like swaps" semantics from
  -- port-claims-design.md.)
  let
    kickA = es9Claim OwnTvoice "kickA" BankEs9Panel [3] NeedGate
    kickB = es9Claim OwnTvoice "kickB" BankEs9Panel [3] NeedGate
  case applyClaim kickA emptyTable >>= applyClaim kickB of
    Right table
      | map _.owner (tableClaims table) == [OwnerId OwnTvoice "kickB"] ->
        log "    ✓ ES-9 single-slot exact-match across owners: B evicts A"
    other -> log $ "    ✗ ES-9 single-slot swap: " <> show (eitherToShape other)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Build a MIDI single-slot claim from the user-facing shape.
midiClaim
  :: String
  -> OwnerKind
  -> String
  -> Int
  -> { owner :: OwnerId
     , mask :: ClaimMask
     , slots :: Map.Map Bank (Array { slot :: Int, need :: NeedKind })
     }
midiClaim name kind alias channel =
  let
    bank = BankMidi alias
    slot = channel - 1
  in
    { owner: OwnerId kind name
    , mask: singletonClaim bank (singleSlot slot)
    , slots: Map.singleton bank [{ slot, need: NeedGate }]
    }

-- | Build a multi-slot ES-9 claim with a uniform NeedKind across all slots.
es9Claim
  :: OwnerKind
  -> String
  -> Bank
  -> Array Int
  -> NeedKind
  -> { owner :: OwnerId
     , mask :: ClaimMask
     , slots :: Map.Map Bank (Array { slot :: Int, need :: NeedKind })
     }
es9Claim kind name bank slotIs need =
  { owner: OwnerId kind name
  , mask: singletonClaim bank (slotsOf slotIs)
  , slots: Map.singleton bank (map (\s -> { slot: s, need }) slotIs)
  }

-- | Compact error label for unexpected outcomes.
eitherToShape :: forall a b. Show a => Show b => Either a b -> String
eitherToShape = case _ of
  Left e -> "Left " <> show e
  Right v -> "Right " <> show v

expectEq :: forall a. Eq a => Show a => String -> a -> a -> Effect Unit
expectEq desc actual expected =
  if actual == expected
    then log $ "    ✓ " <> desc
    else log $ "    ✗ " <> desc <> "\n       got:      " <> show actual
                                  <> "\n       expected: " <> show expected

expectBool :: String -> Boolean -> Boolean -> Effect Unit
expectBool desc actual expected =
  if actual == expected
    then log $ "    ✓ " <> desc
    else log $ "    ✗ " <> desc <> " (got " <> show actual
                                  <> ", expected " <> show expected <> ")"
