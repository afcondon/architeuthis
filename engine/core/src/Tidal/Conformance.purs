-- | **The engine against its references: Haskell Tidal, and GHC.**
-- |
-- | Pure, so every column runs the same comparison on its own backend
-- | (`Tidal.Conformance.Main`); the claim is that GHC, the BEAM and JS give
-- | the same answers, case for case.
-- |
-- | - `tidal`: every case in `Tidal.Conformance.TidalGolden` was rendered by
-- |   GHCi running Tidal (oracle/generate.mjs, from oracle/corpus.txt:
-- |   Tidal's own ParseTest cases first, then ours). Each is read here as a
-- |   line, queried over the same arc and rendered the same way; the event
-- |   lists must be equal, fragments and all, in any order, and a case Tidal
-- |   refused must be refused here too.
-- | - `haskell`: every case in `Tidal.Conformance.HaskellGolden` was computed
-- |   by GHC, the randomness by Tidal's own `Sound.Tidal.UI` and the parsers
-- |   by `Text.Parsec` (oracle/haskell-prim.hs, from oracle/haskell-prim.txt).
-- |   Each is computed here with the `Haskell.*` types and printed as
-- |   Haskell's `show` prints it.
module Tidal.Conformance
  ( Result
  , tidal
  , haskell
  , render
  , tidalVersion
  ) where

import Prelude hiding ((#))

import Control.Alt ((<|>))
import Data.Array (sort)
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Ord (abs)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll, split)
import Data.String as String
import Data.String.CodeUnits (fromCharArray)
import Data.Tuple (Tuple(..))
import Haskell.Int as H
import Haskell.Integer (Integer)
import Haskell.Integer as Integer
import Haskell.Parsec (ParseError, Parsec, alphaNum, char, choice, digit, eof, getPosition, letter, lookAhead, many, many1, notFollowedBy, oneOf, option, sepBy, sourceColumn, sourceLine, spaces, string, try, (<?>))
import Haskell.Parsec as Parsec
import Haskell.Rational (Rational, denominator, fromInt, numerator, ratio)
import Haskell.Rational as Rational
import JS.BigInt as BigInt
import Tidal.Conformance.HaskellGolden as HaskellGolden
import Tidal.Conformance.TidalGolden as TidalGolden
import Tidal.Line (Command(..), parseLine)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Random (timeToIntSeed, timeToRand, xorwise)
import Tidal.Pattern.Types (Arc(..), Event(..), Value(..))

-- | One case: what the reference said, and what we say.
type Result = { input :: String, expected :: String, actual :: String }

tidalVersion :: String
tidalVersion = TidalGolden.tidalVersion

-- | The Tidal corpus, compared.
tidal :: Array Result
tidal = map compare1 TidalGolden.golden
  where
  compare1 g =
    let
      ours = case parseLine ("d1 $ " <> g.expr) of
        Right (Play _ p) -> Just (sort (map render (queryArc p (fromInt g.from) (fromInt g.to))))
        _ -> Nothing
    in
      { input: g.expr <> "  over " <> show g.from <> ".." <> show g.to
      , expected: events (map sort g.events)
      , actual: events ours
      }
  events = maybe "refused" show

-- | The reference-semantics types, compared.
haskell :: Array Result
haskell = map compare1 HaskellGolden.golden
  where
  compare1 g =
    { input: g.input
    , expected: g.output
    , actual: maybe "(no answer)" identity (eval (split (Pattern " ") g.input))
    }

-- | An event as oracle/render.hs renders it in GHCi:
-- | `whole|part|key=value,...`, values tagged f (float) and n (note),
-- | strings quoted, ints bare, three decimals.
render :: Event (Map.Map String Value) -> String
render = case _ of
  Digital e -> arc e.whole <> "|" <> arc e.part <> "|" <> values e.value
  Analog e -> "~|" <> arc e.part <> "|" <> values e.value
  where
  arc (Arc a) = rat a.start <> "-" <> rat a.stop
  rat :: Rational -> String
  rat r = if denominator r == one then show (numerator r) else show (numerator r) <> "/" <> show (denominator r)
  -- purerl shows Numbers in exponent form; three decimals is enough here.
  -- Sign handled apart: purerl's Int div truncates, so -0.5 would lose it.
  num x =
    let
      i = Int.round (abs x * 1000.0)
      frac = show (i `mod` 1000 + 1000)
    in
      (if x < 0.0 && i /= 0 then "-" else "") <> show (i / 1000) <> "." <> String.drop 1 frac
  values m = joinWith "," (map kv (Map.toUnfoldable m :: Array (Tuple String Value)))
  kv (Tuple k v) = k <> "=" <> case v of
    VNumber x -> "f" <> num x
    VNote x -> "n" <> num x
    VString x -> show x
    VInt i -> show i
    VBool b -> show b
    VRational r -> rat r

integer :: String -> Maybe Integer
integer = map Integer.fromBigInt <<< BigInt.fromString

int :: String -> Maybe H.Int
int = map H.fromInteger <<< integer

rational :: String -> Maybe Rational
rational s = case split (Pattern "/") s of
  [ n, d ] -> ratio <$> integer n <*> integer d
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
  [ "parsec", name, input ] -> parsec name (replaceAll (Pattern "_") (Replacement " ") (replaceAll (Pattern "^") (Replacement "\t") input))
  _ -> Nothing

-- | The same table as haskell-prim.hs's.
parsec :: String -> String -> Maybe String
parsec name input = case name of
  "stringAlt" -> Just $ run (string "ab" <|> string "ax")
  "tryStringAlt" -> Just $ run (try (string "ab") <|> string "ax")
  "digitsEof" -> Just $ run (str (many1 digit) <* eof)
  "lookAheadThen" -> Just $ run (lookAhead (string "ab") *> string "abc")
  "commaList" -> Just $ run (sepBy (str (many1 letter)) (char ',') <* eof)
  "labelled" -> Just $ run ((char 'x' <?> "an x") <|> digit)
  "column" -> Just $ showEither (\p -> "(" <> show (sourceLine p) <> "," <> show (sourceColumn p) <> ")")
      (Parsec.parse (many (oneOf [ ' ', '\t' ]) *> getPosition) "" input)
  "keyword" -> Just $ run (string "let" <* notFollowedBy alphaNum)
  "spacesThen" -> Just $ run (spaces *> str (many1 letter) <* eof)
  "optionDigits" -> Just $ run (option "none" (str (many1 digit)) <* eof)
  "choiceStrings" -> Just $ run (choice [ string "foo", string "bar" ] <* eof)
  _ -> Nothing
  where
  -- Haskell's String is [Char]; ours is not, so make it one to show it.
  str = map fromCharArray
  run :: forall a. Show a => Parsec Unit a -> String
  run p = showEither show (Parsec.parse p "" input)

-- | `show` of an `Either`, as Haskell shows it (Parsec's `ParseError` has
-- | only `show`, so it takes no parentheses).
showEither :: forall a. (a -> String) -> Either ParseError a -> String
showEither sh = case _ of
  Left e -> "Left " <> show e
  Right a -> "Right " <> sh a
