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
  , pSingle
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
import Control.Monad.State.Trans (mapStateT)
import Control.Monad.Trans.Class (lift)
import Data.Array as Array
import Data.Char (toCharCode, fromCharCode)
import Data.Identity (Identity)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, (%))
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))
import Text.Parsing.Parser (ParserT)
import Text.Parsing.Parser as P
import Text.Parsing.Parser.Combinators as PC
import Text.Parsing.Parser.String (char, satisfy, string, skipSpaces)
import Text.Parsing.Parser.Token (alphaNum, digit)
import Tidal.AST.Types (Located(..), TPat(..), SourceSpan, tpatSpan)
import Tidal.Chords (lookupChord)
import Tidal.Core.Types (ControlName(..), SourcePos)
import Tidal.Parse.Class (class AtomParseable, atomParser, patternParser, TidalParser, number)
import Tidal.Parse.State (currentPos, mkSourceSpan, newSeed)
import Tidal.Pattern.Types (Note, mkNote)

-- | Lift a parser operation into TidalParser
liftP :: forall a. ParserT String Identity a -> TidalParser a
liftP = lift

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
spaces = liftP skipSpaces

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
-- | A pattern is a sequence optionally followed by stack (,) or choose (|) operators.
pTidal :: forall a. AtomParseable a => TidalParser (TPat a)
pTidal = defer \_ -> do
  s <- pSequence
  stackTail s <|> chooseTail s <|> pure s
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

-- | Parse a sequence of parts
pSequence :: forall a. AtomParseable a => TidalParser (TPat a)
pSequence = defer \_ -> do
  Tuple span parts <- spanned do
    spaces
    manyT do
      a <- pPart
      spaces
      pEnumeration a <|> pElongate a <|> pRepeat a <|> pure a
  pure $ TPat_Seq span parts

-- | Parse a single part (atom, group, variable, etc.)
pPart :: forall a. AtomParseable a => TidalParser (TPat a)
pPart = defer \_ ->
  (pSingle >>= pE >>= pRand >>= pMult)
    <|> pPolyIn
    <|> pPolyOut
    <|> pVar

-- | Parse an atom with its modifiers (uses patternParser to support chords for Note)
pSingle :: forall a. AtomParseable a => TidalParser (TPat a)
pSingle = defer \_ -> patternParser <|> pSilence

-------------------------------------------------------------------------------
-- Atoms
-------------------------------------------------------------------------------

-- | Parse an atom using the type-appropriate parser
pAtom :: forall a. AtomParseable a => TidalParser (TPat a)
pAtom = TPat_Atom <$> atomParser

-- | Parse silence (only ~ now, - is for negation)
pSilence :: forall a. TidalParser (TPat a)
pSilence = do
  Tuple span _ <- spanned $ liftP (char '~')
  pure $ TPat_Silence span

-- | Parse a variable reference: ^name
pVar :: forall a. TidalParser (TPat a)
pVar = do
  Tuple span name <- spanned do
    _ <- liftP $ char '^'
    cs <- liftP $ Array.many (alphaNum <|> satisfy \c -> c == '.' || c == '-' || c == '_' || c == ':')
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
    chordName <- liftP $ Array.some (alphaNum <|> satisfy \c -> c == '7' || c == '9')
    let name = SCU.fromCharArray chordName
    case lookupChord name of
      Just intervals -> pure $ Tuple root intervals
      Nothing -> liftP $ P.fail $ "unknown chord: " <> name
  -- Build stack of notes
  let notes = map (\interval -> noteAtom span (root + interval)) intervals
  case Array.length notes of
    0 -> liftP $ P.fail "empty chord"
    1 -> case Array.head notes of
           Just n -> pure n
           Nothing -> liftP $ P.fail "empty chord"
    _ -> pure $ TPat_Stack span notes
  where
    -- Create a single note atom
    noteAtom :: SourceSpan -> Int -> TPat Note
    noteAtom s pitch = TPat_Atom (Located s (mkNote pitch))

    -- Parse root note: c, d, e, f, g, a, b with optional accidentals and octave
    pNoteRoot :: TidalParser Int
    pNoteRoot = liftP $ PC.try do
      base <- noteBase
      mods <- Array.many noteModifier
      oct <- PC.option 5 (Int.round <$> number)
      pure $ base + Array.foldl (+) 0 mods + (oct - 5) * 12

    -- Base note values
    noteBase :: ParserT String Identity Int
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
        _   -> P.fail "expected note name"

    -- Accidentals
    noteModifier :: ParserT String Identity Int
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
    fast = do
      start <- getPos
      _ <- liftP $ char '*'
      spaces
      r <- pRationalTPat
      end <- getPos
      pure $ TPat_Fast (mkSourceSpan start end) r thing

    slow = do
      start <- getPos
      _ <- liftP $ char '/'
      spaces
      r <- pRationalTPat
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
        n' <- pIntTPat
        _ <- symbol ","
        k' <- pIntTPat
        s' <- optionT (intAtom 0) do
          _ <- symbol ","
          pIntTPat
        pure $ Tuple3 n' k' s'
      end <- getPos
      pure $ TPat_Euclid (mkSourceSpan start end) n k s thing

    intAtom :: Int -> TPat Int
    intAtom n = TPat_Atom (Located (mkSourceSpan { line: 0, column: 0 } { line: 0, column: 0 }) n)

-- | Helper for Tuple3
data Tuple3 a b c = Tuple3 a b c

-- | Elongation: @n or _ (underscore extends by 1)
pElongate :: forall a. TPat a -> TidalParser (TPat a)
pElongate a = do
  start <- getPos
  rs <- liftP $ Array.some elongateOne
  end <- getPos
  let total = 1.0 + Array.foldr (+) 0.0 rs
  pure $ TPat_Elongate (mkSourceSpan start end) (toRational total) a
  where
    elongateOne = do
      _ <- satisfy \c -> c == '@' || c == '_'
      r <- PC.option 1.0 ((\x -> x - 1.0) <$> pRatioNum)
      skipSpaces
      pure r

    toRational :: Number -> Rational
    toRational n = Int.round (n * 1000.0) % 1000

    pRatioNum :: ParserT String Identity Number
    pRatioNum = number

-- | Repetition: !n (default !1 means duplicate once)
pRepeat :: forall a. TPat a -> TidalParser (TPat a)
pRepeat a = do
  start <- getPos
  ns <- liftP $ Array.some repeatOne
  end <- getPos
  let total = 1 + Array.foldr (+) 0 ns
  pure $ TPat_Repeat (mkSourceSpan start end) total a
  where
    repeatOne = do
      _ <- char '!'
      n <- PC.option 1 ((\x -> x - 1) <$> intParser)
      skipSpaces
      pure n

    intParser :: ParserT String Identity Int
    intParser = do
      digits <- Array.some digit
      case Int.fromString (SCU.fromCharArray digits) of
        Just n -> pure n
        Nothing -> P.fail "expected integer"

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
      Tuple span (Tuple seqs mRatio) <- spanned $ braces do
        seqs <- pSequence `sepByT` symbol ","
        ratio <- optionalT do
          _ <- liftP $ char '%'
          pRationalTPat
        pure $ Tuple seqs ratio
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

-- | Try combinator for TidalParser (backtracking)
-- |
-- | Uses mapStateT to lift PC.try through the StateT layer
tryT :: forall a. TidalParser a -> TidalParser a
tryT = mapStateT PC.try

-- | Parse an integer
pInt :: TidalParser Int
pInt = do
  sign <- (liftP (char '-') $> (-1)) <|> pure 1
  digits <- liftP $ Array.some digit
  case Int.fromString (SCU.fromCharArray digits) of
    Just n -> pure (sign * n)
    Nothing -> liftP $ P.fail "expected integer"

-- | Parse a number (decimal)
pNumber :: TidalParser Number
pNumber = do
  sign <- (liftP (char '-') $> (-1.0)) <|> pure 1.0
  n <- liftP number
  pure (sign * n)
