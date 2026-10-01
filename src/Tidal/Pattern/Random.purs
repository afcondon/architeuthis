-- | Haskell Tidal's randomness, to the bit (`Sound.Tidal.UI`, 1.10.1).
-- |
-- | Tidal's random values are a pure function of time: the cycle position
-- | is folded into 29 bits and scrambled by an xorshift (`xorwise`). Matching
-- | it exactly is what makes `?` and `|` drop and choose the same events as
-- | Tidal does. The arithmetic is in Erlang because it needs 64-bit
-- | integers, which PureScript's Int is not.
module Tidal.Pattern.Random
  ( timeToRand
  ) where

import Data.Rational (Rational, denominator, numerator)

foreign import timeToRandImpl :: Int -> Int -> Number

-- | `timeToRand`: 0.5 at time 0, otherwise the scrambled seed of the time,
-- | as a Number in [0, 1).
timeToRand :: Rational -> Number
timeToRand t = timeToRandImpl (numerator t) (denominator t)
