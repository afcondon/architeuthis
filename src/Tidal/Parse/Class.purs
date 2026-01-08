-- | Type classes for polymorphic atom parsing
-- |
-- | Unlike Tidal's Haskell version where `Parseable` combines parsing,
-- | Euclidean rhythm, and control lookup, we split these concerns:
-- |
-- | - `AtomParseable` - How to parse atoms of a type
-- | - `Euclidean` - How Euclidean rhythms work (deferred, for Pattern evaluation)
-- | - `HasControl` - Control pattern lookup (deferred, for Pattern evaluation)
-- |
-- | This separation means a type can be parseable without needing to define
-- | rhythm semantics, which is cleaner and more modular.
module Tidal.Parse.Class
  ( class AtomParseable
  , atomParser
  , TidalParser
  , number
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Monad.State (StateT)
import Control.Monad.Trans.Class (lift)
import Data.Array as Array
import Data.Char (toCharCode, fromCharCode)
import Data.Identity (Identity)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, (%))
import Data.String.CodeUnits as SCU
import Text.Parsing.Parser (ParserT)
import Text.Parsing.Parser as P
import Text.Parsing.Parser.Combinators as PC
import Text.Parsing.Parser.String (char, satisfy)
import Text.Parsing.Parser.Token (alphaNum, digit, letter)
import Tidal.AST.Types (Located(..))
import Tidal.Pattern.Types (Note, mkNote)
import Tidal.Parse.State (ParseState, currentPos, mkSourceSpan)

-- | The parser monad: Parser with state for seed generation
-- |
-- | StateT provides the seed counter, ParserT provides parsing.
type TidalParser = StateT ParseState (ParserT String Identity)

-- | Parse a decimal number (purerl-compatible replacement for Parsing.String.Basic.number)
number :: forall m. Monad m => ParserT String m Number
number = do
  intPart <- Array.some digit
  fracPart <- PC.option [] do
    _ <- char '.'
    Array.some digit
  let intStr = SCU.fromCharArray intPart
      fracStr = SCU.fromCharArray fracPart
      numStr = if Array.null fracPart then intStr else intStr <> "." <> fracStr
  case Int.fromString intStr of
    Just _ -> pure $ unsafeParseNumber numStr
    Nothing -> P.fail "expected number"
  where
    -- Safe because we've validated the format
    unsafeParseNumber :: String -> Number
    unsafeParseNumber s = case Int.fromString s of
      Just n -> Int.toNumber n
      Nothing -> readFloat s

-- | Foreign import for reading floats (will need FFI)
foreign import readFloat :: String -> Number

-- | Lift a parser operation into TidalParser
liftP :: forall a. ParserT String Identity a -> TidalParser a
liftP = lift

-- | Wrap a parser to capture source location
located :: forall a. TidalParser a -> TidalParser (Located a)
located p = do
  start <- liftP currentPos
  value <- p
  end <- liftP currentPos
  pure $ Located (mkSourceSpan start end) value

-- | Types that can be parsed as mini-notation atoms
-- |
-- | Different atom types have different parsing rules:
-- | - String: alphanumeric with `:.-_` (sample names like "bd:2")
-- | - Number: decimal, optionally with sign
-- | - Int: integer, optionally with sign
-- | - Note: note names (c4, fs5) or numbers
-- | - Rational: ratios like 1%3 or shortcuts (w, h, q, e, s, t, f, x)
class AtomParseable a where
  atomParser :: TidalParser (Located a)

-------------------------------------------------------------------------------
-- String atoms
-------------------------------------------------------------------------------

-- | Parse a sample name (alphanumeric with `:.-_`)
-- |
-- | Examples: "bd", "bd:2", "808.wav", "my-sample_01"
instance AtomParseable String where
  atomParser = located do
    chars <- liftP $ Array.some validChar
    pure $ SCU.fromCharArray chars
    where
      validChar = alphaNum <|> satisfy \c ->
        c == ':' || c == '.' || c == '-' || c == '_'

-------------------------------------------------------------------------------
-- Number atoms
-------------------------------------------------------------------------------

-- | Parse a decimal number (optionally signed)
-- |
-- | Examples: "0.5", "-1.0", "3.14159"
instance AtomParseable Number where
  atomParser = located do
    sign <- (liftP (char '-') $> (-1.0)) <|> pure 1.0
    n <- liftP number
    pure (sign * n)

-------------------------------------------------------------------------------
-- Int atoms
-------------------------------------------------------------------------------

-- | Parse an integer (optionally signed)
-- |
-- | Examples: "0", "-1", "42"
instance AtomParseable Int where
  atomParser = located do
    sign <- (liftP (char '-') $> (-1)) <|> pure 1
    digits <- liftP $ Array.some digit
    case Int.fromString (SCU.fromCharArray digits) of
      Just n -> pure (sign * n)
      Nothing -> liftP $ P.fail "expected integer"

-------------------------------------------------------------------------------
-- Rational atoms
-------------------------------------------------------------------------------

-- | Parse a rational number
-- |
-- | Supports:
-- | - Plain integers: "1", "-2"
-- | - Decimals: "0.5", "1.25"
-- | - Ratios: "1%2", "3%4"
-- | - Duration shortcuts: "w" (whole), "h" (half), "q" (quarter),
-- |   "e" (eighth), "s" (sixteenth), "t" (32nd), "f" (64th), "x" (128th)
instance AtomParseable Rational where
  atomParser = located $ shortcut <|> ratio <|> decimal
    where
      -- Duration shortcuts (like in Tidal)
      shortcut = do
        c <- liftP $ satisfy \x -> x == 'w' || x == 'h' || x == 'q' ||
                                   x == 'e' || x == 's' || x == 't' ||
                                   x == 'f' || x == 'x'
        pure $ case c of
          'w' -> 1 % 1   -- whole
          'h' -> 1 % 2   -- half
          'q' -> 1 % 4   -- quarter
          'e' -> 1 % 8   -- eighth
          's' -> 1 % 16  -- sixteenth
          't' -> 1 % 32  -- 32nd
          'f' -> 1 % 64  -- 64th
          'x' -> 1 % 128 -- 128th
          _   -> 1 % 1   -- shouldn't happen

      -- Explicit ratio: n%d
      ratio = liftP $ PC.try do
        sign <- (char '-' $> (-1)) <|> pure 1
        nDigits <- Array.some digit
        _ <- char '%'
        dDigits <- Array.some digit
        case Int.fromString (SCU.fromCharArray nDigits), Int.fromString (SCU.fromCharArray dDigits) of
          Just n, Just d -> pure $ (sign * n) % d
          _, _ -> P.fail "invalid ratio"

      -- Decimal (converted to rational)
      decimal = do
        sign <- (liftP (char '-') $> (-1.0)) <|> pure 1.0
        n <- liftP number
        let scaled = sign * n * 1000.0
        pure $ Int.round scaled % 1000

-------------------------------------------------------------------------------
-- Note atoms
-------------------------------------------------------------------------------

-- | Parse a musical note
-- |
-- | Supports:
-- | - Note names: c, d, e, f, g, a, b (case insensitive)
-- | - Accidentals: s (sharp), f (flat), n (natural)
-- | - Octave: 0-9 (default 5, like Tidal)
-- | - MIDI numbers: 60, 48, etc.
-- |
-- | Examples: "c4", "fs5", "bf3", "60"
-- |
-- | Note: c5 = MIDI 60 (middle C), following Tidal's convention
instance AtomParseable Note where
  atomParser = located $ noteName <|> noteNumber
    where
      -- Parse note name: c, cs, df, etc. with optional octave
      noteName = liftP $ PC.try do
        base <- noteBase
        mods <- Array.many noteModifier
        oct <- PC.option 5 (Int.round <$> number)
        let pitch = base + sum mods + (oct - 5) * 12
        pure $ mkNote pitch

      -- Base note: c=0, d=2, e=4, f=5, g=7, a=9, b=11
      noteBase :: ParserT String Identity Int
      noteBase = do
        c <- letter
        case toLowerChar c of
          'c' -> pure 0
          'd' -> pure 2
          'e' -> pure 4
          'f' -> pure 5
          'g' -> pure 7
          'a' -> pure 9
          'b' -> pure 11
          _   -> P.fail "expected note name (c, d, e, f, g, a, b)"

      -- Accidentals: s=+1 (sharp), f=-1 (flat), n=0 (natural)
      noteModifier :: ParserT String Identity Int
      noteModifier = do
        c <- satisfy \x -> x == 's' || x == 'f' || x == 'n'
        pure $ case c of
          's' -> 1   -- sharp
          'f' -> (-1) -- flat
          'n' -> 0   -- natural
          _   -> 0

      -- MIDI note number (integer)
      noteNumber = do
        sign <- (liftP (char '-') $> (-1)) <|> pure 1
        digits <- liftP $ Array.some digit
        case Int.fromString (SCU.fromCharArray digits) of
          Just n -> pure $ mkNote (sign * n)
          Nothing -> liftP $ P.fail "expected note number"

      -- Helper: convert Char to lowercase
      toLowerChar :: Char -> Char
      toLowerChar c
        | c >= 'A' && c <= 'Z' =
            case fromCharCode (toCharCode c + 32) of
              Just lc -> lc
              Nothing -> c
        | otherwise = c

      -- Sum helper
      sum :: Array Int -> Int
      sum = Array.foldl (+) 0
