-- | **Haskell's `Rational`**: `Ratio Integer`, exact, as `Data.Ratio` has it.
-- |
-- | Always reduced, with the sign in the numerator. The rounding functions
-- | are GHC's definitions, including the two that surprise people:
-- | `truncate` goes towards zero (via `properFraction`), and `round` sends a
-- | half to the even neighbour (`round (5 % 2)` is 2).
-- |
-- | `%` takes `Int`s, because a PureScript literal is one: `1 % 4` reads as
-- | it does in Tidal's source, where the literals default to `Integer`. The
-- | value is exact either way; `ratio` takes `Integer`s.
-- |
-- | `toNumber` is `fromRational :: Rational -> Double`. It is exact to
-- | GHC's correctly-rounded result whenever numerator and denominator are
-- | below 2^53, which covers Tidal's time; beyond that it may differ in the
-- | last bit.
module Haskell.Rational
  ( Rational
  , ratio
  , ratioInt
  , (%)
  , numerator
  , denominator
  , fromInt
  , fromInteger
  , toNumber
  , properFraction
  , truncate
  , floor
  , ceiling
  , round
  ) where

import Prelude

import Data.Tuple (Tuple(..), fst)
import Haskell.Integer (Integer)
import Haskell.Integer as Integer
import Partial.Unsafe (unsafeCrashWith)

data Rational = Rational Integer Integer

derive instance Eq Rational

instance Ord Rational where
  compare (Rational a b) (Rational c d) = compare (a * d) (c * b)

-- | Haskell's `show`: `3 % 2`, and `(-3) % 2` for a negative.
instance Show Rational where
  show (Rational n d) =
    (if n < zero then "(" <> show n <> ")" else show n) <> " % " <> show d

-- | Haskell's `%`: reduced, the sign moved to the numerator. A zero
-- | denominator is an error, as in Haskell.
ratio :: Integer -> Integer -> Rational
ratio n d
  | d == zero = unsafeCrashWith "Ratio has zero denominator"
  | otherwise =
      let
        g = Integer.gcd n d
        s = Integer.signum d
      in
        Rational (s * Integer.quot n g) (s * Integer.quot d g)

-- | `%` at the type of PureScript's literals.
ratioInt :: Int -> Int -> Rational
ratioInt n d = ratio (Integer.fromInt n) (Integer.fromInt d)

infixl 7 ratioInt as %

numerator :: Rational -> Integer
numerator (Rational n _) = n

denominator :: Rational -> Integer
denominator (Rational _ d) = d

fromInteger :: Integer -> Rational
fromInteger n = Rational n one

fromInt :: Int -> Rational
fromInt = fromInteger <<< Integer.fromInt

toNumber :: Rational -> Number
toNumber (Rational n d) = Integer.toNumber n / Integer.toNumber d

instance Semiring Rational where
  add (Rational a b) (Rational c d) = ratio (a * d + c * b) (b * d)
  mul (Rational a b) (Rational c d) = ratio (a * c) (b * d)
  zero = Rational zero one
  one = Rational one one

instance Ring Rational where
  sub (Rational a b) (Rational c d) = ratio (a * d - c * b) (b * d)

instance CommutativeRing Rational

instance DivisionRing Rational where
  recip (Rational n d) = ratio d n

-- | A field: `/` is exact division, and nothing is left over.
instance EuclideanRing Rational where
  degree _ = 1
  div a b = a * recip b
  mod _ _ = zero

-- | GHC's `properFraction`: the whole part truncated towards zero, and a
-- | fraction with the same sign as the input.
properFraction :: Rational -> Tuple Integer Rational
properFraction (Rational n d) =
  let
    Tuple q r = Integer.quotRem n d
  in
    Tuple q (Rational r d)

truncate :: Rational -> Integer
truncate = fst <<< properFraction

floor :: Rational -> Integer
floor x =
  let
    Tuple n r = properFraction x
  in
    if r < zero then n - one else n

ceiling :: Rational -> Integer
ceiling x =
  let
    Tuple n r = properFraction x
  in
    if r > zero then n + one else n

-- | Banker's rounding, as GHC's `round`.
round :: Rational -> Integer
round x =
  let
    Tuple n r = properFraction x
    m = if r < zero then n - one else n + one
    half = Rational one (Integer.fromInt 2)
    absR = if r < zero then negate r else r
  in
    case compare absR half of
      LT -> n
      EQ -> if Integer.even n then n else m
      GT -> m
