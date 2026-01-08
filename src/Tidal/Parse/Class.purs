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
  , patternParser
  , TidalParser
  , number
  , liftP
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Monad.State (StateT)
import Control.Monad.State.Trans (mapStateT)
import Control.Monad.Trans.Class (lift)
import Data.Tuple (Tuple(..))
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
import Tidal.AST.Types (Located(..), TPat(..), SourceSpan)
import Tidal.Chords (lookupChord)
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
-- |
-- | The `patternParser` method allows types to provide pattern-level parsing
-- | (returning TPat) instead of just atom-level. This enables chord parsing
-- | for Note types, where "c'major" becomes a TPat_Stack of notes.
class AtomParseable a where
  atomParser :: TidalParser (Located a)
  -- | Parse a pattern element. Default wraps atom in TPat_Atom.
  -- | Override for types like Note that support chord syntax.
  patternParser :: TidalParser (TPat a)

-------------------------------------------------------------------------------
-- String atoms
-------------------------------------------------------------------------------

-- | Parse a sample name (alphanumeric with `:.-_`)
-- |
-- | Examples: "bd", "bd:2", "808.wav", "my-sample_01"
instance AtomParseable String where
  atomParser = located stringAtom
  patternParser = TPat_Atom <$> located stringAtom

-- | Core string atom parser
stringAtom :: TidalParser String
stringAtom = do
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
  atomParser = located numberAtom
  patternParser = TPat_Atom <$> located numberAtom

-- | Core number atom parser
numberAtom :: TidalParser Number
numberAtom = do
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
  atomParser = located intAtom
  patternParser = TPat_Atom <$> located intAtom

-- | Core int atom parser
intAtom :: TidalParser Int
intAtom = do
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
  atomParser = located rationalAtom
  patternParser = TPat_Atom <$> located rationalAtom

-- | Core rational atom parser
rationalAtom :: TidalParser Rational
rationalAtom = shortcut <|> ratio <|> decimal
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
  atomParser = located noteAtomCore
  -- | Pattern parser for Note tries chord syntax first, then single notes
  patternParser = tryT chordParser <|> (TPat_Atom <$> located noteAtomCore)
    where
      -- Try combinator through StateT
      tryT :: forall a. TidalParser a -> TidalParser a
      tryT = mapStateT PC.try

      -- Parse chord: c'major, e'minor, 'major
      chordParser :: TidalParser (TPat Note)
      chordParser = do
        Tuple span (Tuple root intervals) <- spanned do
          root <- optionT 0 pNoteRoot
          _ <- liftP $ char '\''
          chordName <- liftP $ Array.some (alphaNum <|> satisfy \c -> c == '7' || c == '9')
          let name = SCU.fromCharArray chordName
          case lookupChord name of
            Just ints -> pure $ Tuple root ints
            Nothing -> liftP $ P.fail $ "unknown chord: " <> name
        let notes = map (\interval -> noteAtomPat span (root + interval)) intervals
        case Array.length notes of
          0 -> liftP $ P.fail "empty chord"
          1 -> case Array.head notes of
                 Just n -> pure n
                 Nothing -> liftP $ P.fail "empty chord"
          _ -> pure $ TPat_Stack span notes

      -- Create a single note atom pattern
      noteAtomPat :: SourceSpan -> Int -> TPat Note
      noteAtomPat s pitch = TPat_Atom (Located s (mkNote pitch))

      -- Parse root note: c, d, e, f, g, a, b with optional accidentals and octave
      pNoteRoot :: TidalParser Int
      pNoteRoot = liftP $ PC.try do
        base <- noteBaseParser
        mods <- Array.many noteModParser
        oct <- PC.option 5 (Int.round <$> number)
        pure $ base + Array.foldl (+) 0 mods + (oct - 5) * 12

      -- Option combinator
      optionT :: forall a. a -> TidalParser a -> TidalParser a
      optionT def p = p <|> pure def

      -- Capture source span
      spanned :: forall a. TidalParser a -> TidalParser (Tuple SourceSpan a)
      spanned p = do
        start <- liftP currentPos
        result <- p
        end <- liftP currentPos
        pure $ Tuple (mkSourceSpan start end) result

-- | Core Note atom parser (single note, no chords)
noteAtomCore :: TidalParser Note
noteAtomCore = noteName <|> noteNumber
  where
    -- Parse note name: c, cs, df, etc. with optional octave
    noteName = liftP $ PC.try do
      base <- noteBaseParser
      mods <- Array.many noteModParser
      oct <- PC.option 5 (Int.round <$> number)
      let pitch = base + Array.foldl (+) 0 mods + (oct - 5) * 12
      pure $ mkNote pitch

    -- MIDI note number (integer)
    noteNumber = do
      sign <- (liftP (char '-') $> (-1)) <|> pure 1
      digits <- liftP $ Array.some digit
      case Int.fromString (SCU.fromCharArray digits) of
        Just n -> pure $ mkNote (sign * n)
        Nothing -> liftP $ P.fail "expected note number"

-- | Base note parser: c=0, d=2, e=4, f=5, g=7, a=9, b=11
noteBaseParser :: ParserT String Identity Int
noteBaseParser = do
  c <- letter
  case toLowerHelper c of
    'c' -> pure 0
    'd' -> pure 2
    'e' -> pure 4
    'f' -> pure 5
    'g' -> pure 7
    'a' -> pure 9
    'b' -> pure 11
    _   -> P.fail "expected note name (c, d, e, f, g, a, b)"

-- | Note modifier parser: s=+1 (sharp), f=-1 (flat), n=0 (natural)
noteModParser :: ParserT String Identity Int
noteModParser = do
  c <- satisfy \x -> x == 's' || x == 'f' || x == 'n'
  pure $ case c of
    's' -> 1   -- sharp
    'f' -> (-1) -- flat
    _   -> 0   -- natural

-- | Helper: convert Char to lowercase
toLowerHelper :: Char -> Char
toLowerHelper c
  | c >= 'A' && c <= 'Z' =
      case fromCharCode (toCharCode c + 32) of
        Just lc -> lc
        Nothing -> c
  | otherwise = c
