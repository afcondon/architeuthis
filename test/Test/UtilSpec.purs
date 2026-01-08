-- | Tests for utility functions
module Test.UtilSpec where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Utils (delta, mid, mapBoth, mapFst, mapSnd, nth, enumerate, accumulate, removeCommon)

-- | Run all utility tests
runUtilTests :: Effect Unit
runUtilTests = do
  log ""
  log "=========================================="
  log "  Utility Function Tests"
  log "=========================================="
  log ""

  log "--- Tuple Utilities ---"

  -- delta
  if delta (Tuple 3.0 7.0) == 4.0 then
    log "  ✓ delta (3, 7) = 4"
  else
    log "  ✗ delta (3, 7) = 4"

  if delta (Tuple 0.0 1.0) == 1.0 then
    log "  ✓ delta (0, 1) = 1"
  else
    log "  ✗ delta (0, 1) = 1"

  -- mid
  if mid (Tuple 0.0 1.0) == 0.5 then
    log "  ✓ mid (0, 1) = 0.5"
  else
    log "  ✗ mid (0, 1) = 0.5"

  if mid (Tuple 2.0 4.0) == 3.0 then
    log "  ✓ mid (2, 4) = 3"
  else
    log "  ✗ mid (2, 4) = 3"

  -- mapBoth
  if mapBoth (_ + 1) (Tuple 1 2) == Tuple 2 3 then
    log "  ✓ mapBoth (+1) (1, 2) = (2, 3)"
  else
    log "  ✗ mapBoth (+1) (1, 2) = (2, 3)"

  -- mapFst
  if mapFst (_ * 2) (Tuple 3 4) == Tuple 6 4 then
    log "  ✓ mapFst (*2) (3, 4) = (6, 4)"
  else
    log "  ✗ mapFst (*2) (3, 4) = (6, 4)"

  -- mapSnd
  if mapSnd (_ * 2) (Tuple 3 4) == Tuple 3 8 then
    log "  ✓ mapSnd (*2) (3, 4) = (3, 8)"
  else
    log "  ✗ mapSnd (*2) (3, 4) = (3, 8)"

  log ""
  log "--- List Utilities ---"

  -- nth
  if nth 0 [1, 2, 3] == Just 1 then
    log "  ✓ nth 0 [1,2,3] = Just 1"
  else
    log "  ✗ nth 0 [1,2,3] = Just 1"

  if nth 2 [1, 2, 3] == Just 3 then
    log "  ✓ nth 2 [1,2,3] = Just 3"
  else
    log "  ✗ nth 2 [1,2,3] = Just 3"

  if nth 5 [1, 2, 3] == Nothing then
    log "  ✓ nth 5 [1,2,3] = Nothing"
  else
    log "  ✗ nth 5 [1,2,3] = Nothing"

  -- enumerate
  if enumerate ["a", "b", "c"] == [Tuple 0 "a", Tuple 1 "b", Tuple 2 "c"] then
    log "  ✓ enumerate [a,b,c]"
  else
    log "  ✗ enumerate [a,b,c]"

  -- accumulate
  if accumulate (+) [1, 2, 3, 4] == [1, 3, 6, 10] then
    log "  ✓ accumulate (+) [1,2,3,4] = [1,3,6,10]"
  else
    log "  ✗ accumulate (+) [1,2,3,4] = [1,3,6,10]"

  -- removeCommon
  if removeCommon [1, 2, 3, 4] [2, 4] == [1, 3] then
    log "  ✓ removeCommon [1,2,3,4] [2,4] = [1,3]"
  else
    log "  ✗ removeCommon [1,2,3,4] [2,4] = [1,3]"

  if removeCommon [1, 2] [3, 4] == [1, 2] then
    log "  ✓ removeCommon [1,2] [3,4] = [1,2]"
  else
    log "  ✗ removeCommon [1,2] [3,4] = [1,2]"

  log ""
  log "  Utility tests complete."
