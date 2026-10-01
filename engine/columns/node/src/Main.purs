-- | This column's entry point: the engine's conformance suite, on this
-- | column's backend. Identical in every column; only the recipe differs.
module Main (main) where

import Prelude

import Effect (Effect)
import Tidal.Conformance.Main as Conformance

main :: Effect Unit
main = Conformance.main
