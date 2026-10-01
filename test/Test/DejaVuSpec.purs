-- | Tests for Tidal.DejaVu, Tidal.LiveControl, Tidal.Random.
-- |
-- | These three modules form the smallest end-to-end loop for the
-- | "live-controlled DEJA VU" PoC: a knob (LiveControl) feeds a
-- | probability into a buffered random source (DejaVu) over a note
-- | pool (Random.pickFromPool).
-- |
-- | The hard tests here are the *invariants* of DEJA VU:
-- |
-- |   - At lockProb = 0, the output equals the inner pattern's
-- |     output for every event.
-- |   - At lockProb = 1, the output is stable across cycles —
-- |     i.e. cycle N's values equal cycle 0's values for the same
-- |     slot positions.
-- |
-- | If both invariants hold, the intermediate values
-- | (lockProb = 0.3, 0.7, …) are by construction a stochastic
-- | mixture of the two extremes.
module Test.DejaVuSpec where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Haskell.Rational (fromInt)
import Effect (Effect)
import Effect.Console (log)
import Tidal.DejaVu (dejaVu)
import Tidal.LiveControl (live, liveOr)
import Tidal.Pattern.Core (irand, segment)
import Tidal.Pattern.Types
  (Arc(..), Event(..), Pattern, State(..), Value(..)
  , eventValue, mkArc, mkState, query)
import Tidal.Random (pickFromPool)

-------------------------------------------------------------------------------
-- Test runner
-------------------------------------------------------------------------------

runDejaVuTests :: Effect Unit
runDejaVuTests = do
  log ""
  log "=========================================="
  log "  DejaVu / LiveControl / Random Tests"
  log "=========================================="
  log ""

  testLiveReturnsControlValue
  testLiveDefaultsToZeroWhenAbsent
  testLiveOrUsesProvidedDefault
  testLiveAcceptsIntControlAsNumber

  log ""
  log "--- pickFromPool ---"
  testPickFromPoolBasic
  testPickFromPoolWraps
  testPickFromPoolEmptyPoolIsSilent

  log ""
  log "--- dejaVu invariants ---"
  testLockZeroPassesThrough
  testLockOneStableAcrossCycles
  testLockOneRespectsSeed

-------------------------------------------------------------------------------
-- LiveControl tests
-------------------------------------------------------------------------------

testLiveReturnsControlValue :: Effect Unit
testLiveReturnsControlValue = do
  let
    st = State
      { arc: mkArc (fromInt 0) (fromInt 1)
      , controls: Map.singleton "knob" (VNumber 0.42)
      }
    events = query (live "knob") st
  case Array.head events of
    Just ev | eventValue ev == 0.42 ->
      log "  ✓ live reads named control value (got 0.42)"
    Just ev ->
      log $ "  ✗ live: expected 0.42, got " <> show (eventValue ev)
    Nothing ->
      log "  ✗ live: no events emitted"

testLiveDefaultsToZeroWhenAbsent :: Effect Unit
testLiveDefaultsToZeroWhenAbsent = do
  let
    st = State
      { arc: mkArc (fromInt 0) (fromInt 1)
      , controls: Map.empty
      }
    events = query (live "missing") st
  case Array.head events of
    Just ev | eventValue ev == 0.0 ->
      log "  ✓ live defaults to 0.0 when control is absent"
    Just ev ->
      log $ "  ✗ live missing-key: expected 0.0, got " <> show (eventValue ev)
    Nothing ->
      log "  ✗ live missing-key: no events emitted"

testLiveOrUsesProvidedDefault :: Effect Unit
testLiveOrUsesProvidedDefault = do
  let
    st = State
      { arc: mkArc (fromInt 0) (fromInt 1)
      , controls: Map.empty
      }
    events = query (liveOr 0.5 "missing") st
  case Array.head events of
    Just ev | eventValue ev == 0.5 ->
      log "  ✓ liveOr uses caller-supplied default"
    Just ev ->
      log $ "  ✗ liveOr: expected 0.5, got " <> show (eventValue ev)
    Nothing ->
      log "  ✗ liveOr: no events emitted"

testLiveAcceptsIntControlAsNumber :: Effect Unit
testLiveAcceptsIntControlAsNumber = do
  let
    st = State
      { arc: mkArc (fromInt 0) (fromInt 1)
      , controls: Map.singleton "i" (VInt 7)
      }
    events = query (live "i") st
  case Array.head events of
    Just ev | eventValue ev == 7.0 ->
      log "  ✓ live accepts VInt and returns 7.0"
    Just ev ->
      log $ "  ✗ live VInt: expected 7.0, got " <> show (eventValue ev)
    Nothing ->
      log "  ✗ live VInt: no events emitted"

-------------------------------------------------------------------------------
-- pickFromPool tests
-------------------------------------------------------------------------------

testPickFromPoolBasic :: Effect Unit
testPickFromPoolBasic = do
  -- A constant pattern of Int 2 indexed into a 4-element pool of strings
  -- should give "c" (the third element).
  let
    pool = ["a", "b", "c", "d"]
    pat = pickFromPool pool (pure 2)
    events = query pat (mkState (mkArc (fromInt 0) (fromInt 1)))
  case Array.head events of
    Just ev | eventValue ev == "c" ->
      log "  ✓ pickFromPool indexes the pool correctly"
    Just ev ->
      log $ "  ✗ pickFromPool: expected \"c\", got " <> show (eventValue ev)
    Nothing ->
      log "  ✗ pickFromPool: no events emitted"

testPickFromPoolWraps :: Effect Unit
testPickFromPoolWraps = do
  -- Index 6 into a 4-element pool wraps to 6 mod 4 = 2 → "c".
  let
    pool = ["a", "b", "c", "d"]
    pat = pickFromPool pool (pure 6)
    events = query pat (mkState (mkArc (fromInt 0) (fromInt 1)))
  case Array.head events of
    Just ev | eventValue ev == "c" ->
      log "  ✓ pickFromPool wraps indices modulo pool length"
    Just ev ->
      log $ "  ✗ pickFromPool wrap: expected \"c\", got " <> show (eventValue ev)
    Nothing ->
      log "  ✗ pickFromPool wrap: no events emitted"

testPickFromPoolEmptyPoolIsSilent :: Effect Unit
testPickFromPoolEmptyPoolIsSilent = do
  let
    pool = [] :: Array String
    pat = pickFromPool pool (pure 0)
    events = query pat (mkState (mkArc (fromInt 0) (fromInt 1)))
  case Array.length events of
    0 -> log "  ✓ pickFromPool over empty pool is silent"
    n -> log $ "  ✗ pickFromPool empty: expected 0 events, got " <> show n

-------------------------------------------------------------------------------
-- DejaVu invariants
-------------------------------------------------------------------------------

testLockZeroPassesThrough :: Effect Unit
testLockZeroPassesThrough = do
  -- At lockProb = 0, dejaVu should never replace any event's value;
  -- the output should equal the inner pattern's output exactly.
  let
    inner = segment 4 (irand 10)
    pat = dejaVu { length: 4, lockProb: pure 0.0, seed: 0 } inner
    qSt = mkState (mkArc (fromInt 0) (fromInt 1))
    valuesPat = map eventValue (query pat qSt)
    valuesInner = map eventValue (query inner qSt)
  if valuesPat == valuesInner
    then log "  ✓ dejaVu lockProb=0 passes inner values through"
    else log $ "  ✗ dejaVu lockProb=0: pat=" <> show valuesPat
            <> " inner=" <> show valuesInner

testLockOneStableAcrossCycles :: Effect Unit
testLockOneStableAcrossCycles = do
  -- At lockProb = 1, every event is replaced by the buffered slot
  -- value.  Querying cycle 0 and cycle 1 should produce the same
  -- sequence of values (modulo the per-event onset).
  let
    inner = segment 4 (irand 10)
    pat = dejaVu { length: 4, lockProb: pure 1.0, seed: 0 } inner
    valuesAt n =
      let from = fromInt n
          to   = fromInt (n + 1)
      in map eventValue (query pat (mkState (mkArc from to)))
    cycle0 = valuesAt 0
    cycle1 = valuesAt 1
    cycle3 = valuesAt 3
  if cycle0 == cycle1 && cycle1 == cycle3
    then log $ "  ✓ dejaVu lockProb=1 is stable across cycles "
            <> "(values=" <> show cycle0 <> ")"
    else log $ "  ✗ dejaVu lockProb=1 not stable: c0=" <> show cycle0
            <> " c1=" <> show cycle1 <> " c3=" <> show cycle3

testLockOneRespectsSeed :: Effect Unit
testLockOneRespectsSeed = do
  -- Different seeds should give different locked loops (the seed
  -- selects which cycle of the inner pattern is sampled to fill
  -- the buffer).  At a minimum, seeds 0 and 5 should not produce
  -- identical output.
  let
    inner = segment 4 (irand 100)
    patSeed n = dejaVu { length: 4, lockProb: pure 1.0, seed: n } inner
    qSt = mkState (mkArc (fromInt 0) (fromInt 1))
    vals0 = map eventValue (query (patSeed 0) qSt)
    vals5 = map eventValue (query (patSeed 5) qSt)
  if vals0 /= vals5
    then log "  ✓ dejaVu seed selects a different locked loop"
    else log $ "  ✗ dejaVu seeds 0 and 5 gave identical loops "
            <> "(both " <> show vals0 <> ")"
