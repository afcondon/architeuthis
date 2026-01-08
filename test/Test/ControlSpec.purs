-- | Control pattern tests
-- |
-- | Tests the control parameter system for synthesis parameters.
module Test.ControlSpec where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt, (%))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Controls (Value(..), ValueMap, ControlPattern, sound, gain, pan, speed, note, n, pS, pF, pI, pN, (#), (|>), (|>|), (|+), (|-), (|*), (|/), getS, getF, getI, getN, merge)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), Event(..), arcStart, arcStop)

-------------------------------------------------------------------------------
-- Test runner
-------------------------------------------------------------------------------

-- | Run all control tests
runControlTests :: Effect Unit
runControlTests = do
  log ""
  log "=========================================="
  log "  Control Pattern Tests"
  log "=========================================="
  log ""

  -- Basic controls
  log "--- Basic Controls ---"

  testControl "sound"
    (sound (pure "bd"))
    1
    [ { key: "sound", expectedValue: VS "bd" } ]

  testControl "gain"
    (gain (pure 0.8))
    1
    [ { key: "gain", expectedValue: VF 0.8 } ]

  testControl "pan"
    (pan (pure 0.5))
    1
    [ { key: "pan", expectedValue: VF 0.5 } ]

  testControl "speed"
    (speed (pure 2.0))
    1
    [ { key: "speed", expectedValue: VF 2.0 } ]

  testControl "note"
    (note (pure 60.0))
    1
    [ { key: "note", expectedValue: VN 60.0 } ]

  -- Merge operator (#)
  log ""
  log "--- Merge Operator (#) ---"

  testControl "sound # gain"
    (sound (pure "bd") # gain (pure 0.8))
    1
    [ { key: "sound", expectedValue: VS "bd" }
    , { key: "gain", expectedValue: VF 0.8 }
    ]

  testControl "sound # gain # pan"
    (sound (pure "sn") # gain (pure 0.6) # pan (pure 0.25))
    1
    [ { key: "sound", expectedValue: VS "sn" }
    , { key: "gain", expectedValue: VF 0.6 }
    , { key: "pan", expectedValue: VF 0.25 }
    ]

  testControl "sound # speed # note"
    (sound (pure "pluck") # speed (pure 1.5) # note (pure 48.0))
    1
    [ { key: "sound", expectedValue: VS "pluck" }
    , { key: "speed", expectedValue: VF 1.5 }
    , { key: "note", expectedValue: VN 48.0 }
    ]

  -- Arithmetic merges
  log ""
  log "--- Arithmetic Merge Operators ---"

  testControl "gain |+ gain (addition)"
    (gain (pure 0.5) |+ gain (pure 0.3))
    1
    [ { key: "gain", expectedValue: VF 0.8 } ]

  testControl "gain |- gain (subtraction)"
    (gain (pure 1.0) |- gain (pure 0.5))
    1
    [ { key: "gain", expectedValue: VF 0.5 } ]

  testControl "speed |* speed (multiplication)"
    (speed (pure 2.0) |* speed (pure 1.5))
    1
    [ { key: "speed", expectedValue: VF 3.0 } ]

  testControl "speed |/ speed (division)"
    (speed (pure 4.0) |/ speed (pure 2.0))
    1
    [ { key: "speed", expectedValue: VF 2.0 } ]

  -- Value extraction
  log ""
  log "--- Value Extraction ---"

  testGetS

  testGetF

  testGetI

  testGetN

  log ""
  log "  Control tests complete."

-------------------------------------------------------------------------------
-- Test helpers
-------------------------------------------------------------------------------

type ExpectedControl = { key :: String, expectedValue :: Value }

-- | Test a control pattern over one cycle
testControl :: String -> ControlPattern -> Int -> Array ExpectedControl -> Effect Unit
testControl desc pat expectedCount expectedControls = do
  let events = queryArc pat (fromInt 0) (fromInt 1)
  let actualCount = Array.length events
  if actualCount /= expectedCount then do
    log $ "  ✗ " <> desc
    log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
  else case Array.head events of
    Nothing -> log $ "  ✗ " <> desc <> ": no events"
    Just event ->
      let
        valueMap = eventValue event
        mismatches = Array.mapMaybe (checkControl valueMap) expectedControls
      in
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc
          for_ mismatches \m -> log $ "    " <> m
        else
          log $ "  ✓ " <> desc
  where
    eventValue :: Event ValueMap -> ValueMap
    eventValue (Digital e) = e.value
    eventValue (Analog e) = e.value

    checkControl :: ValueMap -> ExpectedControl -> Maybe String
    checkControl vm { key, expectedValue } =
      case Map.lookup key vm of
        Nothing -> Just $ "Missing key: " <> key
        Just actual ->
          if actual == expectedValue then Nothing
          else Just $ "Key " <> key <> ": expected " <> show expectedValue <> ", got " <> show actual

-- | Test getS
testGetS :: Effect Unit
testGetS = do
  let vm = Map.singleton "sound" (VS "bd")
  case getS "sound" vm of
    Just "bd" -> log "  ✓ getS extracts string value"
    _ -> log "  ✗ getS extracts string value"

  case getS "missing" vm of
    Nothing -> log "  ✓ getS returns Nothing for missing key"
    _ -> log "  ✗ getS returns Nothing for missing key"

-- | Test getF
testGetF :: Effect Unit
testGetF = do
  let vm = Map.singleton "gain" (VF 0.8)
  case getF "gain" vm of
    Just 0.8 -> log "  ✓ getF extracts float value"
    _ -> log "  ✗ getF extracts float value"

-- | Test getI
testGetI :: Effect Unit
testGetI = do
  let vm = Map.singleton "cut" (VI 1)
  case getI "cut" vm of
    Just 1 -> log "  ✓ getI extracts int value"
    _ -> log "  ✗ getI extracts int value"

-- | Test getN
testGetN :: Effect Unit
testGetN = do
  let vm = Map.singleton "note" (VN 60.0)
  case getN "note" vm of
    Just 60.0 -> log "  ✓ getN extracts note value"
    _ -> log "  ✗ getN extracts note value"
