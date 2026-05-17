-- | Tidal.Tintinnabuli — Arvo Pärt's mechanical 1→1 T-voice rule.
-- |
-- | Given a stepwise melody (the M-voice) and a fixed triad, generate
-- | a parallel T-voice in which each note is the nearest triad pitch
-- | in a chosen `Position` relative to its M-voice partner.  This is
-- | the simplest possible illustration of the pitch substrate: just
-- | `map` over a `Pattern Pitch` with a function `Pitch -> Pitch`.
-- |
-- | Background: in Pärt's tintinnabuli style (Tabula Rasa, Spiegel im
-- | Spiegel, Cantus, …) two voices move together — the M-voice plays
-- | stepwise melodic motion, and the T-voice plays notes from a fixed
-- | triad chosen at one of several "Positions":
-- |
-- |   * Position 1 Superior  — nearest triad note **above** the melody
-- |   * Position 1 Inferior  — nearest triad note **below** the melody
-- |   * Position 2 Superior  — second-nearest above
-- |   * Position 2 Inferior  — second-nearest below
-- |
-- | The triad is fixed for the whole piece; Pärt typically uses the
-- | minor triad of the home key (A-minor for Tabula Rasa).
-- |
-- | Usage:
-- |
-- |     melody :: Pattern Pitch
-- |     melody = mini "a4 b4 c5 b4 a4 g4 f4 e4"
-- |
-- |     tVoice :: Pattern Pitch
-- |     tVoice = tintinnabuli aMinT above1 melody
-- |
-- | The function is pure `map`; all time structure (`fast`, `slow`,
-- | `every`, `rev`, …) applies to the M-voice and the T-voice picks
-- | it up via the pattern functor.
module Tidal.Tintinnabuli
  ( Triad
  , triad
  , triadPitchClasses
  , Position(..)
  , above1, above2, above3
  , below1, below2, below3
  , tintinnabuli
  , tintinnabuliPitch
  -- Common named triads (T-suffix to avoid collision with Scale names
  -- like `aMinor` in Tidal.Scales).
  , cMajT, cMinT
  , dMajT, dMinT
  , eMajT, eMinT
  , fMajT, fMinT
  , gMajT, gMinT
  , aMajT, aMinT
  , bMajT, bMinT, bDimT
  ) where

import Prelude

import Data.Array (filter, nub, range, reverse, sort, (!!))
import Data.Foldable (elem)
import Data.Maybe (fromMaybe)

import Tidal.Chords (major, minor, dim)
import Tidal.Pattern.Types (Pattern)
import Tidal.Pitch (Pitch(..))

-- ---------------------------------------------------------------------------
-- Triad
-- ---------------------------------------------------------------------------

-- | A triad represented as the set of its pitch classes (0..11).
-- | Carries no octave, no inversion, no voicing — just the three (or
-- | four, for sevenths) pitch classes whose membership the nearest-
-- | note algorithm checks against.
-- |
-- | Construct with `triad rootPc intervals`, where `intervals` is a
-- | chord-shape from `Tidal.Chords` (`minor`, `major`, `dim`, …).
-- | The constants below cover the common minor/major/diminished
-- | triads of every diatonic root.
newtype Triad = Triad (Array Int)

-- | Recover the pitch-class set.  Useful for debugging and tests.
triadPitchClasses :: Triad -> Array Int
triadPitchClasses (Triad pcs) = pcs

-- | Build a triad from a root pitch-class (0=C..11=B) and a chord-
-- | shape (intervals from root, e.g. `minor` = `[0,3,7]`).  Intervals
-- | are wrapped mod 12 and deduplicated, so seventh- and ninth-chord
-- | shapes (which add `10`, `11`, `14`, …) collapse to the right
-- | three- or four-note pitch-class set automatically.
triad :: Int -> Array Int -> Triad
triad rootPc intervals =
  Triad (sort (nub (map (\i -> mod (rootPc + i) 12) intervals)))

-- ---------------------------------------------------------------------------
-- Position
-- ---------------------------------------------------------------------------

-- | The T-voice's position relative to the M-voice.  `Above k` means
-- | "the k-th triad note strictly above the melody note", `Below k`
-- | the mirror.  Pärt's nomenclature: Position 1 Superior = `Above 1`,
-- | Position 2 Inferior = `Below 2`, etc.
data Position = Above Int | Below Int

derive instance eqPosition :: Eq Position
derive instance ordPosition :: Ord Position

instance showPosition :: Show Position where
  show = case _ of
    Above n -> "Above " <> show n
    Below n -> "Below " <> show n

above1 :: Position
above1 = Above 1
above2 :: Position
above2 = Above 2
above3 :: Position
above3 = Above 3
below1 :: Position
below1 = Below 1
below2 :: Position
below2 = Below 2
below3 :: Position
below3 = Below 3

-- ---------------------------------------------------------------------------
-- The mechanical rule
-- ---------------------------------------------------------------------------

-- | Compute the T-voice pitch for a single M-voice pitch.
-- |
-- |   * `Chromatic n` — look up the k-th triad pitch class strictly
-- |     above (or below) `n` in MIDI space.  Falls back to `n` itself
-- |     if no candidate is found within ±24 semitones (shouldn't
-- |     happen for any sensible triad).
-- |   * `Sample s` — passes through unchanged.  Drums shouldn't go
-- |     through tintinnabuli; if they accidentally do, we don't crash.
-- |   * `Degree d` — passes through unchanged.  Degrees don't know
-- |     their MIDI note until emit time, so applying tintinnabuli to
-- |     them is meaningless at substrate level.  If you want a
-- |     degree-based melody to drive a T-voice, render the melody to
-- |     chromatic first via `inKey` and tintinnabuli operates on the
-- |     rendered chromatic stream.
tintinnabuliPitch :: Triad -> Position -> Pitch -> Pitch
tintinnabuliPitch t pos = case _ of
  Chromatic n -> Chromatic (nearestTriadNote t pos n)
  other       -> other

-- | Map `tintinnabuliPitch` over a pattern.  The pattern's time
-- | structure is untouched — `tintinnabuli t pos (every 4 rev melody)`
-- | works: the M-voice's reverse mirrors into the T-voice naturally.
tintinnabuli :: Triad -> Position -> Pattern Pitch -> Pattern Pitch
tintinnabuli t pos = map (tintinnabuliPitch t pos)

-- | The numeric workhorse.  Walk MIDI space outward from `melody` in
-- | the chosen direction and pick the k-th note whose pitch class is
-- | a triad member.  Strict inequality: a melody note that happens to
-- | sit on a triad is *not* its own T-voice; the rule still finds the
-- | next triad note in the chosen direction.
nearestTriadNote :: Triad -> Position -> Int -> Int
nearestTriadNote (Triad pcs) pos melody = case pos of
  Above k ->
    let cands = filter (\n -> elem (mod n 12) pcs)
                       (range (melody + 1) (melody + 24))
    in fromMaybe melody (cands !! (k - 1))
  Below k ->
    let cands = filter (\n -> elem (mod n 12) pcs)
                       (reverse (range (melody - 24) (melody - 1)))
    in fromMaybe melody (cands !! (k - 1))

-- ---------------------------------------------------------------------------
-- Common named triads — T suffix to avoid colliding with Scale names
-- (Tidal.Scales already exports `aMinor`, `cMajor`, …).
-- ---------------------------------------------------------------------------

cMajT :: Triad
cMajT = triad 0 major
cMinT :: Triad
cMinT = triad 0 minor

dMajT :: Triad
dMajT = triad 2 major
dMinT :: Triad
dMinT = triad 2 minor

eMajT :: Triad
eMajT = triad 4 major
eMinT :: Triad
eMinT = triad 4 minor

fMajT :: Triad
fMajT = triad 5 major
fMinT :: Triad
fMinT = triad 5 minor

gMajT :: Triad
gMajT = triad 7 major
gMinT :: Triad
gMinT = triad 7 minor

aMajT :: Triad
aMajT = triad 9 major
aMinT :: Triad
aMinT = triad 9 minor

bMajT :: Triad
bMajT = triad 11 major
bMinT :: Triad
bMinT = triad 11 minor
bDimT :: Triad
bDimT = triad 11 dim
