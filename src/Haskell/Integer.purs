-- | **Haskell's `Integer`**: unbounded, with GHC's division.
-- |
-- | Part of the reference-semantics types (`Haskell.*`): where a port must
-- | agree with a Haskell library to the bit, the port names Haskell's type
-- | rather than bending PureScript's. Represented by `JS.BigInt` (the
-- | registry's `js-bigints` on JS, its purerl port on the BEAM); everything
-- | here is PureScript over that one seam.
-- |
-- | There is deliberately no `EuclideanRing` instance. PureScript's `div` and
-- | `mod` are Euclidean (the remainder is never negative); Haskell's are
-- | floored (the remainder takes the divisor's sign), and Haskell also has
-- | `quot` and `rem`, which truncate. An instance would let a generic `div`
-- | mean the wrong one silently, so all four are named functions here.
-- | Division by zero is an error, as in Haskell.
module Haskell.Integer
  ( Integer
  , fromInt
  , fromBigInt
  , toBigInt
  , toNumber
  , quot
  , rem
  , quotRem
  , div
  , mod
  , divMod
  , gcd
  , abs
  , signum
  , even
  ) where

import Prelude hiding (div, mod, gcd)

import Data.Tuple (Tuple(..), fst, snd)
import JS.BigInt (BigInt)
import JS.BigInt as BigInt
import Partial.Unsafe (unsafeCrashWith)
import Prelude as P

newtype Integer = Integer BigInt

derive newtype instance Eq Integer
derive newtype instance Ord Integer
derive newtype instance Semiring Integer
derive newtype instance Ring Integer
derive newtype instance CommutativeRing Integer

-- | Haskell's `show`: decimal, with a leading `-`.
instance Show Integer where
  show (Integer n) = BigInt.toString n

fromInt :: Int -> Integer
fromInt = Integer <<< BigInt.fromInt

fromBigInt :: BigInt -> Integer
fromBigInt = Integer

toBigInt :: Integer -> BigInt
toBigInt (Integer n) = n

-- | `fromIntegral :: Integer -> Double`: exact below 2^53, nearest above.
toNumber :: Integer -> Number
toNumber (Integer n) = BigInt.toNumber n

-- | Both divisions start from the Euclidean one the representation offers,
-- | where `a = b*q + r` and `0 <= r < |b|`.
euclid :: Integer -> Integer -> Tuple Integer Integer
euclid (Integer a) (Integer b)
  | b == zero = unsafeCrashWith "divide by zero"
  | otherwise = Tuple (Integer (P.div a b)) (Integer (P.mod a b))

-- | Truncating division: the remainder takes the dividend's sign.
quotRem :: Integer -> Integer -> Tuple Integer Integer
quotRem a b =
  let
    Tuple q r = euclid a b
  in
    if a < zero && r /= zero then Tuple (q + signum b) (r - abs b)
    else Tuple q r

-- | Floored division: the remainder takes the divisor's sign.
divMod :: Integer -> Integer -> Tuple Integer Integer
divMod a b =
  let
    Tuple q r = euclid a b
  in
    if b < zero && r /= zero then Tuple (q - one) (r + b)
    else Tuple q r

quot :: Integer -> Integer -> Integer
quot a b = fst (quotRem a b)

rem :: Integer -> Integer -> Integer
rem a b = snd (quotRem a b)

div :: Integer -> Integer -> Integer
div a b = fst (divMod a b)

mod :: Integer -> Integer -> Integer
mod a b = snd (divMod a b)

-- | Never negative; `gcd 0 0` is 0, as in Haskell.
gcd :: Integer -> Integer -> Integer
gcd a b = go (abs a) (abs b)
  where
  go x y = if y == zero then x else go y (rem x y)

abs :: Integer -> Integer
abs n = if n < zero then negate n else n

signum :: Integer -> Integer
signum n = case compare n zero of
  LT -> negate one
  EQ -> zero
  GT -> one

even :: Integer -> Boolean
even (Integer n) = BigInt.even n
