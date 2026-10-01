-- | **Haskell Tidal's mini-notation atoms, exactly.**
-- |
-- | Ports of the atom parsers in Tidal 1.10.1's `Sound.Tidal.ParseBP`, as
-- | the line language (`Tidal.Line`, Limulus) reads a control's string at
-- | the control's type:
-- |
-- | - `Vocable`, Tidal's `String` (`pVocable`): a letter or digit, then
-- |   letters, digits and `:.-_`.
-- | - `TDouble`, Tidal's `Double` (`pDouble`): a sign, then `pRatio` (an int
-- |   or float, an optional `%` denominator, an optional duration letter:
-- |   `3h` is 1.5, `e` alone 0.125, `1e3` 1000) or else a note name.
-- | - `TNote`, Tidal's `Note` (`pNote`): a sign, then an int or float or a
-- |   note name (`e` is 4 here), else a ratio.
-- | - `TInt`, Tidal's `Int` (`parseIntNote`): as a note, but whole.
-- |
-- | Numbers are read exactly, as rationals, before any conversion. The
-- | legacy atoms in `Tidal.Parse.Class` keep their extensions (`f#2`,
-- | chord strings) for the typed-cue path; these are what Tidal reads.
module Tidal.Parse.Haskell
  ( Vocable(..)
  , TDouble(..)
  , TNote(..)
  , TInt(..)
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Lazy (defer)
import Haskell.Parsec (Parsec, char)
import Tidal.Parse.State (ParseState)
import Haskell.Rational (toNumber)
import Data.Tuple (Tuple(..))
import Tidal.AST.Types (Located(..), TPat(..))
import Tidal.Chords (Modifiers)
import Tidal.Core.Types (emptySpan)
import Tidal.Parse.Class (class AtomParseable, TidalParser, liftP, located, patternParser)
import Tidal.Parse.Combinators (manyT, pPartWith, spanned, tryT)
import Tidal.Parse.Numbers (parseIntNote, pDouble, pNote, pNoteWithoutChord, pRatio, pVocable)
import Tidal.Pattern.Types (class TidalEnum, addSemitones, enumRange)

newtype Vocable = Vocable String
newtype TDouble = TDouble Number
newtype TNote = TNote Number
newtype TInt = TInt Int

derive instance Eq Vocable
derive instance Eq TDouble
derive instance Eq TNote
derive instance Eq TInt

type P = Parsec ParseState

instance AtomParseable Vocable where
  atomParser = located (liftP (Vocable <$> pVocable))
  patternParser = TPat_Atom <$> located (liftP (Vocable <$> pVocable))

instance AtomParseable TDouble where
  atomParser = located (liftP (TDouble <$> pDouble))
  patternParser = defer \_ -> withChords (atom (TDouble <$> pDouble)) (TDouble 0.0)

-- | `pNote`: as `pDouble`, then a ratio as a last resort.
instance AtomParseable TNote where
  atomParser = located (liftP (TNote <$> pNote))
  patternParser = defer \_ ->
    withChords (atom (TNote <$> pNoteWithoutChord)) (TNote 0.0)
      <|> atom (TNote <<< toNumber <$> pRatio)

instance AtomParseable TInt where
  atomParser = located (liftP (TInt <$> parseIntNote))
  patternParser = defer \_ -> withChords (atom (TInt <$> parseIntNote)) (TInt 0)

atom :: forall a. P a -> TidalParser (TPat a)
atom p = TPat_Atom <$> located (liftP p)

-- | Haskell's `pDouble`/`pNote`/`pIntegral` shape: a root part, then
-- | perhaps a chord; or a chord on a root of 0 (`'major`); or the part.
withChords :: forall a. AtomParseable a => TidalParser (TPat a) -> a -> TidalParser (TPat a)
withChords f zero =
  tryT (pPartWith f >>= \root -> pChord root <|> pure root)
    <|> pChord (TPat_Atom (Located emptySpan zero))
    <|> pPartWith f

-- | `pChord`: `'`, a chord name part, then `'`-separated modifier parts.
pChord :: forall a. TPat a -> TidalParser (TPat a)
pChord root = do
  Tuple span (Tuple name mods) <- spanned do
    _ <- liftP (char '\'')
    name <- pPartWith (atom (Vocable <$> pVocable))
    mods <- manyT (liftP (char '\'') *> pPartWith (patternParser :: TidalParser (TPat Modifiers)))
    pure (Tuple name mods)
  pure (TPat_Chord span root (map (\(Vocable v) -> v) name) mods)

-- | Strings enumerate as the two ends, as Tidal's `fromTo` for String.
instance TidalEnum Vocable where
  enumRange a b = [ a, b ]
  addSemitones _ x = x

instance TidalEnum TDouble where
  enumRange (TDouble a) (TDouble b) = map TDouble (enumRange a b)
  addSemitones k (TDouble x) = TDouble (addSemitones k x)

instance TidalEnum TNote where
  enumRange (TNote a) (TNote b) = map TNote (enumRange a b)
  addSemitones k (TNote x) = TNote (addSemitones k x)

instance TidalEnum TInt where
  enumRange (TInt a) (TInt b) = map TInt (enumRange a b)
  addSemitones k (TInt x) = TInt (x + k)

