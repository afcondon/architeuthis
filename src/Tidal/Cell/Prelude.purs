-- | Prelude for generated cell modules.
-- |
-- | A cell's source is the right-hand-side of its `pattern` binding;
-- | the surrounding template imports just this module.  Everything
-- | a cell can reach lives here: the `Pattern` type, the discrete-
-- | pattern combinators (`fast`, `slow`, `rev`, `fastCat`, `stack`,
-- | `every`, `iter`, …), the typed `PitchedNote12` carrier with its `mini` /
-- | `n` / `d` parsers, and the active-scale operators (`inKey`,
-- | `transposeDiatonic`, `transposeChromatic`) from `Tidal.Substrate.Scales`.
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
  , module Tidal.Substrate.Scales
  , module Tidal.Tintinnabuli
  , module Tidal.Emit
  -- Typed-`Sound` surface: the source / control verbs (`s`/`sound`/
  -- `drum`/`n`/`gain`/…) + the typed `#` merge, plus the `Sound`/`Token`
  -- types and bridge helpers.  Imported `hiding` the `Sound`-level
  -- `degree`/`note`/`pitch` verbs and the `Pitch` constructors, which
  -- would clash with the `PitchedNote12`-typed `pitch`/`degree` from
  -- `Tidal.Pitch.Parse` above — pitched authoring stays on that
  -- carrier so the scale machinery (`inKey`/transpose) is unchanged.
  , module Tidal.Sound
  , r
  ) where

-- We deliberately don't import Prelude here.  Tidal.Pattern.Core
-- has a few names (append) that would collide; cells import their
-- own Prelude through the cell template, which is the right place
-- for it.
import Haskell.Rational (Rational, fromInt)
import Haskell.Rational (fromInt) as DataRational
import Tidal.Pattern.Types
import Tidal.Pattern.Core
import Tidal.DejaVu
import Tidal.LiveControl
import Tidal.Random
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Pitch.Parse (pitch, degree)
import Tidal.Substrate.Scales
  ( Scale(..)
  , mkScale, mkScaleP
  , Distribution(..)
  , quantiseToScale, applyDistribution
  , renderDegree
  , inKey
  , quantiseInKey
  , transposeDiatonic
  , transposeChromatic
  , octave
  , cChromatic
  , cMajor, cMinor, cMixolydian, cDorian, cPhrygian, cLydian
  , cAeolian, cLocrian, cHarmonicMinor, cHarmonicMajor, cMelodicMinor
  , dMajor, dMinor, dDorian, dMixolydian
  , eMinor, eDorian, eMixolydian, ePhrygian
  , fMajor, fLydian, fMixolydian
  , gMajor, gMixolydian, gMinor, gDorian
  , aMajor, aMinor, aMixolydian, aDorian, aHarmonicMinor
  , cPhrygianDomLT, cMajorTriad3oct
  , bMinor, bDorian, bLocrian
  )
import Tidal.Tintinnabuli
  ( Triad
  , triad
  , Position(..)
  , above1, above2, above3
  , below1, below2, below3
  , tintinnabuli
  , cMajT, cMinT
  , dMajT, dMinT
  , eMajT, eMinT
  , fMajT, fMinT
  , gMajT, gMinT
  , aMajT, aMinT
  , bMajT, bMinT, bDimT
  )
import Tidal.Sound hiding (degree, note, pitch, Pitch(..))
import Tidal.Emit
  ( class Emitable, noteName
  , class ToMidiNote, toMidiNote
  , class ToVPerOctVolts, toVPerOctVolts
  , class ToOscSample, toOscSample
  )

-- | Short alias for `Data.Rational.fromInt`.  `fast` and `slow` take
-- | a `Rational`, so `fast (r 2) (mini "bd sn")` is the cell idiom.
-- | The unaliased `fromInt` is also re-exported.
r :: Int -> Rational
r = fromInt
