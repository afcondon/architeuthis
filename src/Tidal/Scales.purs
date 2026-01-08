-- | Musical scales for Tidal mini-notation
-- |
-- | Provides scale definitions and functions to convert scale degrees
-- | to semitone offsets. Based on TidalCycles scales.
-- |
-- | Usage:
-- | ```purescript
-- | -- Get the notes of C major scale for degrees 0-7
-- | scale "major" [0, 1, 2, 3, 4, 5, 6, 7]
-- | -- Returns: [0, 2, 4, 5, 7, 9, 11, 12]
-- | ```
module Tidal.Scales
  ( -- * Scale lookup
    lookupScale
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
import Data.Int (toNumber)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

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
