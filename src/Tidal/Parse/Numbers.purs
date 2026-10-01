-- | **Haskell Tidal's mini-notation lexemes, as plain parsers.**
-- |
-- | Ports from Tidal 1.10.1's `Sound.Tidal.ParseBP`: numbers read exactly
-- | as rationals (`intOrFloat`, `pRatio` with `%` and duration letters, an
-- | exponent), note names (`parseNote`), and the per-type atoms the line
-- | language reads (`pVocable`, `pDouble`, `pNote`, `parseIntNote`). The
-- | TidalParser layer (`Tidal.Parse.Class`, `.Combinators`, `.Haskell`)
-- | lifts these; they depend on nothing of it.
module Tidal.Parse.Numbers
  ( pVocable
  , pDouble
  , pNote
  , pNoteWithoutChord
  , parseIntNote
  , pRatio
  , intOrFloat
  , parseNote
  , parseModifiers
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Array as Array
import Data.Char (toCharCode)
import Data.Foldable (foldl)
import Haskell.Parsec (Parsec, fail, char, satisfy, digit, letter)
import Haskell.Parsec as Parsec
import Tidal.Parse.State (ParseState)
import Data.Int as Int
import Data.Rational (Rational, denominator, fromInt, numerator, toNumber, (%))
import Data.String.CodeUnits as SCU
import Tidal.Chords (Modifier(..))

type P = Parsec ParseState

-- | `pString`: a letter or digit, then letters, digits and `:.-_`.
pVocable :: P String
pVocable = do
  c <- letter <|> digit
  cs <- Parsec.many (letter <|> digit <|> satisfy \x -> x == ':' || x == '.' || x == '-' || x == '_')
  pure (SCU.fromCharArray (Array.cons c cs))

-- | `pDoubleWithoutChord`'s atom: sign, then a ratio or a note name.
pDouble :: P Number
pDouble = do
  s <- sign
  v <- (toNumber <$> pRatio) <|> parseNote
  pure (s v)

-- | `pNoteWithoutChord`'s atom, then `pNote`'s ratio fallback.
pNote :: P Number
pNote = Parsec.try pNoteWithoutChord <|> (toNumber <$> pRatio)

-- | `pNoteWithoutChord`'s atom: sign, then an int or float or a note name.
pNoteWithoutChord :: P Number
pNoteWithoutChord = do
  s <- sign
  v <- (toNumber <$> intOrFloat) <|> parseNote
  pure (s v)

-- | `parseIntNote`: as a note, but it must be whole.
parseIntNote :: P Int
parseIntNote = do
  s <- sign
  d <- (toNumber <$> intOrFloat) <|> parseNote
  if Int.toNumber (Int.round d) == d then pure (s (Int.round d)) else fail "not an integer"

-- | `sign`: `-`, `+` or nothing.
sign :: forall n. Ring n => P (n -> n)
sign = (char '-' $> negate) <|> (char '+' $> identity) <|> pure identity

-- | `pRatio`: sign, then an int or float with an optional `%d` and an
-- | optional duration letter, or a duration letter alone.
pRatio :: P Rational
pRatio = do
  s <- sign
  r <- numbered <|> ratioChar
  pure (s r)
  where
  numbered = do
    n <- Parsec.try intOrFloat
    v <- pFraction n <|> pure n
    c <- ratioChar <|> pure one
    pure (v * c)

-- | `pFraction`: `%` and a whole denominator, for a whole numerator.
pFraction :: Rational -> P Rational
pFraction n = do
  _ <- char '%'
  d <- pInteger
  if denominator n == 1 && d /= 0 then pure (numerator n % d) else fail "fractions need int numerator and denominator"

-- | `intOrFloat`: `try pFloat <|> pInteger`, exactly.
intOrFloat :: P Rational
intOrFloat = Parsec.try pFloat <|> (fromInt <$> pInteger)

-- | `pFloat`: digits, then optionally `.digits`, then optionally
-- | `e[-]digits`. A `.` or `e` not followed by digits fails the whole float
-- | (so `0..8` reads the integer 0, then a range).
pFloat :: P Rational
pFloat = do
  i <- Parsec.many1 digit
  d <- Parsec.option [] (char '.' *> Parsec.many1 digit)
  e <- Parsec.option 0 do
    _ <- char 'e'
    neg <- Parsec.option false (char '-' $> true)
    ds <- Parsec.many1 digit
    pure (if neg then negate (digitsInt ds) else digitsInt ds)
  let
    mantissa = fromInt (digitsInt (i <> d)) / fromInt (pow10 (Array.length d))
  pure (if e >= 0 then mantissa * fromInt (pow10 e) else mantissa / fromInt (pow10 (negate e)))

pInteger :: P Int
pInteger = digitsInt <$> Parsec.many1 digit

digitsInt :: Array Char -> Int
digitsInt = foldl (\acc c -> acc * 10 + (toCharCode c - toCharCode '0')) 0

pow10 :: Int -> Int
pow10 k = foldl (\acc _ -> acc * 10) 1 (Array.replicate k unit)

-- | `pRatioChar`: one duration letter not followed by a letter.
ratioChar :: P Rational
ratioChar = Parsec.choice (map one' letters)
  where
  one' (Tuple' c v) = Parsec.try do
    _ <- char c
    Parsec.notFollowedBy letter
    pure v
  letters =
    [ Tuple' 'w' one, Tuple' 'h' (1 % 2), Tuple' 'q' (1 % 4), Tuple' 'e' (1 % 8)
    , Tuple' 's' (1 % 16), Tuple' 't' (1 % 3), Tuple' 'f' (1 % 5), Tuple' 'x' (1 % 6)
    ]

data Tuple' = Tuple' Char Rational

-- | `parseNote`: a letter, modifiers `s`/`f`/`n`, an octave (5 if none).
-- | C5 is 0.
parseNote :: P Number
parseNote = do
  n <- notenum
  mods <- Parsec.many modifier
  octave <- Parsec.option 5 pInteger
  pure (Int.toNumber (n + foldl (+) 0 mods + (octave - 5) * 12))
  where
  notenum = (char 'c' $> 0) <|> (char 'd' $> 2) <|> (char 'e' $> 4) <|> (char 'f' $> 5)
    <|> (char 'g' $> 7) <|> (char 'a' $> 9) <|> (char 'b' $> 11)
  modifier = (char 's' $> 1) <|> (char 'f' $> (-1)) <|> (char 'n' $> 0)

-- | `parseModifiers`: `o`s (Open), `d` and a number (Drop), a number or
-- | note (Range), `i` and a number (that many Inverts), or `i`s.
parseModifiers :: P (Array Modifier)
parseModifiers =
  (map (const Open) <$> Parsec.many1 (char 'o'))
    <|> (char 'd' *> (pure <<< Drop <$> pInteger))
    <|> (pure <<< Range <$> parseIntNote)
    <|> Parsec.try (char 'i' *> ((\n -> Array.replicate n Invert) <$> pInteger))
    <|> (map (const Invert) <$> Parsec.many1 (char 'i'))
