-- | Tests for `Tidal.Tintinnabuli` — task #62 (scale-aware tintinnabuli).
-- |
-- | Red-then-green: the existing `tintinnabuli :: Triad -> Position ->
-- | Pattern PitchedNote12 -> Pattern PitchedNote12` is a no-op on `Degree` values
-- | (passes them through unchanged).  The MVP-3 demo therefore can't
-- | follow a live `set-scale` — the M-voice's degrees retune but the
-- | T-voice is identical to the M-voice (both go through the Voice
-- | emit path's degree-resolution; no triad rule is applied).
-- |
-- | The desired shape: `tintinnabuli :: Scale -> Triad -> Position ->
-- | Pattern PitchedNote12 -> Pattern PitchedNote12` resolves degrees eagerly against
-- | the given scale and applies the nearest-triad rule to the resulting
-- | chromatic.  Live `set-scale` retunes the M-voice (Voice emit path)
-- | but NOT the T-voice — the user re-arms when they want the T-voice
-- | to follow.  This is intentional for v1; full live-tracking via a
-- | new emit-time-resolved PitchedNote12 variant is queued separately.
module Test.TintinnabuliSpec
  ( runTintinnabuliTests
  ) where

import Prelude

import Data.Array as Array
import Haskell.Rational (fromInt)
import Effect (Effect)
import Effect.Console (log)

import Tidal.Pattern.Core (fastCat, queryArc)
import Tidal.Pattern.Types (Pattern, eventValue)
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Notation (toPattern)
import Tidal.Pitch.Parse (degree, pitch)
import Tidal.Substrate.Scales (cMajor, dDorian)
import Tidal.Tintinnabuli (above1, below1, cMajT, tintinnabuli)

runTintinnabuliTests :: Effect Unit
runTintinnabuliTests = do
  log ""
  log "--- Tintinnabuli scale-aware (task #62) ---"

  -- --------------------------------------------------------------------
  -- Regression: chromatic input is unchanged by the new Scale argument.
  -- The scale parameter is only consulted for Degree values; Chromatic
  -- values pass straight through to the nearest-triad rule.
  -- --------------------------------------------------------------------
  let
    chromaticIn = pitch "c4 e4 g4"       -- Chromatic 60, 64, 67
    chromaticOut = tintinnabuli cMajor cMajT above1 chromaticIn
  expectPitches
    "chromatic c4-e4-g4 + cMajT above1 → e4-g4-c5"
    [Chromatic 64, Chromatic 67, Chromatic 72]
    chromaticOut

  -- --------------------------------------------------------------------
  -- Degrees + scale.  In C major:
  --   degree 1 → 60 (C4), above1 of cMajT = strict above 60 in {C,E,G}
  --                                       = 64 (E4)
  --   degree 3 → 64 (E4), above1 strict above 64 = 67 (G4)
  --   degree 5 → 67 (G4), above1 strict above 67 = 72 (C5)
  -- --------------------------------------------------------------------
  let
    degreesIn = degree "1 3 5"
    cMajorOut = tintinnabuli cMajor cMajT above1 degreesIn
  expectPitches
    "degrees 1-3-5 in cMajor + cMajT above1 → e4-g4-c5"
    [Chromatic 64, Chromatic 67, Chromatic 72]
    cMajorOut

  -- --------------------------------------------------------------------
  -- Same degrees in D dorian — different MIDI for the M-voice, so the
  -- T-voice's nearest-triad results differ.  We use `below1` because
  -- the spread is large enough to reach a different triad note in each
  -- direction:
  --   cMajor below1:
  --     degree 1 = 60 → below in {C,E,G} = 55 (G3)
  --     degree 3 = 64 → 60 (C4)
  --     degree 5 = 67 → 64 (E4)
  --   dDorian below1:
  --     degree 1 = 62 → below in {C,E,G} = 60 (C4)
  --     degree 3 = 65 → 64 (E4)
  --     degree 5 = 69 → 67 (G4)
  -- --------------------------------------------------------------------
  let
    cMajorBelowOut = tintinnabuli cMajor cMajT below1 degreesIn
    dDorianBelowOut = tintinnabuli dDorian cMajT below1 degreesIn
  expectPitches
    "degrees 1-3-5 in cMajor + cMajT below1 → g3-c4-e4"
    [Chromatic 55, Chromatic 60, Chromatic 64]
    cMajorBelowOut
  expectPitches
    "degrees 1-3-5 in dDorian + cMajT below1 → c4-e4-g4"
    [Chromatic 60, Chromatic 64, Chromatic 67]
    dDorianBelowOut

  -- --------------------------------------------------------------------
  -- Mixed pattern: Degree, Chromatic, and Sample in one input.  Sample
  -- passes through (no pitch); Chromatic resolves directly; Degree
  -- consults the scale.  `fastCat` packs three single-event patterns
  -- into one cycle.
  -- --------------------------------------------------------------------
  let
    mixedIn = fastCat [toPattern (degree "1"), toPattern (pitch "e4"), toPattern (pitch "bd")]
    mixedOut = tintinnabuli cMajor cMajT above1 mixedIn
  expectPitches
    "mixed (degree 1, chromatic e4, sample bd) → e4, g4, bd"
    [Chromatic 64, Chromatic 67, Sample "bd"]
    mixedOut

expectPitches :: String -> Array PitchedNote12 -> Pattern PitchedNote12 -> Effect Unit
expectPitches desc expected pat =
  let events = queryArc pat (fromInt 0) (fromInt 1)
      actual = map eventValue events
  in if actual == expected
    then log $ "  ✓ " <> desc
    else log $ "  ✗ " <> desc <> "\n     got:      " <> show actual
                                     <> "\n     expected: " <> show expected
