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
import Tidal.Chords (Modifier(..), lookupChord, applyModifiers)
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
-- |
-- | Chord syntax also lives at the String level so users can write
-- | `pad "c4'major7"` and have it expand to a stack of canonical
-- | note-name strings the runtime already understands.  The chord
-- | parser is tried first, falling back to the plain sample-name form.
instance AtomParseable String where
  atomParser = located stringAtom
  patternParser = mapStateT PC.try stringChordParser
              <|> (TPat_Atom <$> located stringAtom)

-- | Core string atom parser
-- |
-- | Two shapes recognised, tried in order:
-- |
-- |   1. **Signed integer** — a leading `-` followed by at least one
-- |      digit, then more digits.  Lets users write `d "1 5 -1"` for
-- |      degrees below the root; without this leg the leading `-`
-- |      would fail the atom parser and the whole pattern would
-- |      silence.  We `try` so a failure here backtracks cleanly into
-- |      the regular leg (e.g. `-` at the start of something that
-- |      isn't a number).
-- |
-- |   2. **Regular** — starts with an alphanumeric, then can contain
-- |      `:.-_#` (the `#` is accepted so note names like `f#2` parse
-- |      as a single atom; the runtime's noteNameMidi map carries
-- |      both `#` and `s` spellings).
stringAtom :: TidalParser String
stringAtom = signedIntAtom <|> regularAtom
  where
    signedIntAtom = liftP $ PC.try do
      minus <- char '-'
      d0 <- digit
      ds <- Array.many digit
      pure $ SCU.fromCharArray (Array.cons minus (Array.cons d0 ds))

    regularAtom = do
      first <- liftP alphaNum
      rest <- liftP $ Array.many validChar
      pure $ SCU.fromCharArray (Array.cons first rest)

    validChar = alphaNum <|> satisfy \c ->
      c == ':' || c == '.' || c == '-' || c == '_' || c == '#'

-- | Chord syntax for String patterns.  Parses `<root>'<chord>['<mods>]*`
-- | and expands to a `TPat_Stack` of canonical note-name string atoms
-- | the runtime's `noteNameMidi` map already understands.
-- |
-- | Examples:
-- |   `c4'major`   → stack ["c4", "e4", "g4"]
-- |   `c4'major7`  → stack ["c4", "e4", "g4", "b4"]
-- |   `f#3'minor`  → stack ["fs3", "a3",  "cs4"]
-- |   `'major`     → stack ["c4", "e4", "g4"]   -- root defaults to c4
-- |
-- | The root note uses runtime-convention C4 = MIDI 60 (matches the
-- | noteNameMidi table), independent of the Tidal-side Note instance
-- | which uses C5 = MIDI 60.
stringChordParser :: TidalParser (TPat String)
stringChordParser = do
  Tuple span (Tuple rootPitch intervals) <- spannedClass do
    rootPitch <- optionTC 60 pNoteRootMidi   -- default = c4 = 60
    _ <- liftP $ char '\''
    chordName <- liftP $ Array.some (alphaNum <|> satisfy \c -> c == '7' || c == '9')
    let name = SCU.fromCharArray chordName
    case lookupChord name of
      Just ints -> do
        mods <- liftP $ Array.many parseChordMods
        pure $ Tuple rootPitch (applyModifiers (Array.concat mods) ints)
      Nothing -> liftP $ P.fail $ "unknown chord: " <> name
  let names = map (\interval -> stringAtomFromPitch span (rootPitch + interval)) intervals
  case Array.length names of
    0 -> liftP $ P.fail "empty chord"
    1 -> case Array.head names of
           Just n -> pure n
           Nothing -> liftP $ P.fail "empty chord"
    _ -> pure $ TPat_Stack span names
  where
    stringAtomFromPitch :: SourceSpan -> Int -> TPat String
    stringAtomFromPitch s p = TPat_Atom (Located s (midiToNoteName p))

    -- Parse note root using runtime convention: c4 = 60.
    -- Accepts `s`/`f`/`n` (Tidal accidentals) and `#` (musical sharp).
    pNoteRootMidi :: TidalParser Int
    pNoteRootMidi = liftP $ PC.try do
      base <- noteBaseParser
      mods <- Array.many noteModParserExt
      oct <- PC.option 4 (Int.round <$> number)
      pure $ (oct + 1) * 12 + base + Array.foldl (+) 0 mods

    -- Parse a chord-modifier group: 'i, 'ii, 'i2, 'o, 'd1, '5
    parseChordMods :: ParserT String Identity (Array Modifier)
    parseChordMods = do
      _ <- char '\''
      pInvertMany <|> pInvertN <|> pOpen <|> pDrop <|> pRange

    pInvertMany :: ParserT String Identity (Array Modifier)
    pInvertMany = PC.try do
      is <- Array.some (char 'i')
      PC.notFollowedBy digit
      pure $ Array.replicate (Array.length is) Invert

    pInvertN :: ParserT String Identity (Array Modifier)
    pInvertN = PC.try do
      _ <- char 'i'
      n <- pPosInt
      pure $ Array.replicate n Invert

    pOpen :: ParserT String Identity (Array Modifier)
    pOpen = do
      os <- Array.some (char 'o')
      pure $ Array.replicate (Array.length os) Open

    pDrop :: ParserT String Identity (Array Modifier)
    pDrop = do
      _ <- char 'd'
      n <- pPosInt
      pure [Drop n]

    pRange :: ParserT String Identity (Array Modifier)
    pRange = do
      n <- pPosInt
      pure [Range n]

    pPosInt :: ParserT String Identity Int
    pPosInt = do
      digits <- Array.some digit
      case Int.fromString (SCU.fromCharArray digits) of
        Just n -> pure n
        Nothing -> P.fail "expected integer"

    spannedClass :: forall a. TidalParser a -> TidalParser (Tuple SourceSpan a)
    spannedClass p = do
      s <- liftP currentPos
      r <- p
      e <- liftP currentPos
      pure $ Tuple (mkSourceSpan s e) r

    optionTC :: forall a. a -> TidalParser a -> TidalParser a
    optionTC d p = p <|> pure d

-- | Note modifier parser including `#` (sharp) and the Tidal-style
-- | `s`/`f`/`n` accidentals.  Used by `stringChordParser`'s root parser.
noteModParserExt :: ParserT String Identity Int
noteModParserExt = do
  c <- satisfy \x -> x == 's' || x == 'f' || x == 'n' || x == '#'
  pure $ case c of
    's' -> 1    -- sharp (Tidal)
    '#' -> 1    -- sharp (musical)
    'f' -> -1   -- flat
    _   -> 0    -- natural

-- | Convert a MIDI pitch to its canonical note-name string ("c4", "fs4",
-- | etc.) — uses the `s`-suffix sharp spelling that `noteNameMidi`
-- | indexes.  C0 = 12, so octave = pitch / 12 - 1.
midiToNoteName :: Int -> String
midiToNoteName pitch =
  let oct = pitch `div` 12 - 1
      step = pitch `mod` 12
      letter = case step of
        0  -> "c"
        1  -> "cs"
        2  -> "d"
        3  -> "ds"
        4  -> "e"
        5  -> "f"
        6  -> "fs"
        7  -> "g"
        8  -> "gs"
        9  -> "a"
        10 -> "as"
        _  -> "b"
  in letter <> show oct

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
rationalAtom = numberedShortcut <|> shortcut <|> ratio <|> decimal
  where
    -- Number with duration suffix: 3h (3 half notes), 1.5q (1.5 quarter notes)
    numberedShortcut = liftP $ PC.try do
      sign <- (char '-' $> (-1.0)) <|> pure 1.0
      n <- number
      c <- satisfy \x -> x == 'w' || x == 'h' || x == 'q' ||
                         x == 'e' || x == 's' || x == 't' ||
                         x == 'f' || x == 'x'
      let base = case c of
            'w' -> 1.0       -- whole
            'h' -> 0.5       -- half
            'q' -> 0.25      -- quarter
            'e' -> 0.125     -- eighth
            's' -> 0.0625    -- sixteenth
            't' -> 0.03125   -- 32nd
            'f' -> 0.015625  -- 64th
            _   -> 0.0078125 -- 128th (x)
          result = sign * n * base * 1000.0
      pure $ Int.round result % 1000

    -- Duration shortcuts (like in Tidal) - single letter
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
      -- With optional modifiers: c'major'i, c'major'o, c'major'5, c'major'd1
      chordParser :: TidalParser (TPat Note)
      chordParser = do
        Tuple span (Tuple root intervals) <- spanned do
          root <- optionT 0 pNoteRoot
          _ <- liftP $ char '\''
          chordName <- liftP $ Array.some (alphaNum <|> satisfy \c -> c == '7' || c == '9')
          let name = SCU.fromCharArray chordName
          case lookupChord name of
            Just ints -> do
              -- Parse optional modifiers (each prefixed with ')
              mods <- liftP $ Array.many parseModifierGroup
              pure $ Tuple root (applyModifiers (Array.concat mods) ints)
            Nothing -> liftP $ P.fail $ "unknown chord: " <> name
        let notes = map (\interval -> noteAtomPat span (root + interval)) intervals
        case Array.length notes of
          0 -> liftP $ P.fail "empty chord"
          1 -> case Array.head notes of
                 Just n -> pure n
                 Nothing -> liftP $ P.fail "empty chord"
          _ -> pure $ TPat_Stack span notes

      -- Parse a modifier group: 'i, 'ii, 'i2, 'o, 'd1, '5
      parseModifierGroup :: ParserT String Identity (Array Modifier)
      parseModifierGroup = do
        _ <- char '\''
        parseInvertMany <|> parseInvertN <|> parseOpen <|> parseDrop <|> parseRange

      -- Parse multiple 'i' characters: 'ii = two inversions
      parseInvertMany :: ParserT String Identity (Array Modifier)
      parseInvertMany = PC.try do
        is <- Array.some (char 'i')
        PC.notFollowedBy digit  -- Not 'i2' form
        pure $ Array.replicate (Array.length is) Invert

      -- Parse 'i2' form: 'i followed by a number
      parseInvertN :: ParserT String Identity (Array Modifier)
      parseInvertN = PC.try do
        _ <- char 'i'
        n <- pInteger
        pure $ Array.replicate n Invert

      -- Parse 'o' for open voicing
      parseOpen :: ParserT String Identity (Array Modifier)
      parseOpen = do
        os <- Array.some (char 'o')
        pure $ Array.replicate (Array.length os) Open

      -- Parse 'd1', 'd2' for drop voicing
      parseDrop :: ParserT String Identity (Array Modifier)
      parseDrop = do
        _ <- char 'd'
        n <- pInteger
        pure [Drop n]

      -- Parse a number alone as range
      parseRange :: ParserT String Identity (Array Modifier)
      parseRange = do
        n <- pInteger
        pure [Range n]

      -- Parse a positive integer
      pInteger :: ParserT String Identity Int
      pInteger = do
        digits <- Array.some digit
        case Int.fromString (SCU.fromCharArray digits) of
          Just n -> pure n
          Nothing -> P.fail "expected integer"

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
