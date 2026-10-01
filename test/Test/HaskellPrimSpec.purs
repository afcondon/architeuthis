-- | **The reference-semantics types against GHC.**
-- |
-- | Every case in `Test.Oracle.HaskellPrimGolden` was computed by GHC, and
-- | the randomness cases by Tidal's own `Sound.Tidal.UI`
-- | (test/oracle/haskell-prim.hs, from test/oracle/haskell-prim.txt). Each is
-- | computed here with `Haskell.Integer`, `Haskell.Int` and
-- | `Haskell.Rational` and printed as Haskell's `show` prints it; the two
-- | strings must be equal. A difference fails the run.
module Test.HaskellPrimSpec (runHaskellPrimTests) where

import Prelude

import Data.Array (filter, length)
import Data.Maybe (Maybe(..), maybe)
import Data.String (Pattern(..), split)
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Haskell.Int as H
import Haskell.Integer (Integer)
import Haskell.Integer as Integer
import Haskell.Rational (Rational, (%))
import Haskell.Rational as Rational
import JS.BigInt as BigInt
import Test.Oracle.HaskellPrimGolden (golden)
import Tidal.Pattern.Random (timeToIntSeed, timeToRand, xorwise)

integer :: String -> Maybe Integer
integer = map Integer.fromBigInt <<< BigInt.fromString

int :: String -> Maybe H.Int
int = map H.fromInteger <<< integer

rational :: String -> Maybe Rational
rational s = case split (Pattern "/") s of
  [ n, d ] -> (%) <$> integer n <*> integer d
  _ -> Nothing

smallInt :: String -> Maybe Int
smallInt = integer >=> (BigInt.toInt <<< Integer.toBigInt)

pair :: forall a b. Show a => Show b => Tuple a b -> String
pair (Tuple a b) = "(" <> show a <> "," <> show b <> ")"

eval :: Array String -> Maybe String
eval = case _ of
  [ "quotRem", a, b ] -> pair <$> (Integer.quotRem <$> integer a <*> integer b)
  [ "divMod", a, b ] -> pair <$> (Integer.divMod <$> integer a <*> integer b)
  [ "gcd", a, b ] -> show <$> (Integer.gcd <$> integer a <*> integer b)
  [ "int", a ] -> show <$> int a
  [ "intAdd", a, b ] -> show <$> ((+) <$> int a <*> int b)
  [ "intSub", a, b ] -> show <$> ((-) <$> int a <*> int b)
  [ "intMul", a, b ] -> show <$> ((*) <$> int a <*> int b)
  [ "intMod", a, b ] -> show <$> (H.mod <$> int a <*> int b)
  [ "shiftL", a, n ] -> show <$> (H.shiftL <$> int a <*> smallInt n)
  [ "shiftR", a, n ] -> show <$> (H.shiftR <$> int a <*> smallInt n)
  [ "xorwise", a ] -> show <<< xorwise <$> int a
  [ "show", r ] -> show <$> rational r
  [ "add", r, s ] -> show <$> ((+) <$> rational r <*> rational s)
  [ "sub", r, s ] -> show <$> ((-) <$> rational r <*> rational s)
  [ "mul", r, s ] -> show <$> ((*) <$> rational r <*> rational s)
  [ "div", r, s ] -> show <$> ((/) <$> rational r <*> rational s)
  [ "compare", r, s ] -> show <$> (compare <$> rational r <*> rational s)
  [ "properFraction", r ] -> pair <<< Rational.properFraction <$> rational r
  [ "truncate", r ] -> show <<< Rational.truncate <$> rational r
  [ "floor", r ] -> show <<< Rational.floor <$> rational r
  [ "ceiling", r ] -> show <<< Rational.ceiling <$> rational r
  [ "round", r ] -> show <<< Rational.round <$> rational r
  [ "timeToIntSeed", r ] -> show <<< timeToIntSeed <$> rational r
  -- Every value is k / 2^29; compare k.
  [ "timeToRand", r ] -> rational r >>= \t ->
    show <$> BigInt.fromNumber (timeToRand t * 536870912.0)
  _ -> Nothing

runHaskellPrimTests :: Effect Unit
runHaskellPrimTests = do
  log ""
  log "=========================================="
  log "  Haskell.* against GHC"
  log "=========================================="
  log ""
  results <- for golden \g -> do
    let ours = eval (split (Pattern " ") g.input)
    if ours == Just g.output then pure true
    else do
      log ("  DIFF  " <> g.input <> "\n        GHC:  " <> g.output <> "\n        ours: " <> maybe "(no answer)" identity ours)
      pure false
  let same = length (filter identity results)
  log ("  " <> show same <> " of " <> show (length results) <> " cases identical to GHC")
  when (same /= length results) (throw "Haskell.* differs from GHC")
