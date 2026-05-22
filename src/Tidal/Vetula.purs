-- | `Tidal.Vetula` — V-A slab.
-- |
-- | The harmonic vocabulary's *recipe* layer.  A `DegreeChord` is a
-- | scale-degree-relative chord recipe (numeral + quality + tensions +
-- | optional slash); `realize :: Key -> DegreeChord -> Chord` resolves
-- | it against a Key into a set of pitch classes.  No voicing, no
-- | voice leading, no emit — those are V-B onwards.
-- |
-- | Design ground rules — settled 2026-05-22:
-- |
-- |   * Slash, not inversion.  First-inversion of a triad is just a
-- |     slash with the 3rd as bass.
-- |   * Vetula can produce arbitrary-size chords; polyphony budget is
-- |     a sink concern, not a Vetula concern.
-- |   * Tensions are absolute (major / perfect) intervals from the
-- |     chord root.  `Add 7` is the major 7th; if you want a minor 7
-- |     chord, use the `Min7` quality.  `Sharp n` / `Flat n` shift the
-- |     default by ±1.  `Sus n` replaces the 3rd.
-- |   * `borrow Mode dc` rewrites the chord to be resolved in a
-- |     parallel mode (modal interchange); only affects the root
-- |     lookup, not the tension arithmetic.
-- |
-- | See `atlantis-site-planning/vetula-design.md` for the type-surface
-- | design and the McMullen Yellow worked example.
module Tidal.Vetula
  ( Numeral(..)
  , Quality(..)
  , Tension(..)
  , DegreeChord(..)
  , Mode(..)
  , Key
  , Chord(..)
  , numeralIndex
  , qualityIntervals
  , modeIntervals
  , defaultIntervalFor
  , realize
  , deg
  , slashed
  , borrow
  , cMajorKey
  , aMinorKey
  , mcmullenYellow
  ) where

import Prelude

import Data.Array (cons, filter, nub, sort, (!!))
import Data.Foldable (elem, foldl)
import Data.Maybe (Maybe(..), fromMaybe)

-- ---------------------------------------------------------------------------
-- Numeral — scale-degree position (I..VII)
-- ---------------------------------------------------------------------------

data Numeral = I | II | III | IV | V | VI | VII

derive instance eqNumeral :: Eq Numeral
derive instance ordNumeral :: Ord Numeral

instance showNumeral :: Show Numeral where
  show = case _ of
    I   -> "I"
    II  -> "II"
    III -> "III"
    IV  -> "IV"
    V   -> "V"
    VI  -> "VI"
    VII -> "VII"

-- | Zero-based index into the mode's interval array.
numeralIndex :: Numeral -> Int
numeralIndex = case _ of
  I   -> 0
  II  -> 1
  III -> 2
  IV  -> 3
  V   -> 4
  VI  -> 5
  VII -> 6

-- ---------------------------------------------------------------------------
-- Quality — the triad or seventh-chord type
-- ---------------------------------------------------------------------------

data Quality
  = Maj           -- major triad           [0, 4, 7]
  | Min           -- minor triad           [0, 3, 7]
  | Dim           -- diminished triad      [0, 3, 6]
  | Aug           -- augmented triad       [0, 4, 8]
  | Maj7          -- major 7th             [0, 4, 7, 11]
  | Min7          -- minor 7th             [0, 3, 7, 10]
  | Dom7          -- dominant 7th          [0, 4, 7, 10]
  | HalfDim       -- minor 7 b5            [0, 3, 6, 10]
  | FullyDim      -- diminished 7          [0, 3, 6, 9]
  | MinMaj7       -- minor major 7         [0, 3, 7, 11]

derive instance eqQuality :: Eq Quality
derive instance ordQuality :: Ord Quality

instance showQuality :: Show Quality where
  show = case _ of
    Maj       -> "Maj"
    Min       -> "Min"
    Dim       -> "Dim"
    Aug       -> "Aug"
    Maj7      -> "Maj7"
    Min7      -> "Min7"
    Dom7      -> "Dom7"
    HalfDim   -> "HalfDim"
    FullyDim  -> "FullyDim"
    MinMaj7   -> "MinMaj7"

-- | Interval set of a chord quality, in semitones from the root.
qualityIntervals :: Quality -> Array Int
qualityIntervals = case _ of
  Maj      -> [0, 4, 7]
  Min      -> [0, 3, 7]
  Dim      -> [0, 3, 6]
  Aug      -> [0, 4, 8]
  Maj7     -> [0, 4, 7, 11]
  Min7     -> [0, 3, 7, 10]
  Dom7     -> [0, 4, 7, 10]
  HalfDim  -> [0, 3, 6, 10]
  FullyDim -> [0, 3, 6, 9]
  MinMaj7  -> [0, 3, 7, 11]

-- ---------------------------------------------------------------------------
-- Tension — additions, alterations, suspensions
-- ---------------------------------------------------------------------------

data Tension
  = Add   Int    -- add the n-th degree (major/perfect interval)
  | Sharp Int    -- raise the n-th degree by 1 semitone
  | Flat  Int    -- lower the n-th degree by 1 semitone
  | Sus   Int    -- replace the 3rd with the n-th
  | NoFifth      -- omit the 5th
  | NoThird      -- omit the 3rd

derive instance eqTension :: Eq Tension
derive instance ordTension :: Ord Tension

instance showTension :: Show Tension where
  show = case _ of
    Add   n  -> "Add "   <> show n
    Sharp n  -> "Sharp " <> show n
    Flat  n  -> "Flat "  <> show n
    Sus   n  -> "Sus "   <> show n
    NoFifth  -> "NoFifth"
    NoThird  -> "NoThird"

-- | Default semitone offset for a numbered degree, measured from the
-- | chord root.  Major thirds, perfect fourths/fifths/elevenths,
-- | major seconds/sixths/ninths/thirteenths.  Returns Nothing for
-- | degrees outside the standard 1..13 vocabulary.
defaultIntervalFor :: Int -> Maybe Int
defaultIntervalFor = case _ of
  1  -> Just 0     -- root
  2  -> Just 2     -- Major 2nd
  3  -> Just 4     -- Major 3rd
  4  -> Just 5     -- Perfect 4th
  5  -> Just 7     -- Perfect 5th
  6  -> Just 9     -- Major 6th
  7  -> Just 11    -- Major 7th
  9  -> Just 14    -- Major 9th
  11 -> Just 17    -- Perfect 11th
  13 -> Just 21    -- Major 13th
  _  -> Nothing

-- ---------------------------------------------------------------------------
-- DegreeChord — the scale-degree-relative recipe
-- ---------------------------------------------------------------------------

newtype DegreeChord = DegreeChord
  { numeral  :: Numeral
  , quality  :: Quality
  , tensions :: Array Tension
  , slash    :: Maybe Numeral   -- bass note as a scale degree
  , mode     :: Maybe Mode      -- modal-interchange override
  }

derive instance eqDegreeChord :: Eq DegreeChord

instance showDegreeChord :: Show DegreeChord where
  show (DegreeChord r) =
    "DegreeChord { numeral: " <> show r.numeral
      <> ", quality: " <> show r.quality
      <> ", tensions: " <> show r.tensions
      <> ", slash: " <> show r.slash
      <> ", mode: " <> show r.mode <> " }"

-- | Convenience constructor: numeral + quality + tensions, default
-- | slash/mode to Nothing.
deg :: Numeral -> Quality -> Array Tension -> DegreeChord
deg n q ts = DegreeChord
  { numeral: n, quality: q, tensions: ts, slash: Nothing, mode: Nothing }

-- | Apply a slash bass to a chord recipe.
slashed :: DegreeChord -> Numeral -> DegreeChord
slashed (DegreeChord r) b = DegreeChord (r { slash = Just b })

-- | Borrow this chord's root lookup from a parallel mode.  Only
-- | shifts the numeral-to-root mapping; tensions still use the
-- | absolute (major/perfect) interval defaults.
borrow :: Mode -> DegreeChord -> DegreeChord
borrow m (DegreeChord r) = DegreeChord (r { mode = Just m })

-- ---------------------------------------------------------------------------
-- Mode — interval template
-- ---------------------------------------------------------------------------

data Mode
  = Ionian | Dorian | Phrygian | Lydian | Mixolydian
  | Aeolian | Locrian
  | HarmonicMinor | MelodicMinor
  | Custom (Array Int)

derive instance eqMode :: Eq Mode

instance showMode :: Show Mode where
  show = case _ of
    Ionian        -> "Ionian"
    Dorian        -> "Dorian"
    Phrygian      -> "Phrygian"
    Lydian        -> "Lydian"
    Mixolydian    -> "Mixolydian"
    Aeolian       -> "Aeolian"
    Locrian       -> "Locrian"
    HarmonicMinor -> "HarmonicMinor"
    MelodicMinor  -> "MelodicMinor"
    Custom xs     -> "Custom " <> show xs

-- | Semitone offsets from the tonic for each scale degree.
modeIntervals :: Mode -> Array Int
modeIntervals = case _ of
  Ionian        -> [0, 2, 4, 5, 7, 9, 11]
  Dorian        -> [0, 2, 3, 5, 7, 9, 10]
  Phrygian      -> [0, 1, 3, 5, 7, 8, 10]
  Lydian        -> [0, 2, 4, 6, 7, 9, 11]
  Mixolydian    -> [0, 2, 4, 5, 7, 9, 10]
  Aeolian       -> [0, 2, 3, 5, 7, 8, 10]
  Locrian       -> [0, 1, 3, 5, 6, 8, 10]
  HarmonicMinor -> [0, 2, 3, 5, 7, 8, 11]
  MelodicMinor  -> [0, 2, 3, 5, 7, 9, 11]
  Custom xs     -> xs

-- ---------------------------------------------------------------------------
-- Key — tonic + mode.  Tonic is a pitch class (0..11).
-- ---------------------------------------------------------------------------

type Key = { tonic :: Int, mode :: Mode }

cMajorKey :: Key
cMajorKey = { tonic: 0, mode: Ionian }

aMinorKey :: Key
aMinorKey = { tonic: 9, mode: Aeolian }

-- ---------------------------------------------------------------------------
-- Chord — unordered set of pitch classes (0..11)
-- ---------------------------------------------------------------------------

newtype Chord = Chord (Array Int)

derive instance eqChord :: Eq Chord

instance showChord :: Show Chord where
  show (Chord xs) = "Chord " <> show xs

-- ---------------------------------------------------------------------------
-- realize — recipe → pitch-class set
-- ---------------------------------------------------------------------------

-- | Resolve a DegreeChord against a Key.
-- |
-- | Pipeline:
-- |   1. Root pitch class = (key.tonic + mode-interval at numeral) mod 12
-- |      (where the mode is the chord's `mode` override if Just, else
-- |      the key's mode).
-- |   2. Base intervals = qualityIntervals q.
-- |   3. Apply tensions left-to-right onto the interval set.
-- |   4. Apply slash: if a bass numeral is given, ensure that pitch
-- |      class is in the chord.
-- |   5. Translate intervals → absolute pitch classes (mod 12),
-- |      sort, deduplicate.
realize :: Key -> DegreeChord -> Chord
realize key (DegreeChord r) =
  let
    effectiveMode = fromMaybe key.mode r.mode

    rootPC = (key.tonic + modeAt effectiveMode (numeralIndex r.numeral)) `mod` 12

    baseIntervals = qualityIntervals r.quality

    tensioned = foldl applyTension baseIntervals r.tensions

    withSlash = case r.slash of
      Nothing -> tensioned
      Just bassNumeral ->
        let
          bassPC = (key.tonic + modeAt effectiveMode (numeralIndex bassNumeral)) `mod` 12
          bassOffset = (bassPC - rootPC + 12) `mod` 12
        in
          if bassOffset `elem` tensioned
            then tensioned
            else cons bassOffset tensioned

    pcs = map (\iv -> (rootPC + iv) `mod` 12) withSlash
  in
    Chord (nub (sort pcs))

-- | Look up a degree's semitone offset in a mode.  Degrees wrap at 7
-- | (so VIII would be the octave's I).
modeAt :: Mode -> Int -> Int
modeAt m n = fromMaybe 0 (modeIntervals m !! (n `mod` 7))

-- | Apply a single tension to an interval set.  Tensions are applied
-- | left-to-right; Sus removes the 3rd before adding its replacement.
applyTension :: Array Int -> Tension -> Array Int
applyTension acc = case _ of
  Add n ->
    case defaultIntervalFor n of
      Just iv -> cons (iv `mod` 12) acc
      Nothing -> acc
  Sharp n ->
    case defaultIntervalFor n of
      Just iv -> cons ((iv + 1) `mod` 12) acc
      Nothing -> acc
  Flat n ->
    case defaultIntervalFor n of
      Just iv -> cons ((iv + 11) `mod` 12) acc
      Nothing -> acc
  Sus n ->
    case defaultIntervalFor n of
      Just iv -> cons (iv `mod` 12) (removeThird acc)
      Nothing -> acc
  NoFifth -> filter (\x -> x /= 6 && x /= 7 && x /= 8) acc
  NoThird -> removeThird acc

removeThird :: Array Int -> Array Int
removeThird = filter (\x -> x /= 3 && x /= 4)

-- ---------------------------------------------------------------------------
-- mcmullenYellow — Joe McMullen's third Plaits chord table (Yellow column).
-- 18 chords arranged by scale-position in a tonal centre.  Encoded as
-- key-relative DegreeChord recipes; faithful realisation against
-- `cMajorKey` should match the pitch classes Plaits Yellow plays when
-- set to C.  See `atlantis-site-planning/vetula-design.md` §McMullen
-- for the position-to-chord mapping.
--
-- Where the original doc encoded `m7`/`m9`/`maj9` as `Min`/`Maj` with
-- `Add 7`/`Add 9` (which under absolute-interval semantics produces
-- Min(maj7) etc.), we use `Min7`/`Maj7` qualities directly so the
-- resulting pitch classes match the conventional jazz reading.
-- ---------------------------------------------------------------------------

mcmullenYellow :: Array DegreeChord
mcmullenYellow =
  [ borrow Aeolian (deg IV  Min  [Add 6, Add 9])     -- 1.  iv 6/9
  , deg II  HalfDim [Sus 4]                          -- 2.  iio 7sus4
  , borrow Aeolian (deg VII Maj  [Add 6])            -- 3.  VII 6
  , deg V   Min  [Add 11]                            -- 4.  v m11
  , borrow Aeolian (deg III Maj  [Add 4])            -- 5.  III add4
  , deg I   Min  [Flat 13]                           -- 6.  i addb13
  , borrow Aeolian (deg VI  Maj  [Sharp 11])         -- 7.  VI add#11
  , borrow Aeolian (deg IV  Min  [Add 6])            -- 8.  iv m6
  , deg II  Dim  []                                  -- 9.  iio
  , deg VII Dim  []                                  -- 10. viio
  , deg V   Dom7 []                                  -- 11. V7
  , deg III Min  [Flat 9]                            -- 12. iii addb9
  , deg I   Maj7 []                                  -- 13. I maj7
  , deg VI  Min7 [Add 9]                             -- 14. vi m9
  , deg IV  Maj7 [Add 9]                             -- 15. IV maj9
  , deg II  Min7 []                                  -- 16. ii m7
  , slashed (deg I Maj7 [Sus 4]) VII                 -- 17. I maj7sus4/vii
  , deg V   Dom7 [Sus 4]                             -- 18. V 7sus4
  ]
