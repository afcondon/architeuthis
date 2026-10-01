-- | **Run the conformance suite on whichever backend compiled it.**
-- |
-- | `main` is the entry point of every column (`engine/columns/*`); purerl-
-- | tidal's own test suite calls `runConformance` too. A difference prints
-- | both answers and fails the run, since parity reached 100% (2026-10-01).
module Tidal.Conformance.Main
  ( main
  , runConformance
  ) where

import Prelude

import Data.Array (filter, length)
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Tidal.Conformance (Result, haskell, tidal, tidalVersion)

main :: Effect Unit
main = runConformance

runConformance :: Effect Unit
runConformance = do
  h <- report "Haskell.* against GHC" haskell
  log ("  " <> show h <> " of " <> show (length haskell) <> " cases identical to GHC")
  t <- report ("Parity with Haskell Tidal " <> tidalVersion) tidal
  log ("  parity: " <> show t <> " of " <> show (length tidal) <> " cases identical to Tidal " <> tidalVersion)
  let failed = (length haskell - h) + (length tidal - t)
  when (failed > 0) $ throw (show failed <> " case(s) differ from the reference")

report :: String -> Array Result -> Effect Int
report title results = do
  log ""
  log "=========================================="
  log ("  " <> title)
  log "=========================================="
  log ""
  let diffs = filter (\r -> r.expected /= r.actual) results
  for_ diffs \r -> do
    log ("  DIFF  " <> r.input)
    log ("        reference: " <> r.expected)
    log ("        ours:      " <> r.actual)
  pure (length results - length diffs)
