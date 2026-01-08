-- | Pattern evaluation tests
-- |
-- | Tests the complete chain: parse → evaluate → query → verify events
-- | This allows testing pattern behavior without needing MIDI or audio.
module Test.PatternSpec where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt, toNumber, (%))
import Effect (Effect)
import Effect.Console (log)
import Tidal.AST.Types (TPat)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Parser (parseTPat)
import Tidal.Pattern.Core (cat, fast, fastAppend, fastCat, queryArc, rev, rotL, rotR, slow, stack)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern, arcStart, arcStop)

-------------------------------------------------------------------------------
-- Test runner
-------------------------------------------------------------------------------

-- | Run all pattern evaluation tests
runPatternTests :: Effect Unit
runPatternTests = do
  log ""
  log "=========================================="
  log "  Pattern Evaluation Tests"
  log "=========================================="
  log ""

  -- Basic patterns
  log "--- Sequence Patterns ---"
  testPattern "bd"
    "single sound"
    1
    [{ sample: "bd", start: 0.0, stop: 1.0 }]

  testPattern "bd sn"
    "two sounds"
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

  testPattern "bd sn hh cp"
    "four sounds"
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "sn", start: 0.25, stop: 0.5 }
    , { sample: "hh", start: 0.5, stop: 0.75 }
    , { sample: "cp", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- Silence ---"
  testPattern "bd ~ sn"
    "with rest"
    2
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "sn", start: 0.666, stop: 1.0 }
    ]

  log ""
  log "--- Stack (Parallel) Patterns ---"
  testPattern "bd, sn"
    "two parallel sounds"
    2
    [ { sample: "bd", start: 0.0, stop: 1.0 }
    , { sample: "sn", start: 0.0, stop: 1.0 }
    ]

  testPattern "bd sn, hh"
    "sequence + single"
    3
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    , { sample: "hh", start: 0.0, stop: 1.0 }
    ]

  log ""
  log "--- Speed Modifiers ---"
  testPattern "bd*2"
    "fast x2"
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 1.0 }
    ]

  testPattern "bd*4"
    "fast x4"
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- Euclidean Rhythms ---"
  -- E(3,8) = [1,0,0,1,0,0,1,0] hits at positions 0, 3, 6 (of 8)
  testPattern "bd(3,8)"
    "euclidean 3,8"
    3
    [ { sample: "bd", start: 0.0, stop: 0.125 }      -- position 0/8
    , { sample: "bd", start: 0.375, stop: 0.5 }     -- position 3/8
    , { sample: "bd", start: 0.75, stop: 0.875 }    -- position 6/8
    ]

  -- E(5,8) = [1,0,1,1,0,1,1,0] hits at positions 0, 2, 3, 5, 6 (of 8)
  testPattern "bd(5,8)"
    "euclidean 5,8"
    5
    [ { sample: "bd", start: 0.0, stop: 0.125 }      -- position 0/8
    , { sample: "bd", start: 0.25, stop: 0.375 }    -- position 2/8
    , { sample: "bd", start: 0.375, stop: 0.5 }     -- position 3/8
    , { sample: "bd", start: 0.625, stop: 0.75 }    -- position 5/8
    , { sample: "bd", start: 0.75, stop: 0.875 }    -- position 6/8
    ]

  log ""
  log "--- Groups ---"
  testPattern "[bd sn]"
    "simple group"
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

  testPattern "[bd sn]*2"
    "group fast x2"
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "sn", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 0.75 }
    , { sample: "sn", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "=========================================="
  log "  Core Combinator Tests"
  log "=========================================="
  log ""

  runCombinatorTests

  log ""
  log "=========================================="
  log "  Toussaint Euclidean Rhythms"
  log "=========================================="
  log ""

  runToussaintTests

  log ""
  log "=========================================="
  log "  Pattern Tests Complete"
  log "=========================================="

-------------------------------------------------------------------------------
-- Core Combinator Tests
-------------------------------------------------------------------------------

-- | Tests for pattern combinators using the Pattern API directly
runCombinatorTests :: Effect Unit
runCombinatorTests = do
  -- cat: patterns play in sequence across cycles
  log "--- cat (slowCat) ---"
  testPatternDirect "cat [bd, sn] cycle 0"
    (cat [pure "bd", pure "sn"])
    (fromInt 0) (fromInt 1)
    1
    [{ sample: "bd", start: 0.0, stop: 1.0 }]

  testPatternDirect "cat [bd, sn] cycle 1"
    (cat [pure "bd", pure "sn"])
    (fromInt 1) (fromInt 2)
    1
    [{ sample: "sn", start: 1.0, stop: 2.0 }]

  testPatternDirect "cat [bd, sn] cycle 2 (wraps)"
    (cat [pure "bd", pure "sn"])
    (fromInt 2) (fromInt 3)
    1
    [{ sample: "bd", start: 2.0, stop: 3.0 }]

  log ""
  log "--- fastCat ---"
  testPatternDirect "fastCat [bd, sn] (both in one cycle)"
    (fastCat [pure "bd", pure "sn"])
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

  testPatternDirect "fastCat [bd, sn, hh] (three in one cycle)"
    (fastCat [pure "bd", pure "sn", pure "hh"])
    (fromInt 0) (fromInt 1)
    3
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "sn", start: 0.333, stop: 0.666 }
    , { sample: "hh", start: 0.666, stop: 1.0 }
    ]

  log ""
  log "--- stack ---"
  testPatternDirect "stack [bd, sn] (both simultaneous)"
    (stack [pure "bd", pure "sn"])
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 1.0 }
    , { sample: "sn", start: 0.0, stop: 1.0 }
    ]

  log ""
  log "--- rev ---"
  testPatternDirect "rev (bd sn) - reversed sequence"
    (rev (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "sn", start: 0.0, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 1.0 }
    ]

  testPatternDirect "rev (bd sn hh cp)"
    (rev (fastCat [pure "bd", pure "sn", pure "hh", pure "cp"]))
    (fromInt 0) (fromInt 1)
    4
    [ { sample: "cp", start: 0.0, stop: 0.25 }
    , { sample: "hh", start: 0.25, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- fast/slow ---"
  testPatternDirect "fast 2 bd"
    (fast (fromInt 2) (pure "bd"))
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 1.0 }
    ]

  testPatternDirect "fast 4 bd"
    (fast (fromInt 4) (pure "bd"))
    (fromInt 0) (fromInt 1)
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  testPatternDirect "slow 2 (bd sn)"
    (slow (fromInt 2) (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    1
    [{ sample: "bd", start: 0.0, stop: 1.0 }]

  testPatternDirect "slow 2 (bd sn) cycle 1"
    (slow (fromInt 2) (fastCat [pure "bd", pure "sn"]))
    (fromInt 1) (fromInt 2)
    1
    [{ sample: "sn", start: 1.0, stop: 2.0 }]

  log ""
  log "--- rotL/rotR (time rotation) ---"
  -- rotL shifts pattern earlier in time (events wrap around)
  -- Original: bd@0-0.5, sn@0.5-1.0
  -- After rotL 0.25: bd@-0.25-0.25, sn@0.25-0.75, bd@0.75-1.25 (wraps)
  -- Query 0-1 sees parts of all three
  testPatternDirect "rotL 0.25 (bd sn)"
    (rotL (1 % 4) (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    3
    [ { sample: "bd", start: 0.0, stop: 0.25 }   -- tail of first bd
    , { sample: "sn", start: 0.25, stop: 0.75 }  -- full sn
    , { sample: "bd", start: 0.75, stop: 1.0 }   -- head of wrapped bd
    ]

  -- rotR shifts pattern later in time
  -- Original: bd@0-0.5, sn@0.5-1.0
  -- After rotR 0.25: sn@-0.25-0.25, bd@0.25-0.75, sn@0.75-1.25 (wraps)
  testPatternDirect "rotR 0.25 (bd sn)"
    (rotR (1 % 4) (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    3
    [ { sample: "sn", start: 0.0, stop: 0.25 }   -- tail of shifted sn
    , { sample: "bd", start: 0.25, stop: 0.75 }  -- full bd
    , { sample: "sn", start: 0.75, stop: 1.0 }   -- head of wrapped sn
    ]

  log ""
  log "--- fastAppend ---"
  testPatternDirect "fastAppend bd sn"
    (fastAppend (pure "bd") (pure "sn"))
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

-------------------------------------------------------------------------------
-- Toussaint Euclidean Paper Examples
-- Reference: "The Euclidean Algorithm Generates Traditional Musical Rhythms"
--            by Godfried Toussaint (2005)
-------------------------------------------------------------------------------

-- | Tests for Euclidean rhythms from Toussaint's paper
runToussaintTests :: Effect Unit
runToussaintTests = do
  -- From the Tidal test suite (UITest.hs) and Toussaint's paper
  -- Note: Hit positions are 0-indexed step numbers within the total steps

  log "--- Classic Euclidean Rhythms ---"

  -- E(1,2) = [1,0] - simple half note
  testPattern "bd(1,2)"
    "E(1,2) - half"
    1
    [{ sample: "bd", start: 0.0, stop: 0.5 }]

  -- E(1,3) = [1,0,0] - dotted half note feel
  testPattern "bd(1,3)"
    "E(1,3) - dotted half"
    1
    [{ sample: "bd", start: 0.0, stop: 0.333 }]

  -- E(1,4) = [1,0,0,0] - whole note
  testPattern "bd(1,4)"
    "E(1,4) - whole"
    1
    [{ sample: "bd", start: 0.0, stop: 0.25 }]

  -- E(2,3) = [1,0,1] - triadic rhythm
  testPattern "bd(2,3)"
    "E(2,3) - triadic"
    2
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "bd", start: 0.666, stop: 1.0 }
    ]

  -- E(2,5) = [1,0,1,0,0] - Persian rhythm (khafif-e-ramal)
  testPattern "bd(2,5)"
    "E(2,5) - khafif-e-ramal"
    2
    [ { sample: "bd", start: 0.0, stop: 0.2 }
    , { sample: "bd", start: 0.4, stop: 0.6 }
    ]

  -- E(3,4) = [1,1,0,1] - hits at 0,1,3
  testPattern "bd(3,4)"
    "E(3,4) - three of four"
    3
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  -- E(3,5) = [1,0,1,0,1] - Persian rhythm (khafif-e-ramal variant)
  testPattern "bd(3,5)"
    "E(3,5) - Persian"
    3
    [ { sample: "bd", start: 0.0, stop: 0.2 }
    , { sample: "bd", start: 0.4, stop: 0.6 }
    , { sample: "bd", start: 0.8, stop: 1.0 }
    ]

  -- E(3,7) = [1,0,1,0,1,0,0] - Ruchenitza rhythm (Bulgarian)
  testPattern "bd(3,7)"
    "E(3,7) - Ruchenitza"
    3
    [ { sample: "bd", start: 0.0, stop: 0.142 }
    , { sample: "bd", start: 0.285, stop: 0.428 }
    , { sample: "bd", start: 0.571, stop: 0.714 }
    ]

  -- E(4,7) = [1,0,1,0,1,0,1] - alternating pattern
  testPattern "bd(4,7)"
    "E(4,7) - alternating 4/7"
    4
    [ { sample: "bd", start: 0.0, stop: 0.142 }
    , { sample: "bd", start: 0.285, stop: 0.428 }
    , { sample: "bd", start: 0.571, stop: 0.714 }
    , { sample: "bd", start: 0.857, stop: 1.0 }
    ]

  -- E(4,9) = [1,0,1,0,1,0,1,0,0] - Aksak rhythm (Turkey)
  testPattern "bd(4,9)"
    "E(4,9) - Aksak"
    4
    [ { sample: "bd", start: 0.0, stop: 0.111 }
    , { sample: "bd", start: 0.222, stop: 0.333 }
    , { sample: "bd", start: 0.444, stop: 0.555 }
    , { sample: "bd", start: 0.666, stop: 0.777 }
    ]

  -- E(5,6) = [1,1,1,0,1,1] - hits at 0,1,2,4,5
  testPattern "bd(5,6)"
    "E(5,6) - five of six"
    5
    [ { sample: "bd", start: 0.0, stop: 0.166 }
    , { sample: "bd", start: 0.166, stop: 0.333 }
    , { sample: "bd", start: 0.333, stop: 0.5 }
    , { sample: "bd", start: 0.666, stop: 0.833 }
    , { sample: "bd", start: 0.833, stop: 1.0 }
    ]

  -- E(5,7) = [1,0,1,1,0,1,1] - hits at 0,2,3,5,6
  testPattern "bd(5,7)"
    "E(5,7) - five of seven"
    5
    [ { sample: "bd", start: 0.0, stop: 0.142 }
    , { sample: "bd", start: 0.285, stop: 0.428 }
    , { sample: "bd", start: 0.428, stop: 0.571 }
    , { sample: "bd", start: 0.714, stop: 0.857 }
    , { sample: "bd", start: 0.857, stop: 1.0 }
    ]

  log ""
  log "--- Afro-Cuban Clave Patterns ---"

  -- E(5,8) = [1,0,1,1,0,1,1,0] - Cuban cinquillo
  testPattern "bd(5,8)"
    "E(5,8) - Cuban cinquillo"
    5
    [ { sample: "bd", start: 0.0, stop: 0.125 }
    , { sample: "bd", start: 0.25, stop: 0.375 }
    , { sample: "bd", start: 0.375, stop: 0.5 }
    , { sample: "bd", start: 0.625, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 0.875 }
    ]

  -- E(7,8) = [1,1,1,1,0,1,1,1] - seven of eight with gap at position 4
  testPattern "bd(7,8)"
    "E(7,8) - seven of eight"
    7
    [ { sample: "bd", start: 0.0, stop: 0.125 }
    , { sample: "bd", start: 0.125, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.375 }
    , { sample: "bd", start: 0.375, stop: 0.5 }
    , { sample: "bd", start: 0.625, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 0.875 }
    , { sample: "bd", start: 0.875, stop: 1.0 }
    ]

  log ""
  log "--- African Bell Patterns ---"

  -- E(7,12) = [1,0,1,1,0,1,0,1,1,0,1,0] - West African bell (12/8 feel)
  testPattern "bd(7,12)"
    "E(7,12) - West African bell"
    7
    [ { sample: "bd", start: 0.0, stop: 0.083 }
    , { sample: "bd", start: 0.166, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.333 }
    , { sample: "bd", start: 0.416, stop: 0.5 }
    , { sample: "bd", start: 0.583, stop: 0.666 }
    , { sample: "bd", start: 0.666, stop: 0.75 }
    , { sample: "bd", start: 0.833, stop: 0.916 }
    ]

  -- E(5,12) = [1,0,0,1,0,1,0,0,1,0,1,0] - Venda children's song (South Africa)
  testPattern "bd(5,12)"
    "E(5,12) - Venda"
    5
    [ { sample: "bd", start: 0.0, stop: 0.083 }
    , { sample: "bd", start: 0.25, stop: 0.333 }
    , { sample: "bd", start: 0.416, stop: 0.5 }
    , { sample: "bd", start: 0.666, stop: 0.75 }
    , { sample: "bd", start: 0.833, stop: 0.916 }
    ]

-------------------------------------------------------------------------------
-- Test helpers
-------------------------------------------------------------------------------

type ExpectedEvent =
  { sample :: String
  , start :: Number
  , stop :: Number
  }

-- | Test a Pattern directly (not through parsing)
testPatternDirect
  :: String
  -> Pattern String
  -> Rational
  -> Rational
  -> Int
  -> Array ExpectedEvent
  -> Effect Unit
testPatternDirect desc pat startTime stopTime expectedCount expectedEvents = do
  let events = queryArc pat startTime stopTime
  let actualCount = Array.length events

  -- Check count
  if actualCount /= expectedCount then do
    log $ "  ✗ " <> desc
    log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
    log $ "    Events: " <> formatEvents events
  else do
    -- Check each event
    let mismatches = findMismatches events expectedEvents
    if Array.length mismatches > 0 then do
      log $ "  ✗ " <> desc
      for_ mismatches \m -> log $ "    " <> m
      log $ "    Got: " <> formatEvents events
    else do
      log $ "  ✓ " <> desc <> ": " <> show actualCount <> " events"

-- | Test a pattern produces expected events
testPattern :: String -> String -> Int -> Array ExpectedEvent -> Effect Unit
testPattern input desc expectedCount expectedEvents = do
  let result = parseTPat input :: Either _ (TPat String)
  case result of
    Left err -> do
      log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let pat = tpatToPattern ast
      let events = queryArc pat (fromInt 0) (fromInt 1)
      let actualCount = Array.length events

      -- Check count
      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatEvents events
      else do
        -- Check each event
        let mismatches = findMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatEvents events
        else do
          log $ "  ✓ " <> desc <> " (\"" <> input <> "\"): " <> show actualCount <> " events"

-- | Format events for display
formatEvents :: Array (Event String) -> String
formatEvents events =
  "[" <> Array.intercalate ", " (map formatEvent events) <> "]"

formatEvent :: Event String -> String
formatEvent = case _ of
  Digital { value, part: Arc { start, stop } } ->
    value <> "@" <> formatTime start <> "-" <> formatTime stop
  Analog { value, part: Arc { start, stop } } ->
    value <> "~" <> formatTime start <> "-" <> formatTime stop

formatTime :: Rational -> String
formatTime r = show (roundTo3 (toNumber r))

roundTo3 :: Number -> Number
roundTo3 n = Int.toNumber (Int.round (n * 1000.0)) / 1000.0

-- | Find mismatches between actual and expected events
-- | Sorts both by start time before comparing
findMismatches :: Array (Event String) -> Array ExpectedEvent -> Array String
findMismatches actuals expecteds =
  let
    -- Sort actuals by start time
    compareEventStart a b = compare (toNumber (eventStart a)) (toNumber (eventStart b))
    sortedActuals = Array.sortBy compareEventStart actuals
    -- Sort expecteds by start time
    sortedExpecteds = Array.sortBy (\a b -> compare a.start b.start) expecteds

    checkOne idx expected =
      case Array.index sortedActuals idx of
        Nothing -> Just $ "Event " <> show idx <> ": missing"
        Just actual -> checkEvent idx actual expected
  in
    Array.mapWithIndex checkOne sortedExpecteds # Array.catMaybes
  where
    checkEvent :: Int -> Event String -> ExpectedEvent -> Maybe String
    checkEvent idx actual expected =
      let
        actualSample = eventSample actual
        actualStart = toNumber (eventStart actual)
        actualStop = toNumber (eventStop actual)
        tolerance = 0.01
      in
        if actualSample /= expected.sample then
          Just $ "Event " <> show idx <> ": sample " <> actualSample <> " ≠ " <> expected.sample
        else if abs (actualStart - expected.start) > tolerance then
          Just $ "Event " <> show idx <> ": start " <> show actualStart <> " ≠ " <> show expected.start
        else if abs (actualStop - expected.stop) > tolerance then
          Just $ "Event " <> show idx <> ": stop " <> show actualStop <> " ≠ " <> show expected.stop
        else
          Nothing

eventSample :: Event String -> String
eventSample = case _ of
  Digital { value } -> value
  Analog { value } -> value

eventStart :: Event String -> Rational
eventStart = case _ of
  Digital { part: Arc { start } } -> start
  Analog { part: Arc { start } } -> start

eventStop :: Event String -> Rational
eventStop = case _ of
  Digital { part: Arc { stop } } -> stop
  Analog { part: Arc { stop } } -> stop

abs :: Number -> Number
abs n = if n < 0.0 then -n else n
