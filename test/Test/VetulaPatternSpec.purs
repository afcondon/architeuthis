-- | Tests for `Tidal.Vetula.Pattern` — V-D: VetulaPart as a first-
-- | class Notation; query the resulting `Pattern PitchedNote12` and
-- | verify it emits stacked Chromatic events per chord, sequenced
-- | across the progression.
module Test.VetulaPatternSpec
  ( runVetulaPatternTests
  ) where

import Prelude

import Data.Array as Array
import Effect (Effect)
import Effect.Console (log)

import Tidal.Notation (toPattern)
import Data.Rational (fromInt)
import Tidal.Pattern.Core (firstCycle, queryArc)
import Tidal.Pattern.Types (eventValue)
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Vetula (Numeral(..), Quality(..), cMajorKey, deg)
import Tidal.Vetula.Pattern (vetula, vetulaPattern, voicingAsStack)
import Tidal.Vetula.Voicing (Voicing(..))

runVetulaPatternTests :: Effect Unit
runVetulaPatternTests = do
  log ""
  log "--- Tidal.Vetula.Pattern — V-D ---"

  -- ------------------------------------------------------------------
  -- voicingAsStack — single voicing emits N parallel events
  -- ------------------------------------------------------------------
  log ""
  log "  voicingAsStack:"
  let
    cmajVoicing = Voicing [60, 64, 67]
    stackedEvents = firstCycle (voicingAsStack cmajVoicing)
    stackedValues = Array.sort (map eventValue stackedEvents)
  expectInt "C major voicing → 3 events in first cycle" 3 (Array.length stackedEvents)
  expectPitches
    "stack [60, 64, 67] → values C E G as Chromatics"
    [Chromatic 60, Chromatic 64, Chromatic 67]
    stackedValues

  expectInt "empty Voicing → 0 events" 0
    (Array.length (firstCycle (voicingAsStack (Voicing []))))

  -- ------------------------------------------------------------------
  -- vetulaPattern — full progression realisation
  -- ------------------------------------------------------------------
  log ""
  log "  vetulaPattern:"
  let
    -- Single-chord progression: I Maj → C E G stacked
    oneChord = vetula cMajorKey [deg I Maj []] identity
    oneChordEvents = firstCycle (vetulaPattern oneChord)
    oneChordValues = Array.sort (map eventValue oneChordEvents)
  expectInt "single-chord progression → 3 events in first cycle" 3
    (Array.length oneChordEvents)
  expectPitches
    "single C major chord → [60, 64, 67] Chromatics"
    [Chromatic 60, Chromatic 64, Chromatic 67]
    oneChordValues

  -- Two-chord progression: I Maj, V Maj
  -- cat is slowCat — one chord per cycle.  firstCycle [0, 1) sees
  -- only the first chord (3 events).  To see both chords, we'd
  -- query [0, 2) — see "across two cycles" test below.
  let
    twoChord = vetula cMajorKey [deg I Maj [], deg V Maj []] identity
    twoChordEvents = firstCycle (vetulaPattern twoChord)
  expectInt "two-chord progression → 3 events in first cycle (only chord 1)" 3
    (Array.length twoChordEvents)

  -- Across two cycles [0, 2) the second chord should also fire.
  -- For Cmaj [60, 64, 67] voice-led to V (PCs [2, 7, 11] = D G B):
  --   Best perm [11, 2, 7]: 60→11=59 (move 1), 64→2=62 (2), 67→7=67 (0).
  --   Result sorted [59, 62, 67] = B3 D4 G4.  Total motion 3.
  let
    twoCycles = queryArc (vetulaPattern twoChord) (fromInt 0) (fromInt 2)
  expectInt "two-chord progression queried [0, 2) → 6 events total" 6
    (Array.length twoCycles)

  -- Empty progression → silence
  let emptyVet = vetula cMajorKey [] identity
  expectInt "empty progression → 0 events" 0
    (Array.length (firstCycle (vetulaPattern emptyVet)))

  -- ------------------------------------------------------------------
  -- Notation instance — toPattern matches vetulaPattern
  -- ------------------------------------------------------------------
  log ""
  log "  Notation VetulaPart PitchedNote12 instance:"
  let
    viaInstance = firstCycle (toPattern oneChord)
    viaDirect   = firstCycle (vetulaPattern oneChord)
  expectInt "toPattern == vetulaPattern (event count agrees)"
    (Array.length viaDirect)
    (Array.length viaInstance)

  log ""

-- ---------------------------------------------------------------------------
-- Spec helpers
-- ---------------------------------------------------------------------------

expectInt :: String -> Int -> Int -> Effect Unit
expectInt label expected actual =
  if actual == expected
    then log ("  PASS  " <> label)
    else log ("  FAIL  " <> label
              <> "\n         expected " <> show expected
              <> "\n         got      " <> show actual)

expectPitches :: String -> Array PitchedNote12 -> Array PitchedNote12 -> Effect Unit
expectPitches label expected actual =
  if actual == expected
    then log ("  PASS  " <> label)
    else log ("  FAIL  " <> label
              <> "\n         expected " <> show expected
              <> "\n         got      " <> show actual)

