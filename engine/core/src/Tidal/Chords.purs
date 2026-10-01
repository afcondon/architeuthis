-- | Chord definitions for Tidal mini-notation
-- |
-- | Contains standard chord voicings used in `c'major`, `e'minor` syntax.
-- | Based on TidalCycles chord definitions.
module Tidal.Chords
  ( lookupChord
  , lookupTidalChord
  , chordTable
  , chordNames
  -- * Modifiers
  , Modifier(..)
  , Modifiers(..)
  , applyModifier
  , applyModifiers
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
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Tidal.Pattern.Types (class TidalEnum)

-------------------------------------------------------------------------------
-- Chord modifiers
-------------------------------------------------------------------------------

-- | Chord voicing modifiers
-- |
-- | These modify how chord notes are arranged:
-- | - `Invert` - Move the bass note up an octave
-- | - `Range n` - Take n notes from octave-extended chord
-- | - `Drop n` - Drop the nth voice from top down an octave
-- | - `Open` - Open voicing (spread notes across octaves)
data Modifier
  = Invert
  | Range Int
  | Drop Int
  | Open

derive instance eqModifier :: Eq Modifier

instance showModifier :: Show Modifier where
  show Invert = "Invert"
  show (Range n) = "Range " <> show n
  show (Drop n) = "Drop " <> show n
  show Open = "Open"

-- | A list of modifiers, one atom of a chord's modifier pattern
-- | (`c'major'<i 5>` has two). Tidal's `[Modifier]`.
newtype Modifiers = Modifiers (Array Modifier)

derive instance Eq Modifiers

instance Show Modifiers where
  show (Modifiers ms) = show ms

-- | They enumerate as the two ends, as Tidal's `fromTo` for `[Modifier]`;
-- | a chord never transposes them.
instance tidalEnumModifiers :: TidalEnum Modifiers where
  enumRange a b = [ a, b ]
  addSemitones _ ms = ms

-- | Apply a single modifier to chord intervals
applyModifier :: Modifier -> Array Int -> Array Int
applyModifier Invert notes = case Array.uncons notes of
  Nothing -> notes
  Just { head: d, tail: ds } -> ds <> [d + 12]
applyModifier (Range i) notes =
  -- Take i notes from the chord repeated up the octaves, as many as needed.
  let
    n = max 1 (Array.length notes)
    octaves = Array.concat $ map (\k -> map (_ + 12 * k) notes) (Array.range 0 (i / n + 1))
  in Array.take i octaves
applyModifier (Drop i) notes =
  -- Drop the ith voice from top down an octave
  let len = Array.length notes
      s = len - i
  in if len < i then notes
     else case Array.index notes s of
       Nothing -> notes
       Just dropped ->
         let xs = Array.take s notes
             ys = Array.drop (s + 1) notes
         in Array.cons (dropped - 12) (xs <> ys)
applyModifier Open notes =
  -- Open voicing: move middle voice(s) down an octave
  if Array.length notes <= 2 then notes
  else
    let bass = fromMaybe 0 (Array.index notes 0)
        third = fromMaybe 0 (Array.index notes 1)
        fifth = fromMaybe 0 (Array.index notes 2)
        rest = Array.drop 3 notes
    in [bass - 12, fifth - 12, third] <> rest

-- | Apply multiple modifiers in sequence
applyModifiers :: Array Modifier -> Array Int -> Array Int
applyModifiers mods notes = foldl (flip applyModifier) notes mods

-------------------------------------------------------------------------------
-- Chord lookup
-------------------------------------------------------------------------------

-- | Look up a chord by name as Haskell Tidal does: its own table only, first
-- | match wins. An unknown name is `Nothing`; Tidal then plays the root.
lookupTidalChord :: String -> Maybe (Array Int)
lookupTidalChord name = Array.find (\(Tuple n _) -> n == name) chordTable
  >>= \(Tuple _ intervals) -> Just intervals

-- | Look up a chord for the typed-cue path: Tidal's table, then the names
-- | this library had before it followed Tidal (`7`, `9`, `sus`, …).
lookupChord :: String -> Maybe (Array Int)
lookupChord name = case lookupTidalChord name of
  Just intervals -> Just intervals
  Nothing -> Array.find (\(Tuple n _) -> n == name) legacyChords
    >>= \(Tuple _ intervals) -> Just intervals

-- | Every chord name either lookup knows.
chordNames :: Array String
chordNames = map (\(Tuple n _) -> n) (chordTable <> legacyChords)

-- | Haskell Tidal 1.10.1's `chordTable`, in its order, generated from GHCi
-- | (`Sound.Tidal.Chords.chordTable`). Its quirks are kept on purpose:
-- | `dom9` is [0,4,7,14] and `9s5` [0,1,13], as in Tidal.
chordTable :: Array (Tuple String (Array Int))
chordTable =
  [ Tuple "major" [0, 4, 7]
  , Tuple "maj" [0, 4, 7]
  , Tuple "M" [0, 4, 7]
  , Tuple "aug" [0, 4, 8]
  , Tuple "plus" [0, 4, 8]
  , Tuple "sharp5" [0, 4, 8]
  , Tuple "six" [0, 4, 7, 9]
  , Tuple "6" [0, 4, 7, 9]
  , Tuple "sixNine" [0, 4, 7, 9, 14]
  , Tuple "six9" [0, 4, 7, 9, 14]
  , Tuple "sixby9" [0, 4, 7, 9, 14]
  , Tuple "6by9" [0, 4, 7, 9, 14]
  , Tuple "major7" [0, 4, 7, 11]
  , Tuple "maj7" [0, 4, 7, 11]
  , Tuple "M7" [0, 4, 7, 11]
  , Tuple "major9" [0, 4, 7, 11, 14]
  , Tuple "maj9" [0, 4, 7, 11, 14]
  , Tuple "M9" [0, 4, 7, 11, 14]
  , Tuple "add9" [0, 4, 7, 14]
  , Tuple "major11" [0, 4, 7, 11, 14, 17]
  , Tuple "maj11" [0, 4, 7, 11, 14, 17]
  , Tuple "M11" [0, 4, 7, 11, 14, 17]
  , Tuple "add11" [0, 4, 7, 17]
  , Tuple "major13" [0, 4, 7, 11, 14, 21]
  , Tuple "maj13" [0, 4, 7, 11, 14, 21]
  , Tuple "M13" [0, 4, 7, 11, 14, 21]
  , Tuple "add13" [0, 4, 7, 21]
  , Tuple "dom7" [0, 4, 7, 10]
  , Tuple "dom9" [0, 4, 7, 14]
  , Tuple "dom11" [0, 4, 7, 17]
  , Tuple "dom13" [0, 4, 7, 21]
  , Tuple "sevenFlat5" [0, 4, 6, 10]
  , Tuple "7f5" [0, 4, 6, 10]
  , Tuple "sevenSharp5" [0, 4, 8, 10]
  , Tuple "7s5" [0, 4, 8, 10]
  , Tuple "sevenFlat9" [0, 4, 7, 10, 13]
  , Tuple "7f9" [0, 4, 7, 10, 13]
  , Tuple "nine" [0, 4, 7, 10, 14]
  , Tuple "eleven" [0, 4, 7, 10, 14, 17]
  , Tuple "11" [0, 4, 7, 10, 14, 17]
  , Tuple "thirteen" [0, 4, 7, 10, 14, 17, 21]
  , Tuple "13" [0, 4, 7, 10, 14, 17, 21]
  , Tuple "minor" [0, 3, 7]
  , Tuple "min" [0, 3, 7]
  , Tuple "m" [0, 3, 7]
  , Tuple "diminished" [0, 3, 6]
  , Tuple "dim" [0, 3, 6]
  , Tuple "minorSharp5" [0, 3, 8]
  , Tuple "msharp5" [0, 3, 8]
  , Tuple "mS5" [0, 3, 8]
  , Tuple "minor6" [0, 3, 7, 9]
  , Tuple "min6" [0, 3, 7, 9]
  , Tuple "m6" [0, 3, 7, 9]
  , Tuple "minorSixNine" [0, 3, 9, 7, 14]
  , Tuple "minor69" [0, 3, 9, 7, 14]
  , Tuple "min69" [0, 3, 9, 7, 14]
  , Tuple "minSixNine" [0, 3, 9, 7, 14]
  , Tuple "m69" [0, 3, 9, 7, 14]
  , Tuple "mSixNine" [0, 3, 9, 7, 14]
  , Tuple "m6by9" [0, 3, 9, 7, 14]
  , Tuple "minor7flat5" [0, 3, 6, 10]
  , Tuple "minor7f5" [0, 3, 6, 10]
  , Tuple "min7flat5" [0, 3, 6, 10]
  , Tuple "min7f5" [0, 3, 6, 10]
  , Tuple "m7flat5" [0, 3, 6, 10]
  , Tuple "m7f5" [0, 3, 6, 10]
  , Tuple "minor7" [0, 3, 7, 10]
  , Tuple "min7" [0, 3, 7, 10]
  , Tuple "m7" [0, 3, 7, 10]
  , Tuple "minor7sharp5" [0, 3, 8, 10]
  , Tuple "minor7s5" [0, 3, 8, 10]
  , Tuple "min7sharp5" [0, 3, 8, 10]
  , Tuple "min7s5" [0, 3, 8, 10]
  , Tuple "m7sharp5" [0, 3, 8, 10]
  , Tuple "m7s5" [0, 3, 8, 10]
  , Tuple "minor7flat9" [0, 3, 7, 10, 13]
  , Tuple "minor7f9" [0, 3, 7, 10, 13]
  , Tuple "min7flat9" [0, 3, 7, 10, 13]
  , Tuple "min7f9" [0, 3, 7, 10, 13]
  , Tuple "m7flat9" [0, 3, 7, 10, 13]
  , Tuple "m7f9" [0, 3, 7, 10, 13]
  , Tuple "minor7sharp9" [0, 3, 7, 10, 15]
  , Tuple "minor7s9" [0, 3, 7, 10, 15]
  , Tuple "min7sharp9" [0, 3, 7, 10, 15]
  , Tuple "min7s9" [0, 3, 7, 10, 15]
  , Tuple "m7sharp9" [0, 3, 7, 10, 15]
  , Tuple "m7s9" [0, 3, 7, 10, 15]
  , Tuple "diminished7" [0, 3, 6, 9]
  , Tuple "dim7" [0, 3, 6, 9]
  , Tuple "minor9" [0, 3, 7, 10, 14]
  , Tuple "min9" [0, 3, 7, 10, 14]
  , Tuple "m9" [0, 3, 7, 10, 14]
  , Tuple "minor11" [0, 3, 7, 10, 14, 17]
  , Tuple "min11" [0, 3, 7, 10, 14, 17]
  , Tuple "m11" [0, 3, 7, 10, 14, 17]
  , Tuple "minor13" [0, 3, 7, 10, 14, 17, 21]
  , Tuple "min13" [0, 3, 7, 10, 14, 17, 21]
  , Tuple "m13" [0, 3, 7, 10, 14, 17, 21]
  , Tuple "minorMajor7" [0, 3, 7, 11]
  , Tuple "minMaj7" [0, 3, 7, 11]
  , Tuple "mmaj7" [0, 3, 7, 11]
  , Tuple "one" [0]
  , Tuple "1" [0]
  , Tuple "five" [0, 7]
  , Tuple "5" [0, 7]
  , Tuple "sus2" [0, 2, 7]
  , Tuple "sus4" [0, 5, 7]
  , Tuple "sevenSus2" [0, 2, 7, 10]
  , Tuple "7sus2" [0, 2, 7, 10]
  , Tuple "sevenSus4" [0, 5, 7, 10]
  , Tuple "7sus4" [0, 5, 7, 10]
  , Tuple "nineSus4" [0, 5, 7, 10, 14]
  , Tuple "ninesus4" [0, 5, 7, 10, 14]
  , Tuple "9sus4" [0, 5, 7, 10, 14]
  , Tuple "sevenFlat10" [0, 4, 7, 10, 15]
  , Tuple "7f10" [0, 4, 7, 10, 15]
  , Tuple "nineSharp5" [0, 1, 13]
  , Tuple "9sharp5" [0, 1, 13]
  , Tuple "9s5" [0, 1, 13]
  , Tuple "minor9sharp5" [0, 1, 14]
  , Tuple "minor9s5" [0, 1, 14]
  , Tuple "min9sharp5" [0, 1, 14]
  , Tuple "min9s5" [0, 1, 14]
  , Tuple "m9sharp5" [0, 1, 14]
  , Tuple "m9s5" [0, 1, 14]
  , Tuple "sevenSharp5flat9" [0, 4, 8, 10, 13]
  , Tuple "7s5f9" [0, 4, 8, 10, 13]
  , Tuple "minor7sharp5flat9" [0, 3, 8, 10, 13]
  , Tuple "m7sharp5flat9" [0, 3, 8, 10, 13]
  , Tuple "elevenSharp" [0, 4, 7, 10, 14, 18]
  , Tuple "11s" [0, 4, 7, 10, 14, 18]
  , Tuple "minor11sharp" [0, 3, 7, 10, 14, 18]
  , Tuple "m11sharp" [0, 3, 7, 10, 14, 18]
  , Tuple "m11s" [0, 3, 7, 10, 14, 18]
  ]

-- | Names this library knew before it followed Tidal's table, and Tidal
-- | does not: the typed-cue path still reads them.
legacyChords :: Array (Tuple String (Array Int))
legacyChords =
  [ Tuple "7" dom7
  , Tuple "aug7" aug7
  , Tuple "m7b5" halfDim7
  , Tuple "halfDim" halfDim7
  , Tuple "9" [ 0, 4, 7, 10, 14 ]
  , Tuple "sus" sus4
  , Tuple "7sus" sevenSus4
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
