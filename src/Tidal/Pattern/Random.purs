-- | Haskell Tidal's randomness, to the bit (`Sound.Tidal.UI`, 1.10.1).
-- |
-- | Tidal's random values are a pure function of time: the cycle position
-- | is stretched over 300 cycles into 29 bits and scrambled by an xorshift
-- | (`xorwise`). Matching it exactly is what makes `?` and `|` drop and
-- | choose the same events as Tidal does.
-- |
-- | Transcribed line for line, on Haskell's own types: `xorwise` relies on
-- | Haskell's 64-bit `Int` wrapping, which PureScript's `Int` does on
-- | neither backend, and the time arithmetic on an exact `Rational`.
module Tidal.Pattern.Random
  ( timeToRand
  , timeToRandAt
  , timeToIntSeed
  , intSeedToRand
  , xorwise
  ) where

import Prelude

import Data.Rational as Data.Rational
import Data.Tuple (snd)
import Haskell.Int (shiftL, shiftR, xor)
import Haskell.Int as H
import Haskell.Integer as Integer
import Haskell.Rational (Rational, (%))
import Haskell.Rational as Rational

-- | `xorwise`: Marsaglia's xorshift on a 64-bit `Int`.
xorwise :: H.Int -> H.Int
xorwise x =
  let
    a = xor (shiftL x 13) x
    b = xor (shiftR a 17) a
  in
    xor (shiftL b 5) b

seedRange :: Int
seedRange = 536870912 -- 2^29

-- | `timeToIntSeed = xorwise . truncate . (* 536870912) . snd . properFraction . (/ 300)`
timeToIntSeed :: Rational -> H.Int
timeToIntSeed =
  xorwise
    <<< H.fromInteger
    <<< Rational.truncate
    <<< (_ * Rational.fromInt seedRange)
    <<< snd
    <<< Rational.properFraction
    <<< (_ / Rational.fromInt 300)

-- | `intSeedToRand = (/ 536870912) . realToFrac . (`mod` 536870912)`
intSeedToRand :: H.Int -> Number
intSeedToRand seed = H.toNumber (H.mod seed (H.fromInt seedRange)) / H.toNumber (H.fromInt seedRange)

-- | `timeToRand`: 0.5 at time 0, otherwise the scrambled seed of the time,
-- | in [0, 1).
timeToRand :: Rational -> Number
timeToRand t = if t == zero then 0.5 else intSeedToRand (timeToIntSeed t)

-- | `timeToRand` at a time of the engine's type, until the engine moves onto
-- | `Haskell.Rational` itself.
timeToRandAt :: Data.Rational.Rational -> Number
timeToRandAt t =
  timeToRand (Integer.fromInt (Data.Rational.numerator t) % Integer.fromInt (Data.Rational.denominator t))
