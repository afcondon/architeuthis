module Test.Main where

import Prelude

import Data.Either (Either(..))
import Effect (Effect)
import Effect.Console (log)
import Test.BranchedSpec (runBranchedTests)
import Test.ControlSpec (runControlTests)
import Test.DejaVuSpec (runDejaVuTests)
import Test.LawSpec (runLawTests)
import Test.MidiClaimSpec (runMidiClaimTests)
import Test.PatternSpec (runPatternTests)
import Test.PredictiveSpec (runPredictiveTests)
import Test.SinkSpec (runSinkTests)
import Test.TintinnabuliSpec (runTintinnabuliTests)
import Test.UtilSpec (runUtilTests)
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Tidal.AST.Pretty (pretty)
import Tidal.AST.Types (Located(..), TPat(..))
import Tidal.Parse.Parser (parseTPat)

main :: Effect Unit
main = do
  log "=== psd3-tidal Parser Tests ==="
  log ""

  log "--- Basic Atoms ---"
  testParse "bd" "single atom"
  testParse "bd sn" "two atoms"
  testParse "bd sn hh" "three atoms"
  testParse "bd:2" "atom with variant"
  testParse "808.wav" "atom with dot"

  log ""
  log "--- Silence ---"
  testParse "bd ~ sn" "with silence"
  testParse "~ ~ ~" "all silence"

  log ""
  log "--- Speed Modifiers ---"
  testParse "bd*2" "fast"
  testParse "bd/2" "slow"
  testParse "bd*2 sn" "fast in sequence"
  testParse "[bd sn]*2" "fast group"

  log ""
  log "--- Degradation ---"
  testParse "bd?" "degrade default"
  testParse "bd?0.25" "degrade with prob"

  log ""
  log "--- Repetition ---"
  testParse "bd!" "repeat once (doubles)"
  testParse "bd!3" "repeat 3 times"

  log ""
  log "--- Elongation ---"
  testParse "bd@2" "elongate"
  testParse "bd_" "underscore elongate"

  log ""
  log "--- Grouping ---"
  testParse "[bd sn]" "simple group"
  testParse "[bd sn hh]" "group of 3"
  testParse "[[bd sn] hh]" "nested groups"

  log ""
  log "--- Stack ---"
  testParse "bd, sn" "stack of 2"
  testParse "bd sn, hh" "stack with sequence"

  log ""
  log "--- Polyrhythm ---"
  testParse "{bd sn, hh hh hh}" "polyrhythm"
  testParse "<bd sn hh>" "alternating"

  log ""
  log "--- Euclidean ---"
  testParse "bd(3,8)" "euclidean"
  testParse "bd(5,8,2)" "euclidean with offset"

  log ""
  log "--- Choose ---"
  testParse "bd | sn" "choose"
  testParse "bd | sn | hh" "choose 3"

  log ""
  log "--- Variables ---"
  testParse "^pattern" "variable"
  testParse "bd ^fill sn" "variable in sequence"

  log ""
  log "--- Round-trip Tests ---"
  testRoundTrip "bd sn hh"
  testRoundTrip "[bd sn]*2"
  testRoundTrip "bd, sn, hh"
  testRoundTrip "<bd sn hh>"
  testRoundTrip "{bd sn, hh hh hh}"
  testRoundTrip "bd(3,8)"

  log ""
  log "--- Complex Nesting ---"
  testParse "[[bd sn] [hh cp]]" "nested groups"
  testParse "[[[bd]]]" "deeply nested (3 levels)"
  testParse "<[bd sn] [hh cp]>" "alternating groups"
  testParse "{[bd sn]*2, hh hh hh}" "poly with fast group"
  testParse "[bd, sn] [hh, cp]" "stacks in sequence"

  log ""
  log "--- Mixed Operators ---"
  testParse "bd*2 sn/2" "fast and slow in sequence"
  testParse "[bd*2]*2" "nested fast"
  testParse "[bd!2]*2" "repeat in group then fast"
  testParse "bd@2 sn" "elongate with sequence"
  testParse "bd? sn? hh?" "multiple degrades"

  log ""
  log "--- Edge Cases ---"
  testParse "bd sn hh cp lo" "long sequence (5)"
  testParse "bd, sn, hh, cp" "stacked 4-way"
  testParse "bd(1,1)" "euclidean 1,1"
  testParse "bd(8,8)" "euclidean full"
  testParse "[bd]" "single element group"
  testParse "< bd >" "alternating single"

  log ""
  log "--- Sharp accidentals (#) ---"
  testParse "f#2" "single sharp note"
  testParse "c#4 d#4 f#4" "sharp-note sequence"
  testParse "f#2*4" "sharp note with fast modifier"
  testParse "[c#4, e4, g#4]" "explicit chord stack with sharps"

  log ""
  log "--- Chord syntax ---"
  testChord "c4'major"   ["c4", "e4", "g4"]                  "C major triad"
  testChord "c4'minor"   ["c4", "ds4", "g4"]                 "C minor triad"
  testChord "c4'major7"  ["c4", "e4", "g4", "b4"]            "C major 7"
  testChord "c4'minor7"  ["c4", "ds4", "g4", "as4"]          "C minor 7"
  testChord "f#3'minor"  ["fs3", "a3", "cs4"]                "F# minor (sharp root)"
  testChord "'major"     ["c4", "e4", "g4"]                  "default-root major"
  testChord "c4'major7'i"["e4", "g4", "b4", "c5"]            "C major 7 first inversion"
  testParse "c4'major"   "chord parses (smoke)"
  testParse "c4'major7 e4'minor7 g4'major7" "chord sequence"
  testParse "c4'major*2" "chord with fast modifier"
  testParse "<c4'major c4'minor>" "alternating chords"

  log ""
  log "=== Parser tests completed ==="

  -- Run pattern evaluation tests
  runPatternTests

  -- Run predictive event-shape tests (whole + part assertions)
  runPredictiveTests

  -- Run control pattern tests
  runControlTests

  -- Run law/property tests
  runLawTests

  -- Run utility tests
  runUtilTests

  -- Run Branched (fork/merge) tests
  runBranchedTests

  -- Run Tidal.Sink (typed voices) tests
  runSinkTests

  -- Run DejaVu / LiveControl / Random tests
  runDejaVuTests

  -- Run Tidal.MidiClaim (frontend reservations Phase 1) tests
  runMidiClaimTests

  -- Run Tidal.Tintinnabuli scale-aware tests (task #62)
  runTintinnabuliTests

  log ""
  log "=== All tests completed ==="

testParse :: String -> String -> Effect Unit
testParse input desc = do
  let result = parseTPat input :: Either _ (TPat String)
  case result of
    Right _ -> log $ "  ✓ " <> desc <> ": \"" <> input <> "\""
    Left err -> log $ "  ✗ " <> desc <> ": \"" <> input <> "\" - " <> show err

testRoundTrip :: String -> Effect Unit
testRoundTrip input = do
  let result1 = parseTPat input :: Either _ (TPat String)
  case result1 of
    Left err -> log $ "  ✗ Round-trip \"" <> input <> "\" - parse failed: " <> show err
    Right ast1 -> do
      let printed = pretty ast1
      let result2 = parseTPat printed :: Either _ (TPat String)
      case result2 of
        Left err -> log $ "  ✗ Round-trip \"" <> input <> "\" -> \"" <> printed <> "\" - reparse failed: " <> show err
        Right _ ->
          log $ "  ✓ Round-trip: \"" <> input <> "\" -> \"" <> printed <> "\""

-- | Verify a chord-syntax input expands to the expected stack of note-name
-- | atoms.  The parser's top-level `pTidal` wraps everything in a `TPat_Seq`,
-- | so for a single-token chord input the AST is `Seq [Stack [atom, ...]]`.
testChord :: String -> Array String -> String -> Effect Unit
testChord input expected desc =
  case parseTPat input :: Either _ (TPat String) of
    Left err ->
      log $ "  ✗ " <> desc <> ": \"" <> input <> "\" - parse failed: " <> show err
    Right ast ->
      case extractStackValues ast of
        Just got
          | got == expected ->
              log $ "  ✓ " <> desc <> ": \"" <> input <> "\" → [" <> joinWith ", " got <> "]"
          | otherwise ->
              log $ "  ✗ " <> desc <> ": \"" <> input <> "\" → ["
                <> joinWith ", " got <> "] (expected [" <> joinWith ", " expected <> "])"
        Nothing ->
          log $ "  ✗ " <> desc <> ": \"" <> input <> "\" — not a stack of atoms"

-- | Pull the values out of a `Seq [Stack [atom, atom, ...]]` shape, which
-- | is what a single chord token compiles to.  Returns Nothing if the AST
-- | has any other shape.
extractStackValues :: TPat String -> Maybe (Array String)
extractStackValues = case _ of
  TPat_Seq _ inner -> case Array.uncons inner of
    Just { head, tail } | Array.null tail -> stackValues head
    _ -> Nothing
  other -> stackValues other
  where
    stackValues = case _ of
      TPat_Stack _ atoms -> traverse atomValue atoms
      TPat_Atom (Located _ v) -> Just [v]
      _ -> Nothing
    atomValue = case _ of
      TPat_Atom (Located _ v) -> Just v
      _ -> Nothing
    traverse f = Array.foldr step (Just [])
      where
        step a macc = do
          v  <- f a
          xs <- macc
          pure (Array.cons v xs)
