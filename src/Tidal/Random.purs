-- | Small Pattern-level random helpers.
-- |
-- | We already have `rand :: Pattern Number` and `irand :: Int ->
-- | Pattern Int` in `Tidal.Pattern.Core`.  This module adds the
-- | small composition helpers a cell typically wants — most
-- | importantly `pickFromPool`, which indexes an array by a
-- | Pattern Int.
-- |
-- | Composition style: `pickFromPool` over `irand` over `segment`
-- | gives a stream of random selections from a fixed pool, e.g.
-- |
-- | ```purescript
-- | melody = pickFromPool [c4, e4, g4, a4]
-- |        $ segment 8
-- |        $ irand 4
-- | ```
-- |
-- | reads as: "8 events per cycle, each a random index 0..3, looked
-- | up in the [c4, e4, g4, a4] pool."  Tidal's `<$>`/`apply`
-- | machinery does most of the work; this module is mostly
-- | naming-conventions over what already exists.
module Tidal.Random
  ( pickFromPool
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Tidal.Pattern.Types (Pattern, silence)

-- | Index an array by a Pattern Int, wrapping out-of-range indices
-- | modulo the pool length.  When the pool is empty, returns
-- | `silence` (no events).
-- |
-- | The wrap-around (`mod`) means callers don't have to constrain
-- | the input pattern's range to `[0, length-1]` — `irand 100`
-- | applied to a 4-element pool just maps onto positions 0..3
-- | uniformly enough for musical purposes.
pickFromPool :: forall a. Array a -> Pattern Int -> Pattern a
pickFromPool pool patIdx = case Array.head pool of
  Nothing -> silence
  Just first ->
    let len = Array.length pool
    in map (lookupAt first len pool) patIdx
  where
    lookupAt :: a -> Int -> Array a -> Int -> a
    lookupAt fallback len arr i =
      let
        wrapped = ((i `mod` len) + len) `mod` len
      in
        fromMaybe fallback (Array.index arr wrapped)
