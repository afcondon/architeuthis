-- | **Haskell's `Int`**: 64 bits, two's complement, wrapping on overflow.
-- |
-- | GHC's `Int` on every platform we use. PureScript's `Int` is neither: 32
-- | bits on JS and unbounded on the BEAM, so code that relies on Haskell's
-- | wrap (Tidal's `xorwise`, which decides every `?`, `|` and `rand`) gets a
-- | different answer on each backend. This type gets GHC's answer on both.
-- |
-- | An `Integer` underneath, brought back into range after every operation
-- | that can leave it (`asIntN 64`). `fromInteger` wraps, as Haskell's
-- | `fromIntegral :: Integer -> Int` does. The divisions are named, as in
-- | `Haskell.Integer`, and the shifts are Haskell's: `shiftR` keeps the sign.
module Haskell.Int
  ( Int
  , fromInt
  , fromInteger
  , toInteger
  , toNumber
  , minBound
  , maxBound
  , quot
  , rem
  , div
  , mod
  , shiftL
  , shiftR
  , xor
  , (.&.)
  , (.|.)
  , and
  , or
  ) where

import Prelude hiding (div, mod)

import Haskell.Integer (Integer)
import Haskell.Integer as Integer
import JS.BigInt as BigInt
import Partial.Unsafe (unsafeCrashWith)
import Prim hiding (Int)
import Prim as Prim

newtype Int = Int Integer

derive newtype instance Eq Int
derive newtype instance Ord Int

instance Show Int where
  show (Int n) = show n

-- | Into range: the low 64 bits, read as two's complement.
wrap :: Integer -> Int
wrap = Int <<< Integer.fromBigInt <<< BigInt.asIntN 64 <<< Integer.toBigInt

lift2 :: (Integer -> Integer -> Integer) -> Int -> Int -> Int
lift2 f (Int a) (Int b) = wrap (f a b)

instance Semiring Int where
  add = lift2 add
  mul = lift2 mul
  zero = Int zero
  one = Int one

instance Ring Int where
  sub = lift2 sub

instance CommutativeRing Int

fromInt :: Prim.Int -> Int
fromInt = Int <<< Integer.fromInt

-- | `fromIntegral :: Integer -> Int`: the low 64 bits.
fromInteger :: Integer -> Int
fromInteger = wrap

toInteger :: Int -> Integer
toInteger (Int n) = n

-- | `fromIntegral :: Int -> Double`.
toNumber :: Int -> Number
toNumber (Int n) = Integer.toNumber n

minBound :: Int
minBound = negate (Int (Integer.fromBigInt (BigInt.pow (BigInt.fromInt 2) (BigInt.fromInt 63))))

maxBound :: Int
maxBound = Int (Integer.fromBigInt (BigInt.pow (BigInt.fromInt 2) (BigInt.fromInt 63) - one))

-- | Haskell raises on `minBound` divided by -1 rather than wrapping.
divide :: (Integer -> Integer -> Integer) -> Int -> Int -> Int
divide f a b
  | a == minBound && b == negate one = unsafeCrashWith "arithmetic overflow"
  | otherwise = lift2 f a b

quot :: Int -> Int -> Int
quot = divide Integer.quot

rem :: Int -> Int -> Int
rem a b = if b == negate one then zero else lift2 Integer.rem a b

div :: Int -> Int -> Int
div = divide Integer.div

mod :: Int -> Int -> Int
mod a b = if b == negate one then zero else lift2 Integer.mod a b

-- | Bits shifted past the top are lost; a shift of 64 or more gives 0.
shiftL :: Int -> Prim.Int -> Int
shiftL (Int a) n = wrap (Integer.fromBigInt (BigInt.shl (Integer.toBigInt a) (BigInt.fromInt n)))

-- | Arithmetic: copies of the sign bit come in from the left.
shiftR :: Int -> Prim.Int -> Int
shiftR (Int a) n = Int (Integer.fromBigInt (BigInt.shr (Integer.toBigInt a) (BigInt.fromInt n)))

bits :: (BigInt.BigInt -> BigInt.BigInt -> BigInt.BigInt) -> Int -> Int -> Int
bits f (Int a) (Int b) = Int (Integer.fromBigInt (f (Integer.toBigInt a) (Integer.toBigInt b)))

xor :: Int -> Int -> Int
xor = bits BigInt.xor

and :: Int -> Int -> Int
and = bits BigInt.and

or :: Int -> Int -> Int
or = bits BigInt.or

infixl 7 and as .&.
infixl 5 or as .|.
