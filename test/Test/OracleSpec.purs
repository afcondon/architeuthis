-- | **purerl-tidal against Haskell Tidal: the parity score.**
-- |
-- | Every case in `Test.Oracle.Golden` was rendered by GHCi running Tidal
-- | (test/oracle/generate.mjs, from test/oracle/corpus.txt: Tidal's own
-- | ParseTest cases first, then ours). Each is read here as a line, queried
-- | over the same arc and rendered the same way; the event lists must be
-- | equal, fragments and all, in any order. A case Tidal refused must be
-- | refused here too. Since parity reached 100% (2026-10-01), a difference
-- | fails the run.
module Test.OracleSpec (runOracleTests) where

import Prelude

import Data.Array (filter, length, sort)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Haskell.Rational (fromInt)
import Data.Traversable (for)
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Test.ControlSpec (render)
import Test.Oracle.Golden (golden, tidalVersion)
import Tidal.Line (Command(..), parseLine)
import Tidal.Pattern.Core (queryArc)

runOracleTests :: Effect Unit
runOracleTests = do
  log ""
  log "=========================================="
  log ("  Parity with Haskell Tidal " <> tidalVersion)
  log "=========================================="
  log ""
  results <- for golden \g -> do
    let
      ours = case parseLine ("d1 $ " <> g.expr) of
        Right (Play _ p) -> Just (sort (map render (queryArc p (fromInt g.from) (fromInt g.to))))
        _ -> Nothing
      theirs = map sort g.events
    if ours == theirs then pure true
    else do
      log ("  DIFF " <> g.expr <> "  over " <> show g.from <> ".." <> show g.to)
      log ("       ours   " <> maybe' ours)
      log ("       Tidal  " <> maybe' theirs)
      pure false
  let passed = length (filter identity results)
  log ""
  log ("  parity: " <> show passed <> " of " <> show (length results) <> " cases identical to Tidal " <> tidalVersion)
  -- Parity reached 100% on 2026-10-01; any divergence now fails the run.
  when (passed < length results) $
    throw (show (length results - passed) <> " case(s) differ from Tidal " <> tidalVersion)
  where
  maybe' = case _ of
    Nothing -> "refused"
    Just evs -> show evs
