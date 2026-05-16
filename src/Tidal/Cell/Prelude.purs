-- | Prelude for generated cell modules.
-- |
-- | A cell's source is the right-hand-side of its `pattern` binding;
-- | the surrounding template imports just this module.  Everything
-- | a cell can reach lives here: the `Pattern` type, the discrete-
-- | pattern combinators (`fast`, `slow`, `rev`, `fastCat`, `stack`,
-- | `every`, `iter`, …), the typed `Pitch` carrier with its `mini` /
-- | `n` / `d` parsers, and the active-scale operators (`inKey`,
-- | `transposeDiatonic`, `transposeChromatic`) from `Tidal.Scales`.
-- |
-- | Re-exports `Tidal.Pattern.Types` and `Tidal.Pattern.Core` in
-- | bulk — anything those modules expose is reachable from a cell.
-- | Full PureScript-as-cell-language is the long-term direction (see
-- | the architectural-bet doc in calypso/docs); user-defined helpers
-- | promoted from cells into the prelude is the natural follow-up
-- | once cell bodies start sharing structure.
module Tidal.Cell.Prelude
  ( module Tidal.Pattern.Types
  , module Tidal.Pattern.Core
  , module DataRational
  , module Tidal.DejaVu
  , module Tidal.LiveControl
  , module Tidal.Random
  , module Tidal.Pitch
  , module Tidal.Pitch.Parse
  , module Tidal.Scales
  , r
  ) where

-- We deliberately don't import Prelude here.  Tidal.Pattern.Core
-- has a few names (append) that would collide; cells import their
-- own Prelude through the cell template, which is the right place
-- for it.
import Data.Rational (Rational, fromInt)
import Data.Rational (fromInt) as DataRational
import Tidal.Pattern.Types
import Tidal.Pattern.Core
import Tidal.DejaVu
import Tidal.LiveControl
import Tidal.Random
import Tidal.Pitch (Pitch(..))
import Tidal.Pitch.Parse (mini, n, d)
import Tidal.Scales
  ( Scale(..)
  , inKey
  , transposeDiatonic
  , transposeChromatic
  , octave
  , cMajor, cMinor, cMixolydian, cDorian, cPhrygian, cLydian
  , cAeolian, cLocrian, cHarmonicMinor, cHarmonicMajor, cMelodicMinor
  , dMajor, dMinor, dDorian, dMixolydian
  , eMinor, eDorian, eMixolydian, ePhrygian
  , fMajor, fLydian, fMixolydian
  , gMajor, gMixolydian, gMinor, gDorian
  , aMajor, aMinor, aMixolydian, aDorian, aHarmonicMinor
  , bMinor, bDorian, bLocrian
  )

-- | Short alias for `Data.Rational.fromInt`.  `fast` and `slow` take
-- | a `Rational`, so `fast (r 2) (mini "bd sn")` is the cell idiom.
-- | The unaliased `fromInt` is also re-exported.
r :: Int -> Rational
r = fromInt
