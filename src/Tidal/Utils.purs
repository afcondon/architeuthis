-- | Utility functions for pattern manipulation
-- |
-- | Based on TidalCycles' Utils module.
module Tidal.Utils
  ( -- * Tuple utilities
    delta
  , mid
  , mapBoth
  , mapFst
  , mapSnd
    -- * List utilities
  , nth
  , enumerate
  , accumulate
  , removeCommon
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

-------------------------------------------------------------------------------
-- Tuple utilities
-------------------------------------------------------------------------------

-- | Get the difference between tuple elements
-- |
-- | `delta (Tuple 3 7) = 4`
delta :: Tuple Number Number -> Number
delta (Tuple a b) = b - a

-- | Get the midpoint between tuple elements
-- |
-- | `mid (Tuple 0.0 1.0) = 0.5`
mid :: Tuple Number Number -> Number
mid (Tuple a b) = (a + b) / 2.0

-- | Apply a function to both elements of a tuple
mapBoth :: forall a b. (a -> b) -> Tuple a a -> Tuple b b
mapBoth f (Tuple a b) = Tuple (f a) (f b)

-- | Apply a function to the first element of a tuple
mapFst :: forall a b c. (a -> b) -> Tuple a c -> Tuple b c
mapFst f (Tuple a c) = Tuple (f a) c

-- | Apply a function to the second element of a tuple
mapSnd :: forall a b c. (b -> c) -> Tuple a b -> Tuple a c
mapSnd f (Tuple a b) = Tuple a (f b)

-------------------------------------------------------------------------------
-- List utilities
-------------------------------------------------------------------------------

-- | Safe indexing into an array
-- |
-- | Returns Nothing if index is out of bounds
nth :: forall a. Int -> Array a -> Maybe a
nth i arr = Array.index arr i

-- | Enumerate elements with their indices
-- |
-- | `enumerate ["a", "b"] = [Tuple 0 "a", Tuple 1 "b"]`
enumerate :: forall a. Array a -> Array (Tuple Int a)
enumerate arr = Array.mapWithIndex Tuple arr

-- | Running accumulation with a binary function
-- |
-- | `accumulate (+) [1, 2, 3, 4] = [1, 3, 6, 10]`
accumulate :: forall a. (a -> a -> a) -> Array a -> Array a
accumulate f arr = case Array.uncons arr of
  Nothing -> []
  Just { head, tail } ->
    let go acc prev rest = case Array.uncons rest of
          Nothing -> acc
          Just { head: h, tail: t } ->
            let next = f prev h
            in go (acc <> [next]) next t
    in [head] <> go [] head tail

-- | Remove elements that appear in both arrays
-- |
-- | Returns elements unique to the first array
removeCommon :: forall a. Eq a => Array a -> Array a -> Array a
removeCommon xs ys = Array.filter (\x -> not (Array.elem x ys)) xs
