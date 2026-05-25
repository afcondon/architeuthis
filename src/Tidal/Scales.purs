-- | Musical scales for Tidal mini-notation.
-- |
-- | Two layers live here:
-- |
-- |   * The legacy interval tables (`major`, `mixolydian`, …) as
-- |     `Array Number`, plus `lookupScale` / `noteInScale`.  Preserved
-- |     for back-compat with anything that still walks raw intervals.
-- |
-- |   * The typed `Scale` carrier — a `{ root, intervals, name }`
-- |     newtype — plus a battery of named constants (`cMajor`,
-- |     `aMinor`, `cMixolydian`, `aHarmonicMinor`, `dDorian`, …) and
-- |     the operators that consume it (`inKey`, `renderDegree`,
-- |     `transposeDiatonic`, `transposeChromatic`).  This is what
-- |     the substrate uses.
-- |
-- | Architectural note: `Scale` lives next to the intervals on
-- | purpose — the typed carrier is a thin wrapper over the existing
-- | tables.  A new scale is just a new constant assembled from a
-- | root note and one of the heptatonic / pentatonic / hexatonic
-- | etc. interval arrays below.
-- |
-- | The live-render trick: most cues use `d "1 3 5"` and stay as
-- | `Degree` all the way to the voice's emit step.  The voice
-- | consults the *active scale* (a per-tick value pushed in via
-- | `Window`) and renders Degree → MIDI just before dispatch.  A
-- | wire-level `set-scale a-harmonic-minor` mutates the active
-- | scale; the very next tick re-renders every running degree
-- | pattern in the new mode.  `inKey s pat` is an eager local
-- | override — it renders Degrees through `s` at construction, so
-- | the resulting Chromatics ride out a global scale change
-- | unchanged.
module Tidal.Scales
  ( -- * Typed Scale carrier
    Scale(..)
  , mkScale
  , mkScaleP
    -- * Distribution modes (Natural / Equal — cf. Instruō Dail)
  , Distribution(..)
  , quantiseToScale
  , applyDistribution
    -- * Named scale constants
  , cChromatic
  , cMajor
  , cMinor
  , cMixolydian
  , cDorian
  , cPhrygian
  , cLydian
  , cAeolian
  , cLocrian
  , cHarmonicMinor
  , cHarmonicMajor
  , cMelodicMinor
  , cMajorPentatonic
  , cMinorPentatonic
  , cMessiaen3
  , cPhrygianDominant
  , dMajor
  , dMinor
  , dDorian
  , dMixolydian
  , eMinor
  , eDorian
  , eMixolydian
  , ePhrygian
  , fMajor
  , fLydian
  , fMixolydian
  , gMajor
  , gMixolydian
  , gMinor
  , gDorian
  , aMajor
  , aMinor
  , aMixolydian
  , aDorian
  , aHarmonicMinor
    -- * Multi-octave scales (Dail-style)
  , cPhrygianDomLT
  , cMajorTriad3oct
  , bMinor
  , bDorian
  , bLocrian
    -- * Lookup + render
  , lookupScaleByName
  , renderDegree
    -- * Operators
  , inKey
  , quantiseInKey
  , transposeDiatonic
  , transposeChromatic
  , shiftDegreesInScale
  , octave
    -- * Legacy interval-table API
  , lookupScale
  , scaleNames
  , noteInScale
    -- * 5-note scales (Pentatonic)
  , minPent
  , majPent
  , ritusen
  , egyptian
  , kumai
  , hirajoshi
  , iwato
  , chinese
  , indian
  , pelog
  , prometheus
  , scriabin
    -- * Chinese pentatonic modes
  , gong
  , shang
  , jiao
  , zhi
  , yu
    -- * 6-note scales (Hexatonic)
  , whole
  , augmented
  , augmented2
  , hexMajor7
  , hexDorian
  , hexPhrygian
  , hexSus
  , hexMajor6
  , hexAeolian
    -- * 7-note scales (Heptatonic)
  , major
  , ionian
  , dorian
  , phrygian
  , lydian
  , mixolydian
  , aeolian
  , minor
  , locrian
  , harmonicMinor
  , harmonicMajor
  , melodicMinor
  , melodicMinorDesc
  , melodicMajor
    -- * Raga modes
  , todi
  , purvi
  , marva
  , bhairav
  , ahirbhairav
  , phrygianDominant
    -- * Other 7-note scales
  , superLocrian
  , romanianMinor
  , hungarianMinor
  , neapolitanMinor
  , enigmatic
  , spanish
  , leadingWhole
  , lydianMinor
  , neapolitanMajor
  , locrianMajor
    -- * 8-note scales (Octatonic)
  , diminished
  , diminished2
    -- * Messiaen modes
  , messiaen1
  , messiaen2
  , messiaen3
  , messiaen4
  , messiaen5
  , messiaen6
  , messiaen7
    -- * 12-note scale
  , chromatic
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldl)
import Data.Int (toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Tidal.Notation (class Notation, toPattern)
import Tidal.Pattern.Types (Pattern)
import Tidal.Pitch (PitchedNote12(..))

-------------------------------------------------------------------------------
-- Scale lookup
-------------------------------------------------------------------------------

-- | Look up a scale by name
lookupScale :: String -> Maybe (Array Number)
lookupScale name = Array.find (\(Tuple n _) -> n == name) scaleTable
  >>= \(Tuple _ intervals) -> Just intervals

-- | List of all scale names
scaleNames :: Array String
scaleNames = map (\(Tuple n _) -> n) scaleTable

-- | Convert a scale degree to a semitone offset
-- |
-- | Handles octave wrapping: degree 7 in a 7-note scale wraps to octave 1
noteInScale :: Array Number -> Int -> Number
noteInScale scale degree =
  let len = Array.length scale
      octave = degree / len  -- Integer division for octave
      idx = degree `mod` len
      -- Handle negative modulo properly
      idx' = if idx < 0 then idx + len else idx
  in case Array.index scale idx' of
       Just note -> note + 12.0 * (toNumber octave)
       Nothing -> toNumber degree  -- Fallback

-------------------------------------------------------------------------------
-- Scale table
-------------------------------------------------------------------------------

scaleTable :: Array (Tuple String (Array Number))
scaleTable =
  -- Pentatonic scales
  [ Tuple "minPent" minPent
  , Tuple "majPent" majPent
  , Tuple "ritusen" ritusen
  , Tuple "egyptian" egyptian
  , Tuple "kumai" kumai
  , Tuple "hirajoshi" hirajoshi
  , Tuple "iwato" iwato
  , Tuple "chinese" chinese
  , Tuple "indian" indian
  , Tuple "pelog" pelog
  , Tuple "prometheus" prometheus
  , Tuple "scriabin" scriabin
  -- Chinese modes
  , Tuple "gong" gong
  , Tuple "shang" shang
  , Tuple "jiao" jiao
  , Tuple "zhi" zhi
  , Tuple "yu" yu
  -- Hexatonic
  , Tuple "whole" whole
  , Tuple "wholetone" whole
  , Tuple "augmented" augmented
  , Tuple "augmented2" augmented2
  , Tuple "hexMajor7" hexMajor7
  , Tuple "hexDorian" hexDorian
  , Tuple "hexPhrygian" hexPhrygian
  , Tuple "hexSus" hexSus
  , Tuple "hexMajor6" hexMajor6
  , Tuple "hexAeolian" hexAeolian
  -- Major modes
  , Tuple "major" major
  , Tuple "ionian" ionian
  , Tuple "dorian" dorian
  , Tuple "phrygian" phrygian
  , Tuple "lydian" lydian
  , Tuple "mixolydian" mixolydian
  , Tuple "aeolian" aeolian
  , Tuple "minor" minor
  , Tuple "locrian" locrian
  -- Harmonic/melodic variants
  , Tuple "harmonicMinor" harmonicMinor
  , Tuple "harmonicMajor" harmonicMajor
  , Tuple "melodicMinor" melodicMinor
  , Tuple "melodicMinorDesc" melodicMinorDesc
  , Tuple "melodicMajor" melodicMajor
  , Tuple "bartok" melodicMajor
  , Tuple "hindu" melodicMajor
  -- Raga modes
  , Tuple "todi" todi
  , Tuple "purvi" purvi
  , Tuple "marva" marva
  , Tuple "bhairav" bhairav
  , Tuple "ahirbhairav" ahirbhairav
  -- Other heptatonic
  , Tuple "superLocrian" superLocrian
  , Tuple "romanianMinor" romanianMinor
  , Tuple "hungarianMinor" hungarianMinor
  , Tuple "neapolitanMinor" neapolitanMinor
  , Tuple "enigmatic" enigmatic
  , Tuple "spanish" spanish
  , Tuple "leadingWhole" leadingWhole
  , Tuple "lydianMinor" lydianMinor
  , Tuple "neapolitanMajor" neapolitanMajor
  , Tuple "locrianMajor" locrianMajor
  -- Octatonic
  , Tuple "diminished" diminished
  , Tuple "octatonic" diminished
  , Tuple "diminished2" diminished2
  , Tuple "octatonic2" diminished2
  -- Messiaen modes
  , Tuple "messiaen1" messiaen1
  , Tuple "messiaen2" messiaen2
  , Tuple "messiaen3" messiaen3
  , Tuple "messiaen4" messiaen4
  , Tuple "messiaen5" messiaen5
  , Tuple "messiaen6" messiaen6
  , Tuple "messiaen7" messiaen7
  -- Chromatic
  , Tuple "chromatic" chromatic
  ]

-------------------------------------------------------------------------------
-- 5-note scales (Pentatonic)
-------------------------------------------------------------------------------

-- | Minor pentatonic: 1 b3 4 5 b7
minPent :: Array Number
minPent = [0.0, 3.0, 5.0, 7.0, 10.0]

-- | Major pentatonic: 1 2 3 5 6
majPent :: Array Number
majPent = [0.0, 2.0, 4.0, 7.0, 9.0]

-- | Ritusen (mode of major pentatonic)
ritusen :: Array Number
ritusen = [0.0, 2.0, 5.0, 7.0, 9.0]

-- | Egyptian (mode of major pentatonic)
egyptian :: Array Number
egyptian = [0.0, 2.0, 5.0, 7.0, 10.0]

-- | Kumai (Japanese)
kumai :: Array Number
kumai = [0.0, 2.0, 3.0, 7.0, 9.0]

-- | Hirajoshi (Japanese)
hirajoshi :: Array Number
hirajoshi = [0.0, 2.0, 3.0, 7.0, 8.0]

-- | Iwato (Japanese)
iwato :: Array Number
iwato = [0.0, 1.0, 5.0, 6.0, 10.0]

-- | Chinese
chinese :: Array Number
chinese = [0.0, 4.0, 6.0, 7.0, 11.0]

-- | Indian
indian :: Array Number
indian = [0.0, 4.0, 5.0, 7.0, 10.0]

-- | Pelog (Indonesian)
pelog :: Array Number
pelog = [0.0, 1.0, 3.0, 7.0, 8.0]

-- | Prometheus
prometheus :: Array Number
prometheus = [0.0, 2.0, 4.0, 6.0, 11.0]

-- | Scriabin
scriabin :: Array Number
scriabin = [0.0, 1.0, 4.0, 7.0, 9.0]

-------------------------------------------------------------------------------
-- Chinese pentatonic modes
-------------------------------------------------------------------------------

gong :: Array Number
gong = [0.0, 2.0, 4.0, 7.0, 9.0]

shang :: Array Number
shang = [0.0, 2.0, 5.0, 7.0, 10.0]

jiao :: Array Number
jiao = [0.0, 3.0, 5.0, 8.0, 10.0]

zhi :: Array Number
zhi = [0.0, 2.0, 5.0, 7.0, 9.0]

yu :: Array Number
yu = [0.0, 3.0, 5.0, 7.0, 10.0]

-------------------------------------------------------------------------------
-- 6-note scales (Hexatonic)
-------------------------------------------------------------------------------

-- | Whole tone scale
whole :: Array Number
whole = [0.0, 2.0, 4.0, 6.0, 8.0, 10.0]

-- | Augmented scale
augmented :: Array Number
augmented = [0.0, 3.0, 4.0, 7.0, 8.0, 11.0]

-- | Augmented scale (second mode)
augmented2 :: Array Number
augmented2 = [0.0, 1.0, 4.0, 5.0, 8.0, 9.0]

-- | Hexatonic major 7
hexMajor7 :: Array Number
hexMajor7 = [0.0, 2.0, 4.0, 7.0, 9.0, 11.0]

-- | Hexatonic dorian
hexDorian :: Array Number
hexDorian = [0.0, 2.0, 3.0, 5.0, 7.0, 10.0]

-- | Hexatonic phrygian
hexPhrygian :: Array Number
hexPhrygian = [0.0, 1.0, 3.0, 5.0, 8.0, 10.0]

-- | Hexatonic sus
hexSus :: Array Number
hexSus = [0.0, 2.0, 5.0, 7.0, 9.0, 10.0]

-- | Hexatonic major 6
hexMajor6 :: Array Number
hexMajor6 = [0.0, 2.0, 4.0, 5.0, 7.0, 9.0]

-- | Hexatonic aeolian
hexAeolian :: Array Number
hexAeolian = [0.0, 3.0, 5.0, 7.0, 8.0, 10.0]

-------------------------------------------------------------------------------
-- 7-note scales (Heptatonic) - Church modes
-------------------------------------------------------------------------------

-- | Major scale (Ionian mode): 1 2 3 4 5 6 7
major :: Array Number
major = [0.0, 2.0, 4.0, 5.0, 7.0, 9.0, 11.0]

-- | Ionian mode (same as major)
ionian :: Array Number
ionian = major

-- | Dorian mode: 1 2 b3 4 5 6 b7
dorian :: Array Number
dorian = [0.0, 2.0, 3.0, 5.0, 7.0, 9.0, 10.0]

-- | Phrygian mode: 1 b2 b3 4 5 b6 b7
phrygian :: Array Number
phrygian = [0.0, 1.0, 3.0, 5.0, 7.0, 8.0, 10.0]

-- | Lydian mode: 1 2 3 #4 5 6 7
lydian :: Array Number
lydian = [0.0, 2.0, 4.0, 6.0, 7.0, 9.0, 11.0]

-- | Mixolydian mode: 1 2 3 4 5 6 b7
mixolydian :: Array Number
mixolydian = [0.0, 2.0, 4.0, 5.0, 7.0, 9.0, 10.0]

-- | Aeolian mode (natural minor): 1 2 b3 4 5 b6 b7
aeolian :: Array Number
aeolian = [0.0, 2.0, 3.0, 5.0, 7.0, 8.0, 10.0]

-- | Natural minor (same as aeolian)
minor :: Array Number
minor = aeolian

-- | Locrian mode: 1 b2 b3 4 b5 b6 b7
locrian :: Array Number
locrian = [0.0, 1.0, 3.0, 5.0, 6.0, 8.0, 10.0]

-------------------------------------------------------------------------------
-- Harmonic and melodic variants
-------------------------------------------------------------------------------

-- | Harmonic minor: 1 2 b3 4 5 b6 7
harmonicMinor :: Array Number
harmonicMinor = [0.0, 2.0, 3.0, 5.0, 7.0, 8.0, 11.0]

-- | Harmonic major: 1 2 3 4 5 b6 7
harmonicMajor :: Array Number
harmonicMajor = [0.0, 2.0, 4.0, 5.0, 7.0, 8.0, 11.0]

-- | Melodic minor (ascending): 1 2 b3 4 5 6 7
melodicMinor :: Array Number
melodicMinor = [0.0, 2.0, 3.0, 5.0, 7.0, 9.0, 11.0]

-- | Melodic minor (descending, same as natural minor)
melodicMinorDesc :: Array Number
melodicMinorDesc = [0.0, 2.0, 3.0, 5.0, 7.0, 8.0, 10.0]

-- | Melodic major: 1 2 3 4 5 b6 b7
melodicMajor :: Array Number
melodicMajor = [0.0, 2.0, 4.0, 5.0, 7.0, 8.0, 10.0]

-------------------------------------------------------------------------------
-- Raga modes
-------------------------------------------------------------------------------

todi :: Array Number
todi = [0.0, 1.0, 3.0, 6.0, 7.0, 8.0, 11.0]

purvi :: Array Number
purvi = [0.0, 1.0, 4.0, 6.0, 7.0, 8.0, 11.0]

marva :: Array Number
marva = [0.0, 1.0, 4.0, 6.0, 7.0, 9.0, 11.0]

bhairav :: Array Number
bhairav = [0.0, 1.0, 4.0, 5.0, 7.0, 8.0, 11.0]

ahirbhairav :: Array Number
ahirbhairav = [0.0, 1.0, 4.0, 5.0, 7.0, 9.0, 10.0]

-- | Phrygian Dominant (5th mode of harmonic minor): 1 b2 3 4 5 b6 b7.
-- | The "Hava Nagila" / Spanish-Phrygian / klezmer scale.  Distinct from
-- | `bhairav` which has natural-7 rather than b7.
phrygianDominant :: Array Number
phrygianDominant = [0.0, 1.0, 4.0, 5.0, 7.0, 8.0, 10.0]

-------------------------------------------------------------------------------
-- Other 7-note scales
-------------------------------------------------------------------------------

superLocrian :: Array Number
superLocrian = [0.0, 1.0, 3.0, 4.0, 6.0, 8.0, 10.0]

romanianMinor :: Array Number
romanianMinor = [0.0, 2.0, 3.0, 6.0, 7.0, 9.0, 10.0]

hungarianMinor :: Array Number
hungarianMinor = [0.0, 2.0, 3.0, 6.0, 7.0, 8.0, 11.0]

neapolitanMinor :: Array Number
neapolitanMinor = [0.0, 1.0, 3.0, 5.0, 7.0, 8.0, 11.0]

enigmatic :: Array Number
enigmatic = [0.0, 1.0, 4.0, 6.0, 8.0, 10.0, 11.0]

spanish :: Array Number
spanish = [0.0, 1.0, 4.0, 5.0, 7.0, 8.0, 10.0]

leadingWhole :: Array Number
leadingWhole = [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 11.0]

lydianMinor :: Array Number
lydianMinor = [0.0, 2.0, 4.0, 6.0, 7.0, 8.0, 10.0]

neapolitanMajor :: Array Number
neapolitanMajor = [0.0, 1.0, 3.0, 5.0, 7.0, 9.0, 11.0]

locrianMajor :: Array Number
locrianMajor = [0.0, 2.0, 4.0, 5.0, 6.0, 8.0, 10.0]

-------------------------------------------------------------------------------
-- 8-note scales (Octatonic)
-------------------------------------------------------------------------------

-- | Diminished scale (half-whole)
diminished :: Array Number
diminished = [0.0, 1.0, 3.0, 4.0, 6.0, 7.0, 9.0, 10.0]

-- | Diminished scale (whole-half)
diminished2 :: Array Number
diminished2 = [0.0, 2.0, 3.0, 5.0, 6.0, 8.0, 9.0, 11.0]

-------------------------------------------------------------------------------
-- Messiaen modes of limited transposition
-------------------------------------------------------------------------------

messiaen1 :: Array Number
messiaen1 = whole

messiaen2 :: Array Number
messiaen2 = diminished

messiaen3 :: Array Number
messiaen3 = [0.0, 2.0, 3.0, 4.0, 6.0, 7.0, 8.0, 10.0, 11.0]

messiaen4 :: Array Number
messiaen4 = [0.0, 1.0, 2.0, 5.0, 6.0, 7.0, 8.0, 11.0]

messiaen5 :: Array Number
messiaen5 = [0.0, 1.0, 5.0, 6.0, 7.0, 11.0]

messiaen6 :: Array Number
messiaen6 = [0.0, 2.0, 4.0, 5.0, 6.0, 8.0, 10.0, 11.0]

messiaen7 :: Array Number
messiaen7 = [0.0, 1.0, 2.0, 3.0, 5.0, 6.0, 7.0, 8.0, 9.0, 11.0]

-------------------------------------------------------------------------------
-- 12-note scale
-------------------------------------------------------------------------------

-- | Chromatic scale (all semitones)
chromatic :: Array Number
chromatic = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0]

-------------------------------------------------------------------------------
-- Typed Scale carrier
-------------------------------------------------------------------------------

-- | A Scale binds a root note to a sequence of semitone offsets, plus
-- | a `period` over which the offset pattern repeats.
-- |
-- |   * `root`       — MIDI note of degree 1 (e.g. 60 for middle C).
-- |   * `intervals`  — ascending semitone offsets from the root, in
-- |                    degree order (degree 1 → `intervals[0]`,
-- |                    degree 2 → `intervals[1]`, …).  Always starts
-- |                    with 0.  May span more than one octave for
-- |                    multi-octave non-repeating scales.
-- |   * `period`     — semitones until the pattern repeats.  12 for
-- |                    traditional octave-repeating scales; 24 for a
-- |                    Dail-style 2-octave non-repeating scale (e.g.
-- |                    Phrygian Dominant with Chromatic Leading
-- |                    Tones); 36 for a 3-octave arpeggio; etc.
-- |   * `name`       — wire-side identifier (`"c-mixolydian"`) used
-- |                    by `lookupScaleByName`.
-- |
-- | Degree extension is implicit: degree (n + 1) where n = length
-- | intervals starts the next period at root + period.  Negative
-- | degrees wrap downwards by period.
-- |
-- | The period generalisation is named for Instruō Dail, whose
-- | bipolar quantiser engine first surfaced multi-octave non-repeating
-- | scales as a first-class musical idiom (firmware presets like
-- | "Phrygian Dominant with Chromatic Leading Tones" only make sense
-- | when the period is larger than one octave).
newtype Scale = Scale
  { root :: Int
  , intervals :: Array Int
  , period :: Int
  , name :: String
  }

derive instance eqScale :: Eq Scale

instance showScale :: Show Scale where
  show (Scale s) = "Scale " <> s.name

-- | Smart constructor for traditional octave-repeating scales.
-- | Intervals are taken straight from one of the tables above
-- | (`major`, `mixolydian`, …) and `period` defaults to 12.  Use
-- | `mkScaleP` to set an explicit non-octave period.
mkScale :: String -> Int -> Array Number -> Scale
mkScale name root ivs = mkScaleP name root ivs 12

-- | Smart constructor with explicit `period`.  Use for multi-octave
-- | non-repeating scales (Dail-style):
-- |
-- |     phrygianDomLT = mkScaleP "phrygian-dom-leading-tones" 60
-- |       [0.0,1.0,4.0,5.0,7.0,8.0,10.0, 12.0,13.0,14.0,15.0,16.0,17.0,18.0,19.0,20.0,21.0,22.0] 24
-- |
-- | The intervals array can list any ascending set of offsets, and
-- | `period` says how far up the pattern repeats.  For a chord-as-scale
-- | (held-chord-becomes-quantiser-mask), pick a period equal to the
-- | full span of the chord plus one.
mkScaleP :: String -> Int -> Array Number -> Int -> Scale
mkScaleP name root ivs period = Scale
  { root
  , intervals: map (Int.round) ivs
  , period
  , name
  }

-------------------------------------------------------------------------------
-- Named scale constants
-------------------------------------------------------------------------------
-- MIDI numbers for the canonical roots: C4 = 60, C#4 = 61, …, B4 = 71.

-- | The chromatic identity scale.  All 12 semitones active, period 12.
-- | `quantiseToScale cChromatic n == n` for every MIDI `n` (every cell
-- | is its own nearest active note), and `renderDegree cChromatic d`
-- | indexes the chromatic scale (degree 1 → C, degree 2 → C#, …).
-- |
-- | This is the default scale for `OdonusConfig` / future per-vmod
-- | scale fields: with `Distribution = Natural`, the per-cell `notes`
-- | array passes through untouched (so today's "60 62 64 …" literal
-- | MIDI cells keep behaving identically), while flipping to `Equal`
-- | turns the same array into a chromatic-degree index.
cChromatic :: Scale
cChromatic = mkScale "c-chromatic" 60 chromatic

cMajor :: Scale
cMajor = mkScale "c-major" 60 major

cMinor :: Scale
cMinor = mkScale "c-minor" 60 minor

cMixolydian :: Scale
cMixolydian = mkScale "c-mixolydian" 60 mixolydian

cDorian :: Scale
cDorian = mkScale "c-dorian" 60 dorian

cPhrygian :: Scale
cPhrygian = mkScale "c-phrygian" 60 phrygian

cLydian :: Scale
cLydian = mkScale "c-lydian" 60 lydian

cAeolian :: Scale
cAeolian = mkScale "c-aeolian" 60 aeolian

cLocrian :: Scale
cLocrian = mkScale "c-locrian" 60 locrian

cHarmonicMinor :: Scale
cHarmonicMinor = mkScale "c-harmonic-minor" 60 harmonicMinor

cHarmonicMajor :: Scale
cHarmonicMajor = mkScale "c-harmonic-major" 60 harmonicMajor

cMelodicMinor :: Scale
cMelodicMinor = mkScale "c-melodic-minor" 60 melodicMinor

-- | Curated pop-scale constants for the L-mid Globals scale-selector
-- | knob (Slab 6.7c).  All C-rooted so the curated picker steps through
-- | modes-over-same-tonic, matching the "stays in key" jam idiom.
cMajorPentatonic :: Scale
cMajorPentatonic = mkScale "c-major-pentatonic" 60 majPent

cMinorPentatonic :: Scale
cMinorPentatonic = mkScale "c-minor-pentatonic" 60 minPent

cMessiaen3 :: Scale
cMessiaen3 = mkScale "c-messiaen-3" 60 messiaen3

cPhrygianDominant :: Scale
cPhrygianDominant = mkScale "c-phrygian-dominant" 60 phrygianDominant

dMajor :: Scale
dMajor = mkScale "d-major" 62 major

dMinor :: Scale
dMinor = mkScale "d-minor" 62 minor

dDorian :: Scale
dDorian = mkScale "d-dorian" 62 dorian

dMixolydian :: Scale
dMixolydian = mkScale "d-mixolydian" 62 mixolydian

eMinor :: Scale
eMinor = mkScale "e-minor" 64 minor

eDorian :: Scale
eDorian = mkScale "e-dorian" 64 dorian

eMixolydian :: Scale
eMixolydian = mkScale "e-mixolydian" 64 mixolydian

ePhrygian :: Scale
ePhrygian = mkScale "e-phrygian" 64 phrygian

fMajor :: Scale
fMajor = mkScale "f-major" 65 major

fLydian :: Scale
fLydian = mkScale "f-lydian" 65 lydian

fMixolydian :: Scale
fMixolydian = mkScale "f-mixolydian" 65 mixolydian

gMajor :: Scale
gMajor = mkScale "g-major" 67 major

gMixolydian :: Scale
gMixolydian = mkScale "g-mixolydian" 67 mixolydian

gMinor :: Scale
gMinor = mkScale "g-minor" 67 minor

gDorian :: Scale
gDorian = mkScale "g-dorian" 67 dorian

aMajor :: Scale
aMajor = mkScale "a-major" 69 major

aMinor :: Scale
aMinor = mkScale "a-minor" 69 minor

aMixolydian :: Scale
aMixolydian = mkScale "a-mixolydian" 69 mixolydian

aDorian :: Scale
aDorian = mkScale "a-dorian" 69 dorian

aHarmonicMinor :: Scale
aHarmonicMinor = mkScale "a-harmonic-minor" 69 harmonicMinor

-------------------------------------------------------------------------------
-- Multi-octave scales (Instruō Dail-style)
--
-- These have `period > 12`: the interval pattern repeats over more than
-- one octave, with different content per octave-within-period.  Degree
-- (n + 1) where n = length intervals lands at root + period, not
-- root + 12.  Reach for these when you want a melodic line that
-- doesn't tile every 12 semitones — Phrygian-with-leading-tones-only-
-- in-the-upper-octave is the canonical example.
-------------------------------------------------------------------------------

-- | Phrygian Dominant in the lower octave, chromatic in the upper —
-- | one of Dail's preset minor scales.  Period 24.  C-rooted.
-- | Degrees 1..7 walk the Phrygian Dom (C C# E F G G# A#); degrees
-- | 8..19 walk semitones from the octave-C upward.
cPhrygianDomLT :: Scale
cPhrygianDomLT = mkScaleP "c-phrygian-dom-leading-tones" 60
  [ 0.0, 1.0, 4.0, 5.0, 7.0, 8.0, 10.0           -- Phrygian Dom in octave 1
  , 12.0, 13.0, 14.0, 15.0, 16.0, 17.0           -- Chromatic leading tones in octave 2
  , 18.0, 19.0, 20.0, 21.0, 22.0, 23.0
  ] 24

-- | A three-octave major triad held as a quantiser mask.  Period 36.
-- | Useful for "snap melody to chord tones across the full range" —
-- | a chord-as-scale, the Dail held-chord-as-mask use case.  Degree
-- | walking gives a sparse arpeggio; Natural Distribution snaps any
-- | continuous CV to the nearest of (C, E, G).
cMajorTriad3oct :: Scale
cMajorTriad3oct = mkScaleP "c-major-triad-3oct" 60
  [ 0.0, 4.0, 7.0
  , 12.0, 16.0, 19.0
  , 24.0, 28.0, 31.0
  ] 36

bMinor :: Scale
bMinor = mkScale "b-minor" 71 minor

bDorian :: Scale
bDorian = mkScale "b-dorian" 71 dorian

bLocrian :: Scale
bLocrian = mkScale "b-locrian" 71 locrian

-------------------------------------------------------------------------------
-- Lookup + render
-------------------------------------------------------------------------------

-- | Resolve a wire-side scale name (e.g. `"c-mixolydian"`) to its
-- | `Scale` value.  Used by the `set-scale` verb to populate the
-- | active-scale ETS slot.  Unknown names return Nothing — the
-- | caller surfaces this as an error.
-- |
-- | Names are kebab-case; `lookupScale` (legacy) uses camelCase
-- | because it indexes the raw interval table by mode name only.
lookupScaleByName :: String -> Maybe Scale
lookupScaleByName name =
  Array.find (\(Scale s) -> s.name == name) namedScales

namedScales :: Array Scale
namedScales =
  [ cMajor, cMinor, cMixolydian, cDorian, cPhrygian, cLydian
  , cAeolian, cLocrian, cHarmonicMinor, cHarmonicMajor, cMelodicMinor
  , cMajorPentatonic, cMinorPentatonic, cMessiaen3, cPhrygianDominant
  , dMajor, dMinor, dDorian, dMixolydian
  , eMinor, eDorian, eMixolydian, ePhrygian
  , fMajor, fLydian, fMixolydian
  , gMajor, gMixolydian, gMinor, gDorian
  , aMajor, aMinor, aMixolydian, aDorian, aHarmonicMinor
  , bMinor, bDorian, bLocrian
  ]

-- | Resolve a (1-based) scale degree to an absolute MIDI note.
-- | Implements **Equal Distribution** semantics (cf. `Distribution`):
-- | each degree is an index into the scale's intervals array, so a
-- | linear ramp through degree-space steps through the scale's notes
-- | one-by-one regardless of their actual pitch spacing.
-- |
-- |   * Degree 1 = root
-- |   * Degree 2 = root + intervals[1]
-- |   * Degree (n + 1) where n = length intervals = root + period
-- |   * Degree 0 = one period down, degree 1 of the period below
-- |   * Negative degrees wrap downwards through periods
-- |
-- | Examples in C major (intervals = [0,2,4,5,7,9,11], period = 12):
-- |   `renderDegree cMajor 1` = 60 (C4)
-- |   `renderDegree cMajor 3` = 64 (E4)
-- |   `renderDegree cMajor 8` = 72 (C5)
-- |   `renderDegree cMajor 0` = 59 (B3 — degree 7 of the period below)
-- |
-- | For multi-octave non-repeating scales (period > 12), degree
-- | (n + 1) lands at root + period (i.e. one full pattern up), not
-- | one octave up.
renderDegree :: Scale -> Int -> Int
renderDegree (Scale s) degree =
  let
    n = Array.length s.intervals
    idx0 = degree - 1
    -- floored division & modulo so negatives wrap into periods below
    period =
      if idx0 >= 0
        then idx0 / n
        else -((-idx0 - 1) / n + 1)
    step = idx0 - period * n
    offset = case Array.index s.intervals step of
      Just iv -> iv
      Nothing -> 0  -- impossible given the step modulo
  in
    s.root + offset + s.period * period

-------------------------------------------------------------------------------
-- Operators on Pattern PitchedNote12
-------------------------------------------------------------------------------

-- | Pin a sub-pattern to a specific scale.  Eagerly renders every
-- | `Degree` event through `scale`, leaving `Chromatic` and `Sample`
-- | events untouched.  After `inKey`, the sub-pattern carries no
-- | Degrees, so a wire-level `set-scale` change does not affect it.
-- |
-- | Use this to pin sections to specific modes inside a larger piece
-- | (verse in c-mixolydian, chorus in a-harmonic-minor).  Don't use
-- | it on a pattern you want to follow live `set-scale` mutation —
-- | the whole point of leaving Degrees unresolved is that the voice
-- | renders them on every tick using the current scale.
inKey :: forall n. Notation n PitchedNote12 => Scale -> n -> Pattern PitchedNote12
inKey scale = map (renderPitchIn scale) <<< toPattern
  where
    renderPitchIn :: Scale -> PitchedNote12 -> PitchedNote12
    renderPitchIn s = case _ of
      Degree d    -> Chromatic (renderDegree s d)
      Chromatic n -> Chromatic n
      Sample x    -> Sample x

-- | **Natural Distribution** counterpart of `inKey`.  Snaps every
-- | `Chromatic` event to the nearest active note in `scale` via
-- | `quantiseToScale`.  `Degree` events render through `renderDegree`
-- | (Equal — same as `inKey`); since a Degree-resolved note is in-
-- | scale by construction, the snap is a no-op for those.
-- |
-- | Use this when you have a chromatic source (raw MIDI values from
-- | a sequencer, an LFO mapped to pitch, etc.) and want it constrained
-- | to a scale.  `mini "c4 c#4 d4 d#4 e4 f4"` quantised against
-- | `cMajor` collapses the half-steps onto the diatonic neighbours.
quantiseInKey :: forall n. Notation n PitchedNote12 => Scale -> n -> Pattern PitchedNote12
quantiseInKey scale = map (renderPitchIn scale) <<< toPattern
  where
    renderPitchIn :: Scale -> PitchedNote12 -> PitchedNote12
    renderPitchIn s = case _ of
      Degree d    -> Chromatic (renderDegree s d)
      Chromatic n -> Chromatic (quantiseToScale s n)
      Sample x    -> Sample x

-- | Transpose by `n` scale degrees.  Operates only on `Degree`
-- | events; `Chromatic` and `Sample` pass through untouched (chromatic
-- | transposition of an already-absolute pitch isn't diatonic, and
-- | sample tokens aren't pitched).
-- |
-- | Composes with `inKey` the obvious way: `inKey s . transposeDiatonic n`
-- | renders to the scale after stepping; `transposeDiatonic n . inKey s`
-- | pins the scale first (so the transpose is a no-op).
transposeDiatonic :: forall n. Notation n PitchedNote12 => Int -> n -> Pattern PitchedNote12
transposeDiatonic offset = map step <<< toPattern
  where
    step :: PitchedNote12 -> PitchedNote12
    step = case _ of
      Degree d -> Degree (d + offset)
      other    -> other

-- | Transpose by `n` semitones.  Operates only on `Chromatic` events;
-- | `Degree` and `Sample` pass through untouched (chromatic transpose
-- | of a degree-in-unknown-scale isn't well-defined; sample tokens
-- | aren't pitched).
-- |
-- | For chromatic transposition of a degree pattern, render first:
-- | `transposeChromatic 5 (inKey cMajor (d "1 3 5"))`.
transposeChromatic :: forall n. Notation n PitchedNote12 => Int -> n -> Pattern PitchedNote12
transposeChromatic offset = map step <<< toPattern
  where
    step :: PitchedNote12 -> PitchedNote12
    step = case _ of
      Chromatic n -> Chromatic (n + offset)
      other       -> other

-- | Shift a MIDI note by `offset` scale-degrees within `scale`.
-- | Returns a MIDI note that is in-scale by construction — no
-- | post-hoc snap needed.  This is the in-house transposition for
-- | per-voice / per-playhead shifts: works in scale-degree space
-- | regardless of how widely the scale's intervals are spaced, so a
-- | "+4 in C-major" lands on the perfect fifth even though +4 semitones
-- | would land on a chromatic E.
-- |
-- | For `cChromatic` the function collapses to raw semitone shift —
-- | every degree of chromatic IS a semitone, so degree-shift and
-- | semitone-shift agree.  This is the graceful-degradation case: a
-- | session that hasn't picked a non-chromatic scale gets the same
-- | audible result it would have gotten from `note + offset`.
-- |
-- | The input is first snapped to its nearest in-scale degree via
-- | `quantiseToScale` to give a well-defined starting degree; the
-- | shift is then exact.  See [[feedback_transpose_via_scale_and_offset]]
-- | for the rationale (don't ship a naive semitone transpose; quantise
-- | via scale + offset).
shiftDegreesInScale :: Scale -> Int -> Int -> Int
shiftDegreesInScale scale offset note =
  let snapped = quantiseToScale scale note
      d       = noteToDegreeIn scale snapped
  in renderDegree scale (d + offset)

-- | Reverse of `renderDegree` for in-scale notes: returns the 1-based
-- | degree of `note` in `scale`.  Assumes `note` is exactly in-scale
-- | (produced by `renderDegree` or `quantiseToScale`).  Off-scale
-- | inputs resolve to the nearest in-scale degree below.
noteToDegreeIn :: Scale -> Int -> Int
noteToDegreeIn (Scale s) note =
  let n         = Array.length s.intervals
      dist      = note - s.root
      periodIdx =
        if dist >= 0
          then dist / s.period
          else -((-dist - 1) / s.period + 1)
      remainder = dist - periodIdx * s.period
      stepIdx   = case Array.findIndex (\iv -> iv == remainder) s.intervals of
        Just i  -> i
        Nothing -> nearestBelowIdx s.intervals remainder
  in periodIdx * n + stepIdx + 1

-- | Index of the largest element of `arr` that is `<= target`.
-- | Used as a fallback when the input isn't exactly in-scale; assumes
-- | `arr` is ascending (the scale intervals are sorted by construction).
nearestBelowIdx :: Array Int -> Int -> Int
nearestBelowIdx arr target =
  case Array.findIndex (\iv -> iv > target) arr of
    Just 0  -> 0
    Just i  -> i - 1
    Nothing -> max 0 (Array.length arr - 1)

-- | Shift a scale's root by `n` periods.  `octave (-2) cMajor` is C2-
-- | rooted C major; `octave 1 aMinor` is A5-rooted A minor.  For
-- | traditional scales (period = 12) this is octave-shift; for multi-
-- | octave non-repeating scales it shifts by the full period.  Useful
-- | for bass / lead voicings of the same mode.
octave :: Int -> Scale -> Scale
octave n (Scale s) = Scale (s { root = s.root + s.period * n })

-------------------------------------------------------------------------------
-- Distribution modes (Natural / Equal) — cf. Instruō Dail
-------------------------------------------------------------------------------

-- | How a continuous or integer value maps onto a Scale's active
-- | pitches.  The two modes are taken straight from Instruō Dail's
-- | quantiser engine:
-- |
-- |   * `Natural` — the value is a position in *pitch-space* (MIDI
-- |     semitones); quantise by snapping to the nearest active note in
-- |     the scale.  CV threshold to move from one note to the next is
-- |     the real semitone distance between them.  A linear ramp
-- |     through a sparse scale spends more time on widely-spaced
-- |     intervals — the V/oct-shaped melodic line.
-- |
-- |   * `Equal` — the value is a position in the *index-space* (degree
-- |     index, 1-based); look up `intervals[value-1]` directly.  Each
-- |     active note gets an equal share of the input range, regardless
-- |     of pitch distance.  A linear ramp through degrees steps through
-- |     the scale's notes one-by-one — the evenly-spaced-through-scale
-- |     melodic line.
-- |
-- | These map directly onto the existing carrier: `Degree d` resolves
-- | Equal (via `renderDegree`); `Chromatic n` is raw MIDI, with optional
-- | Natural quantisation via `quantiseToScale`.  `applyDistribution`
-- | unifies the two so callers can switch modes at runtime.
data Distribution = Natural | Equal

derive instance eqDistribution :: Eq Distribution
derive instance ordDistribution :: Ord Distribution

instance showDistribution :: Show Distribution where
  show Natural = "Natural"
  show Equal   = "Equal"

-- | Snap a MIDI value to the nearest active note in the scale
-- | (**Natural Distribution**).  The value is interpreted as an
-- | absolute MIDI semitone; the scale's `intervals + period` define
-- | the set of valid notes, and the nearest one (by absolute semitone
-- | distance) is returned.
-- |
-- | Examples in C major (intervals = [0,2,4,5,7,9,11], period = 12):
-- |   `quantiseToScale cMajor 60` = 60  (C4, already in scale)
-- |   `quantiseToScale cMajor 61` = 60  (C#4 → C4)
-- |   `quantiseToScale cMajor 63` = 64  (D#4 → E4)
-- |   `quantiseToScale cMajor 72` = 72  (C5 — next period's degree 1)
-- |
-- | In a Dail-style multi-octave scale where the period is 24 and the
-- | intervals span more than one octave, this still does the right
-- | thing — the nearest active note may be in the same period or the
-- | adjacent one.  Empty `intervals` leaves the value unchanged.
quantiseToScale :: Scale -> Int -> Int
quantiseToScale (Scale s) midi =
  let
    dist   = midi - s.root
    bucket =
      if dist >= 0
        then dist / s.period
        else -((-dist - 1) / s.period + 1)
    -- Consider candidates from the bucket the value falls in, plus
    -- one period above and below — handles values near period
    -- boundaries cleanly without special-casing the wrap.
    buckets = [bucket - 1, bucket, bucket + 1]
    candidates :: Array Int
    candidates = do
      b <- buckets
      i <- s.intervals
      pure (s.root + i + b * s.period)
    pickCloser :: { v :: Int, d :: Int } -> Int -> { v :: Int, d :: Int }
    pickCloser best c =
      let d = if c > midi then c - midi else midi - c
      in if d < best.d then { v: c, d } else best
  in
    -- Initial d = 999999 is comfortably larger than any plausible
    -- MIDI distance; falls back to `midi` unchanged if the scale's
    -- intervals array is empty.
    (foldl pickCloser { v: midi, d: 999999 } candidates).v

-- | Unify the two distribution modes behind a single signature.  The
-- | Int input is interpreted differently per mode:
-- |
-- |   * `applyDistribution Natural s n` — `n` is a MIDI semitone;
-- |     snap to nearest scale note.  (= `quantiseToScale s n`)
-- |   * `applyDistribution Equal   s d` — `d` is a 1-based degree
-- |     index; look up in scale.  (= `renderDegree s d`)
-- |
-- | Used by callers (e.g. a sequencer vmod) that carry a single
-- | `Array Int` of values and a runtime `Distribution` choice — the
-- | same data flips between two musical idioms.
applyDistribution :: Distribution -> Scale -> Int -> Int
applyDistribution Natural = quantiseToScale
applyDistribution Equal   = renderDegree
