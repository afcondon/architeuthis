-- | Tidal.PortClaim — unified port-claim machinery (Phase 2 of
-- | `docs/frontend-reservations-plan.md`).
-- |
-- | Device-agnostic core: every part of this module except the `Bank`
-- | constructors and their `bankCapability` / `bankWidth` /
-- | `bankSwapPolicy` data works for any device whose outputs partition
-- | into capability-typed banks.  Companion backend doc:
-- | `fh2-config/docs/port-claims-design.md` — same model, ported to
-- | purerl-tidal so MIDI claims and (eventually) ES-9 / FH-2 claims
-- | share one shape.
-- |
-- | Two-axis classification of a slot:
-- |
-- |   * **Capability** — what the underlying hardware can *emit*
-- |     (Gate / CV / GateOrCV).  Banks declare this once.
-- |   * **NeedKind** — what an owner *wants* the slot to do
-- |     (NeedGate / NeedCV).  The asymmetric rule `needFitsBank`
-- |     captures the fact that a CV-capable jack can be driven as a
-- |     gate (0/+5V via output-range clamp) but a gate-only jack
-- |     physically cannot do continuous CV.
-- |
-- | Claims are partial: a single owner may claim an arbitrary slot
-- | set across one or more banks (per-bank 32-bit `BankMask`).  The
-- | claim table validates each new claim against the table via
-- | `applyClaim`, producing precise error messages for the four
-- | distinguishable conflict shapes.
-- |
-- | Per-bank `SwapPolicy` controls what "exact-match across owners"
-- | means.  For MIDI banks the policy is `SwapError` (two synths on
-- | iac ch 1 is chaos, not a swap).  For ES-9 / FH-2 banks the policy
-- | is `SwapOk` (polylfo replacing polyenv on the main panel is the
-- | natural live-coding gesture).  Same machinery; per-bank
-- | semantics.
module Tidal.PortClaim
  ( -- Capability layer
    Capability(..)
  , NeedKind(..)
  , needFitsBank
  , describeCapability
  , describeNeed
    -- Bank ADT and metadata
  , Bank(..)
  , bankCapability
  , bankWidth
  , bankSwapPolicy
  , describeBank
    -- Swap policy
  , SwapPolicy(..)
    -- BankMask
  , BankMask(..)
  , emptyMask
  , fullMaskForBank
  , singleSlot
  , slotRange
  , slotsOf
  , maskBits
  , unionMask
  , intersectMask
  , differenceMask
  , isEmptyMask
  , isSubsetMask
  , popCount
    -- ClaimMask
  , ClaimMask(..)
  , mkClaimMask
  , singletonClaim
  , emptyClaimMask
  , unionClaim
  , intersectClaim
  , isEmptyClaim
  , isSubsetClaim
    -- Owner identity
  , OwnerKind(..)
  , OwnerId(..)
  , describeOwnerKind
  , prettyOwner
    -- Claim
  , Claim
    -- Overlap classification
  , OverlapShape(..)
  , classifyOverlap
    -- Claim table + apply
  , ClaimTable(..)
  , emptyTable
  , tableClaims
  , ClaimError(..)
  , describeClaimError
  , applyClaim
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Int.Bits (shl, (.&.), (.|.), complement) as Bits
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (class Newtype)
import Data.String.Common (joinWith)
import Data.Tuple (Tuple(..), fst, snd)

-- ---------------------------------------------------------------------------
-- Capability layer
-- ---------------------------------------------------------------------------

-- | What kind of signal a jack can emit physically.  Read on its
-- | own: `Gate` is gate-only hardware (FHX-8GT-style; can never go
-- | to continuous voltage); `CV` is CV-only hardware (FHX-8CV;
-- | continuous voltage, clamps to 0/+5V for gate use); `GateOrCV`
-- | is panel hardware that does both natively.
data Capability = Gate | CV | GateOrCV

derive instance eqCapability :: Eq Capability
derive instance ordCapability :: Ord Capability

instance showCapability :: Show Capability where
  show = describeCapability

-- | English noun for `Capability` — used in error messages.
describeCapability :: Capability -> String
describeCapability = case _ of
  Gate     -> "gate"
  CV       -> "CV"
  GateOrCV -> "gate-or-CV"

-- | What an owner wants a slot to do.  Recorded per-slot in the
-- | owner's `Claim` so the capability check can pinpoint which
-- | slots fail (rather than just "this claim is wrong-shaped").
data NeedKind = NeedGate | NeedCV

derive instance eqNeedKind :: Eq NeedKind
derive instance ordNeedKind :: Ord NeedKind

instance showNeedKind :: Show NeedKind where
  show = describeNeed

-- | English noun for `NeedKind`.
describeNeed :: NeedKind -> String
describeNeed = case _ of
  NeedGate -> "gate"
  NeedCV   -> "CV"

-- | The asymmetric satisfiability rule.  CV-capable jacks can be
-- | driven as gates (clamp to 0/+5V via per-jack output range), but
-- | gate-only jacks cannot do continuous voltage.
needFitsBank :: NeedKind -> Capability -> Boolean
needFitsBank NeedGate Gate     = true
needFitsBank NeedGate CV       = true
needFitsBank NeedGate GateOrCV = true
needFitsBank NeedCV   Gate     = false
needFitsBank NeedCV   CV       = true
needFitsBank NeedCV   GateOrCV = true

-- ---------------------------------------------------------------------------
-- Swap policy
-- ---------------------------------------------------------------------------

-- | What happens when a new claim exact-matches an existing claim's
-- | mask under a different owner.
-- |
-- |   * `SwapOk` — eviction.  The new owner takes over, the old
-- |     owner's claim is removed atomically.  Right for ES-9 / FH-2
-- |     polysignal-style banks where the user explicitly re-fires
-- |     a different family on the same physical bank.
-- |   * `SwapError` — reject the new claim.  Right for MIDI channels
-- |     where two simultaneous owners on the same channel produces
-- |     silent chaos (both bindings send notes to the destination
-- |     synth on the same channel, indistinguishable from a bug).
data SwapPolicy = SwapOk | SwapError

derive instance eqSwapPolicy :: Eq SwapPolicy
derive instance ordSwapPolicy :: Ord SwapPolicy

instance showSwapPolicy :: Show SwapPolicy where
  show SwapOk = "SwapOk"
  show SwapError = "SwapError"

-- ---------------------------------------------------------------------------
-- Bank ADT
-- ---------------------------------------------------------------------------

-- | A bank — a contiguous addressable slice of a device's outputs.
-- | The two device families this phase tracks:
-- |
-- |   * `BankMidi <device-alias>` — one MIDI device, 16 channels.
-- |     Each Studio.purs `MidiDevice` declaration backs one
-- |     `BankMidi`; instruments and drum kits claim single slots
-- |     (one channel each).
-- |   * `BankEs9*` — the ES-9 module's output banks, mirroring the
-- |     port-claims-design `Es9Bank` namespace.  8 slots each.
-- |
-- | Adding a new device family is one constructor + one clause each
-- | in `bankCapability`, `bankWidth`, `bankSwapPolicy`,
-- | `describeBank`.  Everything else (`BankMask`, `ClaimMask`,
-- | `OverlapShape`, `applyClaim`) is device-agnostic.
data Bank
  = BankMidi String
  | BankEs9Panel
  | BankEs9Cv Int
  | BankEs9Gt Int
  | BankEs9Es5 Int

derive instance eqBank :: Eq Bank
derive instance ordBank :: Ord Bank

instance showBank :: Show Bank where
  show = describeBank

-- | Compact rendering for error messages.  Reads like the cell
-- | verbs / Studio declarations the user wrote: `BankMidi "iac"`
-- | renders as `iac`; ES-9 banks as `es9 panel`, `es9 cv 0`, etc.
describeBank :: Bank -> String
describeBank = case _ of
  BankMidi alias -> alias
  BankEs9Panel   -> "es9 panel"
  BankEs9Cv n    -> "es9 cv " <> show n
  BankEs9Gt n    -> "es9 gt " <> show n
  BankEs9Es5 n   -> "es9 es5 " <> show n

-- | The bank's hardware capability profile.  ES-9 panel jacks are
-- | the canonical GateOrCV case (configurable per-jack); CV banks
-- | (FHX-8CV cousins) are CV; GT and ES-5 banks are gate-only.
bankCapability :: Bank -> Capability
bankCapability = case _ of
  BankMidi _   -> GateOrCV   -- MIDI is symbolic; capability check is trivial
  BankEs9Panel -> GateOrCV
  BankEs9Cv _  -> CV
  BankEs9Gt _  -> Gate
  BankEs9Es5 _ -> Gate

-- | The number of slots in a bank.  MIDI is 16 (channels 1-16,
-- | encoded as slots 0-15 in the mask).  ES-9 banks are 8 each.
bankWidth :: Bank -> Int
bankWidth = case _ of
  BankMidi _   -> 16
  BankEs9Panel -> 8
  BankEs9Cv _  -> 8
  BankEs9Gt _  -> 8
  BankEs9Es5 _ -> 8

-- | The per-bank exact-match-cross-owner policy.  See `SwapPolicy`
-- | for the rationale.
bankSwapPolicy :: Bank -> SwapPolicy
bankSwapPolicy = case _ of
  BankMidi _   -> SwapError
  BankEs9Panel -> SwapOk
  BankEs9Cv _  -> SwapOk
  BankEs9Gt _  -> SwapOk
  BankEs9Es5 _ -> SwapOk

-- ---------------------------------------------------------------------------
-- BankMask — slot-set within one bank
-- ---------------------------------------------------------------------------

-- | A slot-set as a bitmask.  Bit *i* set ⇔ slot *i* claimed.
-- | Stored as `Int` (32-bit signed on most platforms; well over the
-- | 16-bit-MIDI / 8-bit-ES-9 widths we use).  Wrapped in a newtype
-- | so the type-level intent stays visible at call sites.
newtype BankMask = BankMask Int

derive instance eqBankMask :: Eq BankMask
derive instance ordBankMask :: Ord BankMask
derive instance newtypeBankMask :: Newtype BankMask _

instance showBankMask :: Show BankMask where
  show m = "BankMask " <> show (Array.fromFoldable (maskBits m))

-- | The empty mask — no slots claimed.
emptyMask :: BankMask
emptyMask = BankMask 0

-- | The mask covering every slot in a given bank.  E.g. for a MIDI
-- | bank that's bits 0-15 (channels 1-16); for an ES-9 panel bank
-- | that's bits 0-7.
fullMaskForBank :: Bank -> BankMask
fullMaskForBank bank =
  let w = bankWidth bank
  in BankMask ((1 `Bits.shl` w) - 1)

-- | A single-slot mask — bit *i* set, all others clear.  Caller is
-- | responsible for slot validity (`0 ≤ i < bankWidth bank`); an
-- | out-of-range slot still produces a valid mask but it won't
-- | line up with anything else.
singleSlot :: Int -> BankMask
singleSlot i = BankMask (1 `Bits.shl` i)

-- | A contiguous slot range, inclusive.  `slotRange 0 7` is `0xFF`.
-- | Empty range (`lo > hi`) gives `emptyMask`.
slotRange :: Int -> Int -> BankMask
slotRange lo hi
  | lo > hi = emptyMask
  | otherwise =
      let count = hi - lo + 1
          base = (1 `Bits.shl` count) - 1
      in BankMask (base `Bits.shl` lo)

-- | The union of the listed slots.  `slotsOf [0, 3, 7]` is
-- | `0b10001001`.
slotsOf :: Array Int -> BankMask
slotsOf = foldl (\m i -> m `unionMask` singleSlot i) emptyMask

-- | The list of slots set in the mask, in ascending order.  Useful
-- | for rendering claim error messages slot-by-slot.
maskBits :: BankMask -> Array Int
maskBits (BankMask n) = Array.filter (\i -> (n `Bits.shl` (-i)) Bits..&. 1 /= 0)
                                      (Array.range 0 31)

-- | Union — slots claimed by either mask.
unionMask :: BankMask -> BankMask -> BankMask
unionMask (BankMask a) (BankMask b) = BankMask (a Bits..|. b)

-- | Intersection — slots claimed by both masks.
intersectMask :: BankMask -> BankMask -> BankMask
intersectMask (BankMask a) (BankMask b) = BankMask (a Bits..&. b)

-- | Set difference — slots in the first but not the second.
differenceMask :: BankMask -> BankMask -> BankMask
differenceMask (BankMask a) (BankMask b) =
  BankMask (a Bits..&. Bits.complement b)

isEmptyMask :: BankMask -> Boolean
isEmptyMask (BankMask n) = n == 0

-- | Subset check — every bit in `a` is also in `b`.
isSubsetMask :: BankMask -> BankMask -> Boolean
isSubsetMask a b = isEmptyMask (a `differenceMask` b)

-- | The number of slots set in the mask.  Naïve count over the
-- | 32-bit width — fine for masks this size.
popCount :: BankMask -> Int
popCount m = Array.length (maskBits m)

-- ---------------------------------------------------------------------------
-- ClaimMask — slot-sets across multiple banks
-- ---------------------------------------------------------------------------

-- | A claim's slot footprint across the rig.  Banks not in the map
-- | are implicitly unclaimed; banks-with-empty-mask are normalised
-- | out by `mkClaimMask`.  This canonical form keeps `Eq` and
-- | emptiness checks unambiguous.
newtype ClaimMask = ClaimMask (Map Bank BankMask)

derive instance eqClaimMask :: Eq ClaimMask
derive instance ordClaimMask :: Ord ClaimMask
derive instance newtypeClaimMask :: Newtype ClaimMask _

instance showClaimMask :: Show ClaimMask where
  show (ClaimMask m) =
    "ClaimMask {"
      <> joinWith ", "
           (map (\(Tuple b mask) -> describeBank b <> ": " <> show mask)
                (Map.toUnfoldable m :: Array _))
      <> "}"

-- | Smart constructor — drops banks whose mask is empty so the
-- | resulting `ClaimMask` has one canonical representation.
mkClaimMask :: Map Bank BankMask -> ClaimMask
mkClaimMask = ClaimMask <<< Map.filter (not <<< isEmptyMask)

-- | The empty claim — no slots claimed on any bank.
emptyClaimMask :: ClaimMask
emptyClaimMask = ClaimMask Map.empty

-- | Single-bank shorthand — most claims this phase are one bank.
singletonClaim :: Bank -> BankMask -> ClaimMask
singletonClaim b m
  | isEmptyMask m = emptyClaimMask
  | otherwise = ClaimMask (Map.singleton b m)

-- | Union of two ClaimMasks — slots in either.
unionClaim :: ClaimMask -> ClaimMask -> ClaimMask
unionClaim (ClaimMask a) (ClaimMask b) =
  mkClaimMask (Map.unionWith unionMask a b)

-- | Intersection — slots in both.  Banks where one side is missing
-- | drop out (no overlap there).
intersectClaim :: ClaimMask -> ClaimMask -> ClaimMask
intersectClaim (ClaimMask a) (ClaimMask b) =
  let
    merged = Map.intersectionWith intersectMask a b
  in
    mkClaimMask merged

isEmptyClaim :: ClaimMask -> Boolean
isEmptyClaim (ClaimMask m) = Map.isEmpty m

-- | Whether every bit in `a` is also in `b`.
isSubsetClaim :: ClaimMask -> ClaimMask -> Boolean
isSubsetClaim (ClaimMask a) bClaim =
  Array.all (\(Tuple bank aMask) -> case bClaim of
                ClaimMask b ->
                  isSubsetMask aMask (fromMaybe emptyMask (Map.lookup bank b)))
            ((Map.toUnfoldable a) :: Array (Tuple Bank BankMask))

-- ---------------------------------------------------------------------------
-- Owner identity
-- ---------------------------------------------------------------------------

-- | What kind of declaration owns a claim.  Carried in error
-- | messages so a collision between an Instrument and a DrumKit
-- | reads correctly ("instrument `x` vs drum kit `y`" rather than
-- | "x vs y"); also lets future policy choices (e.g. "drumkit voice
-- | names cannot collide with tvoice names" from the design doc)
-- | dispatch on owner kind.
data OwnerKind
  = OwnInstrument
  | OwnDrumKit
  | OwnPolySignal
  | OwnTvoice
  | OwnYarns

derive instance eqOwnerKind :: Eq OwnerKind
derive instance ordOwnerKind :: Ord OwnerKind

instance showOwnerKind :: Show OwnerKind where
  show = describeOwnerKind

describeOwnerKind :: OwnerKind -> String
describeOwnerKind = case _ of
  OwnInstrument -> "instrument"
  OwnDrumKit    -> "drum kit"
  OwnPolySignal -> "polysignal"
  OwnTvoice     -> "tvoice"
  OwnYarns      -> "yarns"

-- | An owner's stable identity.  Two claims with the same `OwnerId`
-- | are the same owner (re-firing a cell updates the claim
-- | idempotently); different `OwnerId`s are different owners even
-- | if the underlying string matches.
data OwnerId = OwnerId OwnerKind String

derive instance eqOwnerId :: Eq OwnerId
derive instance ordOwnerId :: Ord OwnerId

instance showOwnerId :: Show OwnerId where
  show = prettyOwner

-- | Human-readable rendering for error messages.
prettyOwner :: OwnerId -> String
prettyOwner (OwnerId kind name) =
  describeOwnerKind kind <> " `" <> name <> "`"

-- ---------------------------------------------------------------------------
-- Claim
-- ---------------------------------------------------------------------------

-- | One owner's footprint on the rig.  The parallel `slots` map
-- | carries the per-slot `NeedKind`s so capability errors can
-- | report which specific slots are wrong-shaped, not just "this
-- | claim has a bad bank".
type Claim =
  { owner :: OwnerId
  , mask :: ClaimMask
  , slots :: Map Bank (Array { slot :: Int, need :: NeedKind })
  }

-- ---------------------------------------------------------------------------
-- Overlap classification
-- ---------------------------------------------------------------------------

-- | The five distinguishable overlap shapes between two claim
-- | masks.  Used by `applyClaim` to dispatch to the right policy:
-- | `Disjoint` is always allowed; `ExactMatch` is policy-dependent
-- | (per-bank `SwapPolicy`); the three partial shapes are always
-- | errors.
data OverlapShape
  = Disjoint
  | ExactMatch
  | NewSubsetsOld
  | OldSubsetsNew
  | PartialOverlap

derive instance eqOverlapShape :: Eq OverlapShape
derive instance ordOverlapShape :: Ord OverlapShape

instance showOverlapShape :: Show OverlapShape where
  show = case _ of
    Disjoint       -> "Disjoint"
    ExactMatch     -> "ExactMatch"
    NewSubsetsOld  -> "NewSubsetsOld"
    OldSubsetsNew  -> "OldSubsetsNew"
    PartialOverlap -> "PartialOverlap"

-- | Compare two claim masks.  Order of arguments is `old`, `new`:
-- | `NewSubsetsOld` means the *new* claim is a proper subset of
-- | the *old* one, etc.
classifyOverlap :: ClaimMask -> ClaimMask -> OverlapShape
classifyOverlap oldM newM =
  let
    isect = oldM `intersectClaim` newM
  in
    if isEmptyClaim isect then Disjoint
    else if oldM == newM then ExactMatch
    else if isSubsetClaim newM oldM then NewSubsetsOld
    else if isSubsetClaim oldM newM then OldSubsetsNew
    else PartialOverlap

-- ---------------------------------------------------------------------------
-- ClaimTable
-- ---------------------------------------------------------------------------

-- | The authoritative table of who-owns-what.  One per running rig.
-- | Wraps an Array (insertion order) so error messages can render
-- | conflicts in declaration order.
newtype ClaimTable = ClaimTable (Array Claim)

derive instance newtypeClaimTable :: Newtype ClaimTable _

instance showClaimTable :: Show ClaimTable where
  show (ClaimTable cs) =
    "ClaimTable [" <> joinWith ", " (map showClaim cs) <> "]"
    where
    showClaim c = prettyOwner c.owner <> " " <> show c.mask

emptyTable :: ClaimTable
emptyTable = ClaimTable []

-- | Project out the claims for iteration / inspection.
tableClaims :: ClaimTable -> Array Claim
tableClaims (ClaimTable cs) = cs

-- ---------------------------------------------------------------------------
-- Claim errors
-- ---------------------------------------------------------------------------

-- | One reason a claim could not be installed.
-- |
-- |   * `CapabilityError` — one or more requested slots can't do
-- |     what the owner needs (e.g. NeedCV on a Gate-only bank).
-- |     Reported before any overlap checks; capability is a
-- |     short-circuit.
-- |   * `ExactMatchRejected` — the new claim hits exactly the same
-- |     slot set as an existing claim under a different owner, on
-- |     a bank whose `SwapPolicy = SwapError` (MIDI channels).
-- |   * `PartialConflict` — the new claim overlaps an existing
-- |     claim under a different owner without exact-matching it.
-- |     Always an error regardless of swap policy.
data ClaimError
  = CapabilityError
      { owner :: OwnerId
      , conflicts ::
          Array { bank :: Bank, slot :: Int, need :: NeedKind, has :: Capability }
      }
  | ExactMatchRejected
      { owner :: OwnerId
      , conflict :: { with :: OwnerId, slots :: ClaimMask }
      }
  | PartialConflict
      { owner :: OwnerId
      , conflicts :: Array { with :: OwnerId, slots :: ClaimMask }
      }

derive instance eqClaimError :: Eq ClaimError

instance showClaimError :: Show ClaimError where
  show = describeClaimError

-- | One-line rendering suitable for the BEAM log + Calypso reply
-- | pane.  Examples:
-- |
-- |     instrument `bass1b`: duplicate claim on `iac` ch 1 — already
-- |       claimed by instrument `bass1`
-- |     polylfo `myLfo`: needs CV on `es9 gt 0` slot 3 (gate-only)
-- |     drumkit `kitA`: partial conflict on `es9 panel` slots 0, 1
-- |       — overlaps polyclock `myClk`
describeClaimError :: ClaimError -> String
describeClaimError = case _ of
  CapabilityError r ->
    prettyOwner r.owner
      <> ": "
      <> joinWith "; " (map describeOneCapErr r.conflicts)
  ExactMatchRejected r ->
    prettyOwner r.owner
      <> ": "
      <> describeExactMatchErr r.conflict
  PartialConflict r ->
    prettyOwner r.owner
      <> ": "
      <> joinWith "; " (map describeOnePartialErr r.conflicts)
  where
  describeOneCapErr c =
    "needs "
      <> describeNeed c.need
      <> " on `"
      <> describeBank c.bank
      <> "` slot "
      <> show c.slot
      <> " ("
      <> describeCapability c.has
      <> "-only)"
  describeExactMatchErr c =
    "duplicate claim on "
      <> describeClaimMaskBriefly c.slots
      <> " — already claimed by "
      <> prettyOwner c.with
  describeOnePartialErr c =
    "partial conflict on "
      <> describeClaimMaskBriefly c.slots
      <> " — overlaps "
      <> prettyOwner c.with

-- | Brief rendering for a ClaimMask in an error: `iac ch 1`,
-- | `es9 panel slots 0, 1`.  Single-bank single-slot is the
-- | dominant case so we keep that compact.
describeClaimMaskBriefly :: ClaimMask -> String
describeClaimMaskBriefly (ClaimMask m) =
  joinWith ", " (map renderBank (Map.toUnfoldable m :: Array (Tuple Bank BankMask)))
  where
  renderBank (Tuple bank bm) =
    let bits = maskBits bm
    in case bank of
      BankMidi _ -> case bits of
        -- MIDI channels are 1-16 to the user; mask bit i = channel i+1.
        [i] -> "`" <> describeBank bank <> "` ch " <> show (i + 1)
        _   -> "`" <> describeBank bank <> "` channels "
                 <> joinWith ", " (map (\i -> show (i + 1)) bits)
      _ -> case bits of
        [i] -> "`" <> describeBank bank <> "` slot " <> show i
        _   -> "`" <> describeBank bank <> "` slots "
                 <> joinWith ", " (map show bits)

-- ---------------------------------------------------------------------------
-- applyClaim — the validator
-- ---------------------------------------------------------------------------

-- | Try to install a claim.  Returns:
-- |
-- |   * `Right updated` — claim installed, with any same-owner
-- |     update or `SwapOk` eviction applied atomically.
-- |   * `Left err` — capability mismatch, exact-match rejected by
-- |     `SwapError` policy, or partial conflict against existing
-- |     claims.
-- |
-- | Algorithm:
-- |
-- |   1. Capability check first — every (bank, slot, need) triple
-- |      in the new claim is verified against `bankCapability`.
-- |      Any mismatch returns `CapabilityError` immediately; we
-- |      never report capability + overlap in the same response.
-- |   2. Remove any existing claim with the same `OwnerId` from
-- |      the candidate set (same-owner update is idempotent — the
-- |      owner replaces its own previous claim freely).
-- |   3. Classify the new claim against each remaining existing
-- |      claim.  Disjoint claims stay; partial-overlap shapes
-- |      collect into `PartialConflict`.  ExactMatch dispatches on
-- |      the bank's `SwapPolicy`: `SwapOk` evicts the existing
-- |      claim, `SwapError` produces `ExactMatchRejected`.
-- |   4. If any errors were collected, return them; otherwise
-- |      return the new table with evictions applied + the new
-- |      claim appended.
applyClaim :: Claim -> ClaimTable -> Either ClaimError ClaimTable
applyClaim newC (ClaimTable existing) =
  case checkCapability newC of
    Just err -> Left err
    Nothing ->
      let
        -- Step 2: drop same-owner claims; they're replaced wholesale.
        others :: Array Claim
        others = Array.filter (\c -> c.owner /= newC.owner) existing

        -- Step 3: classify against each remaining existing claim.
        classified :: Array { existing :: Claim, shape :: OverlapShape }
        classified = map (\c -> { existing: c
                                , shape: classifyOverlap c.mask newC.mask })
                         others

        -- Partial-overlap shapes are always errors (regardless of swap policy).
        partials = Array.filter (isPartialShape <<< _.shape) classified

        -- Exact matches — dispatch on per-bank swap policy.
        exactMatches = Array.filter (\r -> r.shape == ExactMatch) classified

        exactMatchErr :: Maybe ClaimError
        exactMatchErr = case Array.head exactMatches of
          Nothing -> Nothing
          Just r ->
            -- If any bank in the intersection has SwapError, reject.
            let
              banks = case r.existing.mask `intersectClaim` newC.mask of
                ClaimMask m -> (Map.keys m :: _) # Array.fromFoldable
              anySwapError = Array.any (\b -> bankSwapPolicy b == SwapError) banks
            in
              if anySwapError then Just $ ExactMatchRejected
                { owner: newC.owner
                , conflict:
                    { with: r.existing.owner
                    , slots: r.existing.mask `intersectClaim` newC.mask
                    }
                }
              else Nothing
      in
        case Array.null partials, exactMatchErr of
          false, _ ->
            Left $ PartialConflict
              { owner: newC.owner
              , conflicts:
                  map
                    (\r ->
                       { with: r.existing.owner
                       , slots: r.existing.mask `intersectClaim` newC.mask
                       })
                    partials
              }
          true, Just err -> Left err
          true, Nothing ->
            -- Step 4: success.  Evict ExactMatch holders (SwapOk only,
            -- since SwapError was caught above), append the new claim.
            let
              evictedOwners = map _.existing.owner exactMatches
              kept = Array.filter
                       (\c -> not (Array.elem c.owner evictedOwners))
                       others
            in
              Right (ClaimTable (Array.snoc kept newC))
  where
  isPartialShape NewSubsetsOld  = true
  isPartialShape OldSubsetsNew  = true
  isPartialShape PartialOverlap = true
  isPartialShape _              = false

-- | Internal: capability check for every claimed slot.  Returns
-- | `Nothing` on success; `Just CapabilityError` listing every
-- | offending (bank, slot, need, has) tuple on failure.
checkCapability :: Claim -> Maybe ClaimError
checkCapability c =
  let
    bankSlotPairs :: Array (Tuple Bank (Array { slot :: Int, need :: NeedKind }))
    bankSlotPairs = Map.toUnfoldable c.slots

    perBank :: Tuple Bank (Array { slot :: Int, need :: NeedKind })
            -> Array { bank :: Bank, slot :: Int, need :: NeedKind, has :: Capability }
    perBank pair =
      let bank = fst pair
          cap = bankCapability bank
      in Array.mapMaybe
           (\s -> if needFitsBank s.need cap then Nothing
                  else Just { bank, slot: s.slot, need: s.need, has: cap })
           (snd pair)

    conflicts = Array.concatMap perBank bankSlotPairs
  in
    if Array.null conflicts then Nothing
    else Just $ CapabilityError { owner: c.owner, conflicts }
