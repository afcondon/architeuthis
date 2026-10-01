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

import Tidal.AST.Types (TPat(..))
import Tidal.Parse.Class (class AtomParseable, liftP, located)
import Tidal.Parse.Numbers (parseIntNote, pDouble, pNote, pVocable)
import Tidal.Pattern.Types (class TidalEnum, enumRange)

newtype Vocable = Vocable String
newtype TDouble = TDouble Number
newtype TNote = TNote Number
newtype TInt = TInt Int

derive instance Eq Vocable
derive instance Eq TDouble
derive instance Eq TNote
derive instance Eq TInt

instance AtomParseable Vocable where
  atomParser = located (liftP (Vocable <$> pVocable))
  patternParser = TPat_Atom <$> located (liftP (Vocable <$> pVocable))

instance AtomParseable TDouble where
  atomParser = located (liftP (TDouble <$> pDouble))
  patternParser = TPat_Atom <$> located (liftP (TDouble <$> pDouble))

instance AtomParseable TNote where
  atomParser = located (liftP (TNote <$> pNote))
  patternParser = TPat_Atom <$> located (liftP (TNote <$> pNote))

instance AtomParseable TInt where
  atomParser = located (liftP (TInt <$> parseIntNote))
  patternParser = TPat_Atom <$> located (liftP (TInt <$> parseIntNote))

-- | Strings enumerate as the two ends, as Tidal's `fromTo` for String.
instance TidalEnum Vocable where
  enumRange a b = [ a, b ]

instance TidalEnum TDouble where
  enumRange (TDouble a) (TDouble b) = map TDouble (enumRange a b)

instance TidalEnum TNote where
  enumRange (TNote a) (TNote b) = map TNote (enumRange a b)

instance TidalEnum TInt where
  enumRange (TInt a) (TInt b) = map TInt (enumRange a b)

