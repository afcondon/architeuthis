-- | Parser combinators for mini-notation
-- |
-- | This module implements the mini-notation grammar as parser combinators.
-- | The grammar is roughly:
-- |
-- | ```
-- | pattern  = sequence ((',' sequence)* | ('|' sequence)*)
-- | sequence = part*
-- | part     = single | group | polyrhythm | variable
-- | single   = atom modifiers*
-- | modifier = '*' ratio | '/' ratio | '@' ratio | '!' int | '?' prob | euclid
-- | group    = '[' pattern ']'
-- | polyrhythm = '{' sequence (',' sequence)* '}' ('%' ratio)?
-- |            | '<' sequence (',' sequence)* '>'
-- | euclid   = '(' int ',' int (',' int)? ')'
-- | ```
module Tidal.Parse.Combinators
  ( -- * Main entry point
    pTidal
    -- * Sequence and parts
  , pSequence
  , pPart
  , pPartWith
  , pSingle
  , pSingleWith
    -- * Atoms
  , pAtom
  , pSilence
  , pVar
    -- * Chords (Note-specific)
  , pNoteChord
    -- * Modifiers
  , pMult
  , pRand
  , pE
  , pElongate
  , pRepeat
  , pEnumeration
    -- * Grouping
  , pPolyIn
  , pPolyOut
    -- * Utilities
  , liftP
  , spanned
  , located
    -- * TidalParser combinators
  , manyT
  , someT
  , sepByT
  , tryT
  , optionT
  , optionalT
    -- * Primitive parsers
  , pRational
  , pInt
  , pNumber
    -- * Internal (for custom parsers)
  , symbol
  , spaces
  ) where

import Prelude hiding (between)

import Control.Alt ((<|>))
import Control.Lazy (defer)
import Haskell.Parsec (char, noneOf, satisfy, string, alphaNum, digit)
import Haskell.Parsec as Parsec
import Data.Array as Array
import Data.Char (toCharCode, fromCharCode)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Haskell.Rational (Rational, (%))
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))
import Tidal.AST.Types (Located(..), TPat(..), SourceSpan, tpatSpan)
import Tidal.Parse.Numbers (pRatio)
import Tidal.Chords (Modifier(..), lookupChord, applyModifiers)
import Tidal.Core.Types (ControlName(..), SourcePos)
import Tidal.Parse.Class (class AtomParseable, atomParser, patternParser, TidalParser, number)
import Tidal.Parse.State (currentPos, mkSourceSpan, newSeed)
import Tidal.Pattern.Types (Note, mkNote)

-- | The identity: plain parsers are TidalParsers now that the seed lives in
-- | Parsec's user state. Kept so the grammar reads as it did.
liftP :: forall a. TidalParser a -> TidalParser a
liftP = identity

-- | Get current position from the parser
getPos :: TidalParser SourcePos
getPos = liftP currentPos

-- | Wrap a parser to capture source span
spanned :: forall a. TidalParser a -> TidalParser (Tuple SourceSpan a)
spanned p = do
  start <- getPos
  result <- p
  end <- getPos
  pure $ Tuple (mkSourceSpan start end) result

-- | Parse something and wrap it with source location
located :: forall a. TidalParser a -> TidalParser (Located a)
located p = do
  Tuple span value <- spanned p
  pure $ Located span value

-- | Skip whitespace
spaces :: TidalParser Unit
spaces = liftP Parsec.spaces

-- | Parse a symbol (string followed by optional spaces)
symbol :: String -> TidalParser String
symbol s = liftP (string s) <* spaces

-- | Between combinator for TidalParser
betweenT :: forall a. TidalParser Unit -> TidalParser Unit -> TidalParser a -> TidalParser a
betweenT open close p = do
  _ <- open
  result <- p
  _ <- close
  pure result

-- | Parse between brackets
brackets :: forall a. TidalParser a -> TidalParser a
brackets = betweenT (void $ symbol "[") (void $ symbol "]")

-- | Parse between braces
braces :: forall a. TidalParser a -> TidalParser a
braces = betweenT (void $ symbol "{") (void $ symbol "}")

-- | Parse between angles
angles :: forall a. TidalParser a -> TidalParser a
angles = betweenT (void $ symbol "<") (void $ symbol ">")

-- | Parse between parens
parens :: forall a. TidalParser a -> TidalParser a
parens = betweenT (void $ symbol "(") (void $ symbol ")")

-------------------------------------------------------------------------------
-- Main parser
-------------------------------------------------------------------------------

-- | Main entry point - parse a full pattern
-- |
-- | A pattern is a sequence optionally followed by:
-- | - stack (,) - layers patterns
-- | - choose (|) - randomly selects
-- | - dot (.) - divides cycle into equal groups
pTidal :: forall a. AtomParseable a => TidalParser (TPat a)
pTidal = defer \_ -> do
  s <- pSequence
  x <- stackTail s <|> chooseTail s <|> pure s
  pMult x
  where
    stackTail s = do
      _ <- symbol ","
      ss <- pSequence `sepByT` symbol ","
      theSpan <- spanFromArray (Array.cons s ss)
      pure $ TPat_Stack theSpan (Array.cons s ss)

    chooseTail s = do
      _ <- symbol "|"
      ss <- pSequence `sepByT` symbol "|"
      theSpan <- spanFromArray (Array.cons s ss)
      seed <- newSeed
      pure $ TPat_CycleChoose theSpan seed (Array.cons s ss)

    -- Get span covering all elements
    spanFromArray :: Array (TPat a) -> TidalParser SourceSpan
    spanFromArray arr = do
      end <- getPos
      let start = case Array.head arr of
            Just pat -> (tpatSpan pat).start
            Nothing -> end
      pure $ mkSourceSpan start end

-- | Parse a sequence of parts: Haskell's `pSequence`. A `.` is a foot:
-- | `bd sd . hh hh hh` is `[bd sd] [hh hh hh]`, wherever a sequence is
-- | (inside `<>` and `{}` too). A `?` may follow the whole sequence.
pSequence :: forall a. AtomParseable a => TidalParser (TPat a)
pSequence = defer \_ -> do
  Tuple span parts <- spanned do
    spaces
    manyT (step <|> foot)
  pRand (resolveFeet span parts)
  where
    step = do
      a <- pPart
      spaces
      Just <$> (pEnumeration a <|> pElongate a <|> pRepeat a <|> pure a)
    foot = tryT do
      _ <- liftP $ char '.'
      liftP $ Parsec.notFollowedBy (char '.')
      spaces
      pure Nothing
    resolveFeet span parts =
      let feet = splitFeet parts
      in
        if Array.length feet > 1 then TPat_Seq span (map (TPat_Seq span) feet)
        else TPat_Seq span (Array.catMaybes parts)
    splitFeet parts = case Array.findIndex isFoot parts of
      Nothing -> [ Array.catMaybes parts ]
      Just i -> Array.cons (Array.catMaybes (Array.take i parts)) (splitFeet (Array.drop (i + 1) parts))
    isFoot = case _ of
      Nothing -> true
      Just _ -> false

-- | A part: Haskell's `pPart`, `(pSingle <|> pPolyIn <|> pPolyOut <|> pVar)
-- | >>= pE >>= pRand`, with the type's own atom parser.
pPart :: forall a. AtomParseable a => TidalParser (TPat a)
pPart = defer \_ -> pPartWith patternParser

-- | `pPart` over a given atom parser, as Haskell's `pPart f`: how a chord's
-- | root, name and modifiers are each a whole part (`<c e>'<major minor>`).
pPartWith :: forall a. AtomParseable a => TidalParser (TPat a) -> TidalParser (TPat a)
pPartWith f = defer \_ ->
  ((pSingleWith f <|> pPolyIn <|> pPolyOut <|> pVar) >>= pE) >>= pRand

-- | An atom or a rest, then `?` and `*`/`/`: Haskell's `pSingle`.
pSingle :: forall a. AtomParseable a => TidalParser (TPat a)
pSingle = defer \_ -> pSingleWith patternParser

-- | `pSingle` over a given atom parser, with Haskell's `parseRest`: a `-`
-- | is a negative sign when what follows it (after any spaces) is not
-- | another `-` and parses as an atom; otherwise a rest.
pSingleWith :: forall a. TidalParser (TPat a) -> TidalParser (TPat a)
pSingleWith f = defer \_ -> (restOrAtom >>= pRand) >>= pMult
  where
    restOrAtom =
      tryT (liftP (Parsec.lookAhead (char '-' *> Parsec.spaces *> noneOf [ '-' ])) *> f)
        <|> dash
        <|> f
        <|> tilde
    dash = do
      Tuple span _ <- spanned (liftP (char '-'))
      pure (TPat_Silence span)
    tilde = do
      Tuple span _ <- spanned (liftP (char '~'))
      pure (TPat_Silence span)

-------------------------------------------------------------------------------
-- Atoms
-------------------------------------------------------------------------------

-- | Parse an atom using the type-appropriate parser
pAtom :: forall a. AtomParseable a => TidalParser (TPat a)
pAtom = TPat_Atom <$> atomParser

-- | Parse silence: ~ or - (dash only when not followed by digit)
pSilence :: forall a. TidalParser (TPat a)
pSilence = do
  Tuple span _ <- spanned $ liftP (tilde <|> dash)
  pure $ TPat_Silence span
  where
    tilde = void $ char '~'
    -- Dash is silence only when NOT followed by a digit (otherwise it's negation)
    dash = Parsec.try do
      _ <- char '-'
      -- Peek ahead - fail if followed by digit
      Parsec.notFollowedBy digit
      pure unit

-- | Parse a variable reference: ^name
pVar :: forall a. TidalParser (TPat a)
pVar = do
  Tuple span name <- spanned do
    _ <- liftP $ char '^'
    cs <- liftP $ Parsec.many (alphaNum <|> satisfy \c -> c == '.' || c == '-' || c == '_' || c == ':')
    pure $ ControlName $ SCU.fromCharArray cs
  pure $ TPat_Var span name

-------------------------------------------------------------------------------
-- Chords (Note-specific parsing)
-------------------------------------------------------------------------------

-- | Parse a chord: c'major, e'minor, 'major (defaults to C)
-- |
-- | Returns a TPat_Stack of notes for the chord.
-- |
-- | Syntax:
-- | - `c'major` - C major chord (notes: 0, 4, 7)
-- | - `e'minor` - E minor chord (notes: 4, 7, 11)
-- | - `fs'dim` - F# diminished
-- | - `'major` - Major chord starting from C (root = 0)
pNoteChord :: TidalParser (TPat Note)
pNoteChord = tryT $ do
  Tuple span (Tuple root intervals) <- spanned do
    -- Parse optional root note
    root <- optionT 0 pNoteRoot
    -- Parse chord separator and name
    _ <- liftP $ char '\''
    chordName <- liftP $ Parsec.many1 (alphaNum <|> satisfy \c -> c == '7' || c == '9')
    let name = SCU.fromCharArray chordName
    case lookupChord name of
      Just ints -> do
        -- Parse optional modifiers (each prefixed with ')
        mods <- liftP $ Parsec.many parseModifierGroup
        pure $ Tuple root (applyModifiers (Array.concat mods) ints)
      Nothing -> liftP $ Parsec.fail $ "unknown chord: " <> name
  -- Build stack of notes
  let notes = map (\interval -> noteAtom span (root + interval)) intervals
  case Array.length notes of
    0 -> liftP $ Parsec.fail "empty chord"
    1 -> case Array.head notes of
           Just n -> pure n
           Nothing -> liftP $ Parsec.fail "empty chord"
    _ -> pure $ TPat_Stack span notes
  where
    -- Create a single note atom
    noteAtom :: SourceSpan -> Int -> TPat Note
    noteAtom s pitch = TPat_Atom (Located s (mkNote pitch))

    -- Parse root note: c, d, e, f, g, a, b with optional accidentals and octave
    pNoteRoot :: TidalParser Int
    pNoteRoot = liftP $ Parsec.try do
      base <- noteBase
      mods <- Parsec.many noteModifier
      oct <- Parsec.option 5 (Int.round <$> number)
      pure $ base + Array.foldl (+) 0 mods + (oct - 5) * 12

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
      n <- pIntRaw
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
      n <- pIntRaw
      pure [Drop n]

    -- Parse a number alone as range
    parseRange :: TidalParser (Array Modifier)
    parseRange = do
      n <- pIntRaw
      pure [Range n]

    -- Parse a positive integer (raw parser, not TidalParser)
    pIntRaw :: TidalParser Int
    pIntRaw = do
      digits <- Parsec.many1 digit
      case Int.fromString (SCU.fromCharArray digits) of
        Just n -> pure n
        Nothing -> Parsec.fail "expected integer"

    -- Base note values
    noteBase :: TidalParser Int
    noteBase = do
      c <- satisfy \x -> x >= 'a' && x <= 'g' || x >= 'A' && x <= 'G'
      case toLower c of
        'c' -> pure 0
        'd' -> pure 2
        'e' -> pure 4
        'f' -> pure 5
        'g' -> pure 7
        'a' -> pure 9
        'b' -> pure 11
        _   -> Parsec.fail "expected note name"

    -- Accidentals
    noteModifier :: TidalParser Int
    noteModifier = do
      c <- satisfy \x -> x == 's' || x == 'f' || x == 'n'
      pure $ case c of
        's' -> 1    -- sharp
        'f' -> (-1) -- flat
        _   -> 0    -- natural

    toLower :: Char -> Char
    toLower c
      | c >= 'A' && c <= 'G' = case charFromCode (charCode c + 32) of
          Just lc -> lc
          Nothing -> c
      | otherwise = c

    charCode :: Char -> Int
    charCode = toCharCode

    charFromCode :: Int -> Maybe Char
    charFromCode = fromCharCode

-------------------------------------------------------------------------------
-- Modifiers
-------------------------------------------------------------------------------

-- | Speed modifiers: *n (fast) or /n (slow)
pMult :: forall a. TPat a -> TidalParser (TPat a)
pMult thing = fast <|> slow <|> pure thing
  where
    -- Haskell: `pRational <|> pPolyIn pRational <|> pPolyOut pRational`.
    rate = pRationalTPat <|> pPolyIn <|> pPolyOut
    fast = do
      start <- getPos
      _ <- liftP $ char '*'
      spaces
      r <- rate
      end <- getPos
      pure $ TPat_Fast (mkSourceSpan start end) r thing

    slow = do
      start <- getPos
      _ <- liftP $ char '/'
      spaces
      r <- rate
      end <- getPos
      pure $ TPat_Slow (mkSourceSpan start end) r thing

-- | Degradation: ?prob (default 0.5)
pRand :: forall a. TPat a -> TidalParser (TPat a)
pRand thing = degrade <|> pure thing
  where
    degrade = do
      start <- getPos
      _ <- liftP $ char '?'
      prob <- optionT 0.5 pNumber
      spaces
      seed <- newSeed
      end <- getPos
      pure $ TPat_DegradeBy (mkSourceSpan start end) seed prob thing

-- | Euclidean rhythm: (n,k) or (n,k,s)
pE :: forall a. TPat a -> TidalParser (TPat a)
pE thing = euclidean <|> pure thing
  where
    euclidean = do
      start <- getPos
      Tuple _ (Tuple3 n k s) <- spanned $ parens do
        n' <- pSequence
        _ <- symbol ","
        k' <- pSequence
        s' <- optionT (intAtom 0) do
          _ <- symbol ","
          pSequence
        pure $ Tuple3 n' k' s'
      end <- getPos
      pure $ TPat_Euclid (mkSourceSpan start end) n k s thing

    intAtom :: Int -> TPat Int
    intAtom n = TPat_Atom (Located (mkSourceSpan { line: 0, column: 0 } { line: 0, column: 0 }) n)

-- | Helper for Tuple3
data Tuple3 a b c = Tuple3 a b c

-- | Elongation: `@r` or `_`, accumulating, as Haskell's `pElongate`; `r` is
-- | an exact ratio (`@1%6`, `@1.5`, `@h`).
pElongate :: forall a. TPat a -> TidalParser (TPat a)
pElongate a = do
  start <- getPos
  rs <- liftP $ Parsec.many1 elongateOne
  end <- getPos
  pure $ TPat_Elongate (mkSourceSpan start end) (one + Array.foldr (+) zero rs) a
  where
    elongateOne = do
      _ <- satisfy \c -> c == '@' || c == '_'
      r <- Parsec.option one ((_ - one) <$> pRatio)
      Parsec.spaces
      pure r

-- | Repetition: !n (default !1 means duplicate once)
pRepeat :: forall a. TPat a -> TidalParser (TPat a)
pRepeat a = do
  start <- getPos
  ns <- liftP $ Parsec.many1 repeatOne
  end <- getPos
  let total = 1 + Array.foldr (+) 0 ns
  pure $ TPat_Repeat (mkSourceSpan start end) total a
  where
    repeatOne = do
      _ <- char '!'
      n <- Parsec.option 1 ((\x -> x - 1) <$> intParser)
      Parsec.spaces
      pure n

    intParser :: TidalParser Int
    intParser = do
      digits <- Parsec.many1 digit
      case Int.fromString (SCU.fromCharArray digits) of
        Just n -> pure n
        Nothing -> Parsec.fail "expected integer"

-- | Enumeration: a .. b
pEnumeration :: forall a. AtomParseable a => TPat a -> TidalParser (TPat a)
pEnumeration a = do
  start <- getPos
  _ <- tryT $ symbol ".."
  b <- pPart
  end <- getPos
  pure $ TPat_EnumFromTo (mkSourceSpan start end) a b

-------------------------------------------------------------------------------
-- Grouping
-------------------------------------------------------------------------------

-- | Grouping: [a b c]
pPolyIn :: forall a. AtomParseable a => TidalParser (TPat a)
pPolyIn = defer \_ -> do
  x <- brackets pTidal
  pMult x

-- | Polyrhythm: {a b, c d} or {a b}%ratio or <a b> (alternate)
pPolyOut :: forall a. AtomParseable a => TidalParser (TPat a)
pPolyOut = defer \_ -> braces_ <|> angles_
  where
    braces_ = do
      Tuple span seqs <- spanned $ braces (pSequence `sepByT` symbol ",")
      mRatio <- optionalT do
        _ <- liftP $ char '%'
        pSequence
      result <- pMult $ TPat_Polyrhythm span mRatio seqs
      pure result

    angles_ = do
      Tuple span seqs <- spanned $ angles do
        pSequence `sepByT` symbol ","
      let one = TPat_Atom (Located (mkSourceSpan { line: 0, column: 0 } { line: 0, column: 0 }) (1 % 1))
      pMult $ TPat_Polyrhythm span (Just one) seqs

-------------------------------------------------------------------------------
-- Primitive value parsers
-------------------------------------------------------------------------------

-- | Parse a rational number as TPat
pRationalTPat :: TidalParser (TPat Rational)
pRationalTPat = defer \_ -> do
  loc <- located pRational
  pure $ TPat_Atom loc

-- | Parse an integer as TPat
pIntTPat :: TidalParser (TPat Int)
pIntTPat = defer \_ -> do
  loc <- located pInt
  pure $ TPat_Atom loc

-- | Parse a rational number
pRational :: TidalParser Rational
pRational = do
  n <- pNumber
  mDenom <- optionalT do
    _ <- liftP $ char '%'
    pNumber
  pure $ case mDenom of
    Just d -> Int.round (n * 1000.0) % Int.round (d * 1000.0)
    Nothing -> Int.round (n * 1000.0) % 1000

-- | Optional combinator for TidalParser
optionalT :: forall a. TidalParser a -> TidalParser (Maybe a)
optionalT p = (Just <$> p) <|> pure Nothing

-- | Option combinator for TidalParser (default value if parser fails)
optionT :: forall a. a -> TidalParser a -> TidalParser a
optionT def p = p <|> pure def

-- | Many combinator for TidalParser (returns Array instead of List)
manyT :: forall a. TidalParser a -> TidalParser (Array a)
manyT p = go []
  where
    go acc = (p >>= \x -> go (Array.snoc acc x)) <|> pure acc

-- | Some combinator for TidalParser (one or more, returns Array)
someT :: forall a. TidalParser a -> TidalParser (Array a)
someT p = do
  first <- p
  rest <- manyT p
  pure $ Array.cons first rest

-- | SepBy combinator for TidalParser (returns Array)
sepByT :: forall a sep. TidalParser a -> TidalParser sep -> TidalParser (Array a)
sepByT p sep = do
  first <- optionalT p
  case first of
    Nothing -> pure []
    Just f -> do
      rest <- manyT (sep *> p)
      pure $ Array.cons f rest

-- | Parsec's `try`: a consumed failure becomes an unconsumed one.
tryT :: forall a. TidalParser a -> TidalParser a
tryT = Parsec.try

-- | Parse an integer
pInt :: TidalParser Int
pInt = do
  sign <- (liftP (char '-') $> (-1)) <|> pure 1
  digits <- liftP $ Parsec.many1 digit
  case Int.fromString (SCU.fromCharArray digits) of
    Just n -> pure (sign * n)
    Nothing -> liftP $ Parsec.fail "expected integer"

-- | Parse a number (decimal)
pNumber :: TidalParser Number
pNumber = do
  sign <- (liftP (char '-') $> (-1.0)) <|> pure 1.0
  n <- liftP number
  pure (sign * n)
