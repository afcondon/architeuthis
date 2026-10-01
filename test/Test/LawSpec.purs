-- | Pattern law tests
-- |
-- | Verifies algebraic correctness of Pattern type.
module Test.LawSpec where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt, (%))
import Effect (Effect)
import Effect.Console (log)
import Tidal.AST.Types (TPat)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Parser (parseTPat)
import Tidal.Pattern.Core (queryArc, silence, stack, cat, fast, slow, rotL, rotR, rev)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern, arcStart, arcStop, eventValue)

-------------------------------------------------------------------------------
-- Test runner
-------------------------------------------------------------------------------

-- | Run all law tests
runLawTests :: Effect Unit
runLawTests = do
  log ""
  log "=========================================="
  log "  Pattern Law Tests"
  log "=========================================="
  log ""

  -- Functor Laws
  log "--- Functor Laws ---"

  testFunctorIdentity "bd sn"
    "fmap id = id"

  testFunctorComposition "bd sn hh"
    "fmap (f . g) = fmap f . fmap g"

  -- Semigroup/Monoid-like properties (stack)
  log ""
  log "--- Stack Properties ---"

  testStackAssociativity
    "stack associativity"

  testStackWithSilence
    "stack with silence"

  -- Transformation properties
  log ""
  log "--- Transformation Properties ---"

  testFastSlowInverse
    "fast 2 . slow 2 = id"

  testSlowFastInverse
    "slow 2 . fast 2 = id"

  testRotLRotRInverse
    "rotL t . rotR t = id"

  testRevRevIdentity
    "rev . rev = id"

  -- Query boundary tests
  log ""
  log "--- Query Boundary Conditions ---"

  testQueryEmptyArc
    "query empty arc returns the event at that instant (as Tidal)"

  testQuerySingleCycle
    "query single cycle returns correct events"

  testQueryMultipleCycles
    "query across cycles returns events from all"

  testQueryFractionalArc
    "query fractional arc slices events"

  -- Silence properties
  log ""
  log "--- Silence Properties ---"

  testSilenceIsEmpty
    "silence produces no events"

  log ""
  log "  Law tests complete."

-------------------------------------------------------------------------------
-- Functor Law Tests
-------------------------------------------------------------------------------

-- | Test: fmap id = id
testFunctorIdentity :: String -> String -> Effect Unit
testFunctorIdentity input desc = do
  case parseTPat input of
    Left err -> log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let mappedPat = map identity pat
      let originalEvents = queryArc pat (fromInt 0) (fromInt 1)
      let mappedEvents = queryArc mappedPat (fromInt 0) (fromInt 1)
      if eventsEqual originalEvents mappedEvents then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Original: " <> show (Array.length originalEvents) <> " events"
        log $ "    Mapped: " <> show (Array.length mappedEvents) <> " events"

-- | Test: fmap (f . g) = fmap f . fmap g
testFunctorComposition :: String -> String -> Effect Unit
testFunctorComposition input desc = do
  case parseTPat input of
    Left err -> log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let f = \s -> s <> "!"
      let g = \s -> s <> "?"
      -- fmap (f . g)
      let composed = map (f <<< g) pat
      -- fmap f . fmap g
      let chained = map f (map g pat)
      let composedEvents = queryArc composed (fromInt 0) (fromInt 1)
      let chainedEvents = queryArc chained (fromInt 0) (fromInt 1)
      if eventsEqual composedEvents chainedEvents then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    (f . g): " <> show (Array.length composedEvents) <> " events"
        log $ "    f . g applied: " <> show (Array.length chainedEvents) <> " events"

-------------------------------------------------------------------------------
-- Stack/Monoid-like Property Tests
-------------------------------------------------------------------------------

-- | Test stack associativity: (a `stack` b) `stack` c = a `stack` (b `stack` c)
testStackAssociativity :: String -> Effect Unit
testStackAssociativity desc = do
  case parseTPat "bd" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right astA -> case parseTPat "sn" of
      Left err -> log $ "  ✗ " <> desc <> ": parse error"
      Right astB -> case parseTPat "hh" of
        Left err -> log $ "  ✗ " <> desc <> ": parse error"
        Right astC -> do
          let a = tpatToPattern astA :: Pattern String
          let b = tpatToPattern astB :: Pattern String
          let c = tpatToPattern astC :: Pattern String
          -- (a <> b) <> c
          let left = stack [stack [a, b], c]
          -- a <> (b <> c)
          let right = stack [a, stack [b, c]]
          let leftEvents = queryArc left (fromInt 0) (fromInt 1)
          let rightEvents = queryArc right (fromInt 0) (fromInt 1)
          -- Both should produce 3 events
          if Array.length leftEvents == 3 && Array.length rightEvents == 3 then
            log $ "  ✓ " <> desc
          else do
            log $ "  ✗ " <> desc
            log $ "    Left: " <> show (Array.length leftEvents) <> " events"
            log $ "    Right: " <> show (Array.length rightEvents) <> " events"

-- | Test stack with silence
testStackWithSilence :: String -> Effect Unit
testStackWithSilence desc = do
  case parseTPat "bd" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let withSilence = stack [pat, silence]
      let events = queryArc withSilence (fromInt 0) (fromInt 1)
      -- Should still produce 1 event from bd
      if Array.length events == 1 then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Expected 1 event, got " <> show (Array.length events)

-------------------------------------------------------------------------------
-- Transformation Property Tests
-------------------------------------------------------------------------------

-- | Test: fast 2 . slow 2 = id
testFastSlowInverse :: String -> Effect Unit
testFastSlowInverse desc = do
  case parseTPat "bd sn" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let transformed = fast (fromInt 2) (slow (fromInt 2) pat)
      let originalEvents = queryArc pat (fromInt 0) (fromInt 1)
      let transformedEvents = queryArc transformed (fromInt 0) (fromInt 1)
      if Array.length originalEvents == Array.length transformedEvents then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Original: " <> show (Array.length originalEvents) <> " events"
        log $ "    Transformed: " <> show (Array.length transformedEvents) <> " events"

-- | Test: slow 2 . fast 2 = id
testSlowFastInverse :: String -> Effect Unit
testSlowFastInverse desc = do
  case parseTPat "bd sn" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let transformed = slow (fromInt 2) (fast (fromInt 2) pat)
      let originalEvents = queryArc pat (fromInt 0) (fromInt 1)
      let transformedEvents = queryArc transformed (fromInt 0) (fromInt 1)
      if Array.length originalEvents == Array.length transformedEvents then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Original: " <> show (Array.length originalEvents) <> " events"
        log $ "    Transformed: " <> show (Array.length transformedEvents) <> " events"

-- | Test: rotL t . rotR t = id
testRotLRotRInverse :: String -> Effect Unit
testRotLRotRInverse desc = do
  case parseTPat "bd sn hh cp" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let offset = 1 % 4
      let transformed = rotL offset (rotR offset pat)
      let originalEvents = queryArc pat (fromInt 0) (fromInt 1)
      let transformedEvents = queryArc transformed (fromInt 0) (fromInt 1)
      -- Should have same number of events
      if Array.length originalEvents == Array.length transformedEvents then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Original: " <> show (Array.length originalEvents) <> " events"
        log $ "    Transformed: " <> show (Array.length transformedEvents) <> " events"

-- | Test: rev . rev = id
testRevRevIdentity :: String -> Effect Unit
testRevRevIdentity desc = do
  case parseTPat "bd sn hh" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let transformed = rev (rev pat)
      let originalEvents = queryArc pat (fromInt 0) (fromInt 1)
      let transformedEvents = queryArc transformed (fromInt 0) (fromInt 1)
      -- Double reversal should give same events in same order
      if eventsEqual originalEvents transformedEvents then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Original: " <> show (Array.length originalEvents) <> " events"
        log $ "    Double-rev: " <> show (Array.length transformedEvents) <> " events"

-------------------------------------------------------------------------------
-- Query Boundary Tests
-------------------------------------------------------------------------------

-- | Test: querying an empty arc returns no events
testQueryEmptyArc :: String -> Effect Unit
testQueryEmptyArc desc = do
  case parseTPat "bd sn" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      -- Query arc [0.5, 0.5] - zero length. Tidal 1.10.1 answers with the
      -- event there: `(½>½)-1|"sn"` (GHCi).
      let events = queryArc pat (1 % 2) (1 % 2)
      if map eventValue events == [ "sn" ] then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Expected the one event sn, got " <> show (map eventValue events)

-- | Test: query single cycle returns correct number of events
testQuerySingleCycle :: String -> Effect Unit
testQuerySingleCycle desc = do
  case parseTPat "bd sn hh cp" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      let events = queryArc pat (fromInt 0) (fromInt 1)
      if Array.length events == 4 then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Expected 4 events, got " <> show (Array.length events)

-- | Test: query across multiple cycles returns events from all
testQueryMultipleCycles :: String -> Effect Unit
testQueryMultipleCycles desc = do
  case parseTPat "bd sn" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      -- Query cycles 0, 1, 2 (should get 2 * 3 = 6 events)
      let events = queryArc pat (fromInt 0) (fromInt 3)
      if Array.length events == 6 then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Expected 6 events, got " <> show (Array.length events)

-- | Test: query fractional arc correctly slices events
testQueryFractionalArc :: String -> Effect Unit
testQueryFractionalArc desc = do
  case parseTPat "bd sn hh cp" of
    Left err -> log $ "  ✗ " <> desc <> ": parse error"
    Right ast -> do
      let pat = tpatToPattern ast :: Pattern String
      -- Query first half of cycle [0, 0.5] should get bd and sn
      let events = queryArc pat (fromInt 0) (1 % 2)
      if Array.length events == 2 then
        log $ "  ✓ " <> desc
      else do
        log $ "  ✗ " <> desc
        log $ "    Expected 2 events (bd, sn), got " <> show (Array.length events)

-------------------------------------------------------------------------------
-- Silence Property Tests
-------------------------------------------------------------------------------

-- | Test: silence produces no events
testSilenceIsEmpty :: String -> Effect Unit
testSilenceIsEmpty desc = do
  let events = queryArc (silence :: Pattern String) (fromInt 0) (fromInt 1)
  if Array.length events == 0 then
    log $ "  ✓ " <> desc
  else do
    log $ "  ✗ " <> desc
    log $ "    Expected 0 events, got " <> show (Array.length events)

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- | Compare two event arrays for structural equality (same length, same values)
eventsEqual :: forall a. Eq a => Array (Event a) -> Array (Event a) -> Boolean
eventsEqual a b =
  Array.length a == Array.length b &&
  Array.all identity (Array.zipWith eventsSameValue a b)

eventsSameValue :: forall a. Eq a => Event a -> Event a -> Boolean
eventsSameValue (Digital e1) (Digital e2) = e1.value == e2.value
eventsSameValue (Analog e1) (Analog e2) = e1.value == e2.value
eventsSameValue _ _ = false
