-- | Chord definitions for Tidal mini-notation
-- |
-- | Contains standard chord voicings used in `c'major`, `e'minor` syntax.
-- | Based on TidalCycles chord definitions.
module Tidal.Chords
  ( lookupChord
  , chordNames
  -- * Basic triads
  , major
  , minor
  , aug
  , dim
  -- * Seventh chords
  , major7
  , minor7
  , dom7
  , dim7
  , aug7
  , halfDim7
  -- * Extended chords
  , major9
  , minor9
  , dom9
  , major11
  , minor11
  , major13
  , minor13
  -- * Suspended chords
  , sus2
  , sus4
  , sevenSus4
  -- * Other common chords
  , six
  , minor6
  , add9
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

-------------------------------------------------------------------------------
-- Chord lookup
-------------------------------------------------------------------------------

-- | Look up a chord by name, returning intervals from root
lookupChord :: String -> Maybe (Array Int)
lookupChord name = Array.find (\(Tuple n _) -> n == name) chordTable
  >>= \(Tuple _ intervals) -> Just intervals

-- | List of all supported chord names
chordNames :: Array String
chordNames = map (\(Tuple n _) -> n) chordTable

-- | Chord lookup table: name -> intervals
chordTable :: Array (Tuple String (Array Int))
chordTable =
  -- Major triads
  [ Tuple "major" major
  , Tuple "maj" major
  , Tuple "M" major

  -- Minor triads
  , Tuple "minor" minor
  , Tuple "min" minor
  , Tuple "m" minor

  -- Augmented
  , Tuple "aug" aug
  , Tuple "plus" aug

  -- Diminished
  , Tuple "dim" dim
  , Tuple "diminished" dim

  -- Major 7th
  , Tuple "major7" major7
  , Tuple "maj7" major7
  , Tuple "M7" major7

  -- Minor 7th
  , Tuple "minor7" minor7
  , Tuple "min7" minor7
  , Tuple "m7" minor7

  -- Dominant 7th
  , Tuple "dom7" dom7
  , Tuple "7" dom7

  -- Diminished 7th
  , Tuple "dim7" dim7
  , Tuple "diminished7" dim7

  -- Augmented 7th
  , Tuple "aug7" aug7

  -- Half-diminished (minor 7 flat 5)
  , Tuple "m7b5" halfDim7
  , Tuple "m7flat5" halfDim7
  , Tuple "halfDim" halfDim7

  -- 9th chords
  , Tuple "major9" major9
  , Tuple "maj9" major9
  , Tuple "M9" major9
  , Tuple "minor9" minor9
  , Tuple "min9" minor9
  , Tuple "m9" minor9
  , Tuple "dom9" dom9
  , Tuple "9" dom9

  -- 11th chords
  , Tuple "major11" major11
  , Tuple "maj11" major11
  , Tuple "M11" major11
  , Tuple "minor11" minor11
  , Tuple "min11" minor11
  , Tuple "m11" minor11

  -- 13th chords
  , Tuple "major13" major13
  , Tuple "maj13" major13
  , Tuple "M13" major13
  , Tuple "minor13" minor13
  , Tuple "min13" minor13
  , Tuple "m13" minor13

  -- Suspended
  , Tuple "sus2" sus2
  , Tuple "sus4" sus4
  , Tuple "sus" sus4
  , Tuple "7sus4" sevenSus4
  , Tuple "7sus" sevenSus4

  -- 6th chords
  , Tuple "six" six
  , Tuple "6" six
  , Tuple "minor6" minor6
  , Tuple "min6" minor6
  , Tuple "m6" minor6

  -- Add chords
  , Tuple "add9" add9
  , Tuple "add2" add9
  ]

-------------------------------------------------------------------------------
-- Basic triads
-------------------------------------------------------------------------------

-- | Major triad: root, major 3rd, perfect 5th
major :: Array Int
major = [0, 4, 7]

-- | Minor triad: root, minor 3rd, perfect 5th
minor :: Array Int
minor = [0, 3, 7]

-- | Augmented triad: root, major 3rd, augmented 5th
aug :: Array Int
aug = [0, 4, 8]

-- | Diminished triad: root, minor 3rd, diminished 5th
dim :: Array Int
dim = [0, 3, 6]

-------------------------------------------------------------------------------
-- Seventh chords
-------------------------------------------------------------------------------

-- | Major 7th: root, major 3rd, perfect 5th, major 7th
major7 :: Array Int
major7 = [0, 4, 7, 11]

-- | Minor 7th: root, minor 3rd, perfect 5th, minor 7th
minor7 :: Array Int
minor7 = [0, 3, 7, 10]

-- | Dominant 7th: root, major 3rd, perfect 5th, minor 7th
dom7 :: Array Int
dom7 = [0, 4, 7, 10]

-- | Diminished 7th: root, minor 3rd, diminished 5th, diminished 7th
dim7 :: Array Int
dim7 = [0, 3, 6, 9]

-- | Augmented 7th: root, major 3rd, augmented 5th, minor 7th
aug7 :: Array Int
aug7 = [0, 4, 8, 10]

-- | Half-diminished (minor 7 flat 5): root, minor 3rd, diminished 5th, minor 7th
halfDim7 :: Array Int
halfDim7 = [0, 3, 6, 10]

-------------------------------------------------------------------------------
-- Extended chords
-------------------------------------------------------------------------------

-- | Major 9th
major9 :: Array Int
major9 = [0, 4, 7, 11, 14]

-- | Minor 9th
minor9 :: Array Int
minor9 = [0, 3, 7, 10, 14]

-- | Dominant 9th
dom9 :: Array Int
dom9 = [0, 4, 7, 10, 14]

-- | Major 11th
major11 :: Array Int
major11 = [0, 4, 7, 11, 14, 17]

-- | Minor 11th
minor11 :: Array Int
minor11 = [0, 3, 7, 10, 14, 17]

-- | Major 13th
major13 :: Array Int
major13 = [0, 4, 7, 11, 14, 21]

-- | Minor 13th
minor13 :: Array Int
minor13 = [0, 3, 7, 10, 14, 17, 21]

-------------------------------------------------------------------------------
-- Suspended chords
-------------------------------------------------------------------------------

-- | Suspended 2nd: root, major 2nd, perfect 5th
sus2 :: Array Int
sus2 = [0, 2, 7]

-- | Suspended 4th: root, perfect 4th, perfect 5th
sus4 :: Array Int
sus4 = [0, 5, 7]

-- | Dominant 7 sus 4
sevenSus4 :: Array Int
sevenSus4 = [0, 5, 7, 10]

-------------------------------------------------------------------------------
-- Other common chords
-------------------------------------------------------------------------------

-- | Major 6th: root, major 3rd, perfect 5th, major 6th
six :: Array Int
six = [0, 4, 7, 9]

-- | Minor 6th
minor6 :: Array Int
minor6 = [0, 3, 7, 9]

-- | Add 9 (major triad + 9th, no 7th)
add9 :: Array Int
add9 = [0, 4, 7, 14]
