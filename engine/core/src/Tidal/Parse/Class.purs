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
  , located
  ) where

import Prelude

import Control.Alt ((<|>))
import Haskell.Parsec (Parsec, char, satisfy, alphaNum, digit, letter)
import Haskell.Parsec as Parsec
import Data.Tuple (Tuple(..))
import Data.Array as Array
import Data.Char (toCharCode, fromCharCode)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number as Number
import Haskell.Rational (Rational)
import Data.String.CodeUnits as SCU
import Tidal.AST.Types (Located(..), TPat(..), SourceSpan)
import Tidal.Chords (Modifier(..), Modifiers(..), lookupChord, applyModifiers)
import Tidal.Pattern.Types (Note, mkNote)
import Tidal.Parse.Numbers (parseIntNote, parseModifiers, pRatio)
import Tidal.Parse.State (ParseState, currentPos, mkSourceSpan)

-- | The parser monad: Haskell's Parsec (`Haskell.Parsec`), its user state
-- | the seed counter, as in Tidal's `Parsec String Int`.
type TidalParser = Parsec ParseState

-- | Parse a decimal number (purerl-compatible replacement for Parsing.String.Basic.number)
number :: TidalParser Number
number = do
  intPart <- Parsec.many1 digit
  fracPart <- Parsec.option [] do
    _ <- char '.'
    Parsec.many1 digit
  let intStr = SCU.fromCharArray intPart
      fracStr = SCU.fromCharArray fracPart
      numStr = if Array.null fracPart then intStr else intStr <> "." <> fracStr
  case Int.fromString intStr of
    Just _ -> pure $ unsafeParseNumber numStr
    Nothing -> Parsec.fail "expected number"
  where
    -- Safe because we've validated the format
    unsafeParseNumber :: String -> Number
    unsafeParseNumber s = case Int.fromString s of
      Just n -> Int.toNumber n
      Nothing -> readFloat s

-- | Validated above, so `fromString` cannot fail here.
readFloat :: String -> Number
readFloat s = fromMaybe 0.0 (Number.fromString s)

-- | The identity, as in `Tidal.Parse.Combinators`.
liftP :: forall a. TidalParser a -> TidalParser a
liftP = identity

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
-- Chord modifiers
-------------------------------------------------------------------------------

-- | One atom of a chord's modifier pattern: Haskell's `pModifiers`.
instance AtomParseable Modifiers where
  atomParser = located (liftP (Modifiers <$> parseModifiers))
  patternParser = TPat_Atom <$> located (liftP (Modifiers <$> parseModifiers))

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
  patternParser = Parsec.try stringChordParser
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
stringAtom = signedNumAtom <|> regularAtom
  where
    -- A leading `-` puts us on the signed-number path, and `regularAtom`
    -- cannot rescue us from it: that one must START with an alphanumeric,
    -- so the `.` in `-0.5` matches nothing and is dropped.  Until this
    -- parser took a fraction, `speed "-0.5"` therefore tokenised as
    -- `["-0", "5"]` — a TWO-step pattern playing backwards at 0x and then
    -- forwards at 5x.  No error, no warning, and the wrong thing is close
    -- enough to "the minus didn't take" to be blamed on the module.
    -- Positive fractions were always fine (`regularAtom` accepts `.`),
    -- which is why this survived: it only bit the signed half.
    signedNumAtom = liftP $ Parsec.try do
      minus <- char '-'
      d0 <- digit
      ds <- Parsec.many digit
      frac <- Parsec.option [] $ Parsec.try do
        dot <- char '.'
        f0 <- digit
        fs <- Parsec.many digit
        pure $ Array.cons dot (Array.cons f0 fs)
      pure $ SCU.fromCharArray
        (Array.cons minus (Array.cons d0 ds) <> frac)

    regularAtom = do
      first <- liftP alphaNum
      rest <- liftP $ Parsec.many validChar
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
    chordName <- liftP $ Parsec.many1 (alphaNum <|> satisfy \c -> c == '7' || c == '9')
    let name = SCU.fromCharArray chordName
    case lookupChord name of
      Just ints -> do
        mods <- liftP $ Parsec.many parseChordMods
        pure $ Tuple rootPitch (applyModifiers (Array.concat mods) ints)
      Nothing -> liftP $ Parsec.fail $ "unknown chord: " <> name
  let names = map (\interval -> stringAtomFromPitch span (rootPitch + interval)) intervals
  case Array.length names of
    0 -> liftP $ Parsec.fail "empty chord"
    1 -> case Array.head names of
           Just n -> pure n
           Nothing -> liftP $ Parsec.fail "empty chord"
    _ -> pure $ TPat_Stack span names
  where
    stringAtomFromPitch :: SourceSpan -> Int -> TPat String
    stringAtomFromPitch s p = TPat_Atom (Located s (midiToNoteName p))

    -- Parse note root using runtime convention: c4 = 60.
    -- Accepts `s`/`f`/`n` (Tidal accidentals) and `#` (musical sharp).
    pNoteRootMidi :: TidalParser Int
    pNoteRootMidi = liftP $ Parsec.try do
      base <- noteBaseParser
      mods <- Parsec.many noteModParserExt
      oct <- Parsec.option 4 (Int.round <$> number)
      pure $ (oct + 1) * 12 + base + Array.foldl (+) 0 mods

    -- Parse a chord-modifier group: 'i, 'ii, 'i2, 'o, 'd1, '5
    parseChordMods :: TidalParser (Array Modifier)
    parseChordMods = do
      _ <- char '\''
      pInvertMany <|> pInvertN <|> pOpen <|> pDrop <|> pRange

    pInvertMany :: TidalParser (Array Modifier)
    pInvertMany = Parsec.try do
      is <- Parsec.many1 (char 'i')
      Parsec.notFollowedBy digit
      pure $ Array.replicate (Array.length is) Invert

    pInvertN :: TidalParser (Array Modifier)
    pInvertN = Parsec.try do
      _ <- char 'i'
      n <- pPosInt
      pure $ Array.replicate n Invert

    pOpen :: TidalParser (Array Modifier)
    pOpen = do
      os <- Parsec.many1 (char 'o')
      pure $ Array.replicate (Array.length os) Open

    pDrop :: TidalParser (Array Modifier)
    pDrop = do
      _ <- char 'd'
      n <- pPosInt
      pure [Drop n]

    pRange :: TidalParser (Array Modifier)
    pRange = do
      n <- pPosInt
      pure [Range n]

    pPosInt :: TidalParser Int
    pPosInt = do
      digits <- Parsec.many1 digit
      case Int.fromString (SCU.fromCharArray digits) of
        Just n -> pure n
        Nothing -> Parsec.fail "expected integer"

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
noteModParserExt :: TidalParser Int
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

-- | Core int atom parser: Haskell Tidal's `parseIntNote` (a whole number
-- | or a note name, so `bd(3,8,c)` works as in Tidal).
intAtom :: TidalParser Int
intAtom = liftP parseIntNote

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

-- | Core rational atom parser: Haskell Tidal's `pRatio` (an int or float,
-- | `%` and a denominator, a duration letter: `3h`, `1%6`, `q`), exact.
rationalAtom :: TidalParser Rational
rationalAtom = liftP pRatio

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
      tryT :: forall a. TidalParser a -> TidalParser a
      tryT = Parsec.try

      -- Parse chord: c'major, e'minor, 'major
      -- With optional modifiers: c'major'i, c'major'o, c'major'5, c'major'd1
      chordParser :: TidalParser (TPat Note)
      chordParser = do
        Tuple span (Tuple root intervals) <- spanned do
          root <- optionT 0 pNoteRoot
          _ <- liftP $ char '\''
          chordName <- liftP $ Parsec.many1 (alphaNum <|> satisfy \c -> c == '7' || c == '9')
          let name = SCU.fromCharArray chordName
          case lookupChord name of
            Just ints -> do
              -- Parse optional modifiers (each prefixed with ')
              mods <- liftP $ Parsec.many parseModifierGroup
              pure $ Tuple root (applyModifiers (Array.concat mods) ints)
            Nothing -> liftP $ Parsec.fail $ "unknown chord: " <> name
        let notes = map (\interval -> noteAtomPat span (root + interval)) intervals
        case Array.length notes of
          0 -> liftP $ Parsec.fail "empty chord"
          1 -> case Array.head notes of
                 Just n -> pure n
                 Nothing -> liftP $ Parsec.fail "empty chord"
          _ -> pure $ TPat_Stack span notes

      -- Parse a modifier group: 'i, 'ii, 'i2, 'o, 'd1, '5
      parseModifierGroup :: TidalParser (Array Modifier)
      parseModifierGroup = do
        _ <- char '\''
        parseInvertMany <|> parseInvertN <|> parseOpen <|> parseDrop <|> parseRange

      -- Parse multiple 'i' characters: 'ii = two inversions
      parseInvertMany :: TidalParser (Array Modifier)
      parseInvertMany = Parsec.try do
        is <- Parsec.many1 (char 'i')
        Parsec.notFollowedBy digit  -- Not 'i2' form
        pure $ Array.replicate (Array.length is) Invert

      -- Parse 'i2' form: 'i followed by a number
      parseInvertN :: TidalParser (Array Modifier)
      parseInvertN = Parsec.try do
        _ <- char 'i'
        n <- pInteger
        pure $ Array.replicate n Invert

      -- Parse 'o' for open voicing
      parseOpen :: TidalParser (Array Modifier)
      parseOpen = do
        os <- Parsec.many1 (char 'o')
        pure $ Array.replicate (Array.length os) Open

      -- Parse 'd1', 'd2' for drop voicing
      parseDrop :: TidalParser (Array Modifier)
      parseDrop = do
        _ <- char 'd'
        n <- pInteger
        pure [Drop n]

      -- Parse a number alone as range
      parseRange :: TidalParser (Array Modifier)
      parseRange = do
        n <- pInteger
        pure [Range n]

      -- Parse a positive integer
      pInteger :: TidalParser Int
      pInteger = do
        digits <- Parsec.many1 digit
        case Int.fromString (SCU.fromCharArray digits) of
          Just n -> pure n
          Nothing -> Parsec.fail "expected integer"

      -- Create a single note atom pattern
      noteAtomPat :: SourceSpan -> Int -> TPat Note
      noteAtomPat s pitch = TPat_Atom (Located s (mkNote pitch))

      -- Parse root note: c, d, e, f, g, a, b with optional accidentals and octave
      pNoteRoot :: TidalParser Int
      pNoteRoot = liftP $ Parsec.try do
        base <- noteBaseParser
        mods <- Parsec.many noteModParser
        oct <- Parsec.option 5 (Int.round <$> number)
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
    noteName = liftP $ Parsec.try do
      base <- noteBaseParser
      mods <- Parsec.many noteModParser
      oct <- Parsec.option 5 (Int.round <$> number)
      let pitch = base + Array.foldl (+) 0 mods + (oct - 5) * 12
      pure $ mkNote pitch

    -- MIDI note number (integer)
    noteNumber = do
      sign <- (liftP (char '-') $> (-1)) <|> pure 1
      digits <- liftP $ Parsec.many1 digit
      case Int.fromString (SCU.fromCharArray digits) of
        Just n -> pure $ mkNote (sign * n)
        Nothing -> liftP $ Parsec.fail "expected note number"

-- | Base note parser: c=0, d=2, e=4, f=5, g=7, a=9, b=11
noteBaseParser :: TidalParser Int
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
    _   -> Parsec.fail "expected note name (c, d, e, f, g, a, b)"

-- | Note modifier parser: s=+1 (sharp), f=-1 (flat), n=0 (natural)
noteModParser :: TidalParser Int
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
