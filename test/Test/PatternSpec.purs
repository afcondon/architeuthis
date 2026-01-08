-- | Pattern evaluation tests
-- |
-- | Tests the complete chain: parse → evaluate → query → verify events
-- | This allows testing pattern behavior without needing MIDI or audio.
module Test.PatternSpec where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt, toNumber, (%))
import Effect (Effect)
import Effect.Console (log)
import Tidal.AST.Types (TPat)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Parser (parseTPat, parseChord)
import Tidal.Pattern.Core (cat, fast, fastAppend, fastCat, queryArc, rev, rotL, rotR, slow, stack)
import Data.Newtype (unwrap)
import Tidal.Pattern.Types (Arc(..), Event(..), Note, Pattern, arcStart, arcStop, mkNote)

-------------------------------------------------------------------------------
-- Test runner
-------------------------------------------------------------------------------

-- | Run all pattern evaluation tests
runPatternTests :: Effect Unit
runPatternTests = do
  log ""
  log "=========================================="
  log "  Pattern Evaluation Tests"
  log "=========================================="
  log ""

  -- Basic patterns
  log "--- Sequence Patterns ---"
  testPattern "bd"
    "single sound"
    1
    [{ sample: "bd", start: 0.0, stop: 1.0 }]

  testPattern "bd sn"
    "two sounds"
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

  testPattern "bd sn hh cp"
    "four sounds"
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "sn", start: 0.25, stop: 0.5 }
    , { sample: "hh", start: 0.5, stop: 0.75 }
    , { sample: "cp", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- Silence ---"
  testPattern "bd ~ sn"
    "with rest"
    2
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "sn", start: 0.666, stop: 1.0 }
    ]

  log ""
  log "--- Stack (Parallel) Patterns ---"
  testPattern "bd, sn"
    "two parallel sounds"
    2
    [ { sample: "bd", start: 0.0, stop: 1.0 }
    , { sample: "sn", start: 0.0, stop: 1.0 }
    ]

  testPattern "bd sn, hh"
    "sequence + single"
    3
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    , { sample: "hh", start: 0.0, stop: 1.0 }
    ]

  log ""
  log "--- Speed Modifiers ---"
  testPattern "bd*2"
    "fast x2"
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 1.0 }
    ]

  testPattern "bd*4"
    "fast x4"
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- Euclidean Rhythms ---"
  -- E(3,8) = [1,0,0,1,0,0,1,0] hits at positions 0, 3, 6 (of 8)
  testPattern "bd(3,8)"
    "euclidean 3,8"
    3
    [ { sample: "bd", start: 0.0, stop: 0.125 }      -- position 0/8
    , { sample: "bd", start: 0.375, stop: 0.5 }     -- position 3/8
    , { sample: "bd", start: 0.75, stop: 0.875 }    -- position 6/8
    ]

  -- E(5,8) = [1,0,1,1,0,1,1,0] hits at positions 0, 2, 3, 5, 6 (of 8)
  testPattern "bd(5,8)"
    "euclidean 5,8"
    5
    [ { sample: "bd", start: 0.0, stop: 0.125 }      -- position 0/8
    , { sample: "bd", start: 0.25, stop: 0.375 }    -- position 2/8
    , { sample: "bd", start: 0.375, stop: 0.5 }     -- position 3/8
    , { sample: "bd", start: 0.625, stop: 0.75 }    -- position 5/8
    , { sample: "bd", start: 0.75, stop: 0.875 }    -- position 6/8
    ]

  log ""
  log "--- Groups ---"
  testPattern "[bd sn]"
    "simple group"
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

  testPattern "[bd sn]*2"
    "group fast x2"
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "sn", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 0.75 }
    , { sample: "sn", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "=========================================="
  log "  Core Combinator Tests"
  log "=========================================="
  log ""

  runCombinatorTests

  log ""
  log "=========================================="
  log "  Toussaint Euclidean Rhythms"
  log "=========================================="
  log ""

  runToussaintTests

  log ""
  log "=========================================="
  log "  Pattern Tests Complete"
  log "=========================================="

-------------------------------------------------------------------------------
-- Core Combinator Tests
-------------------------------------------------------------------------------

-- | Tests for pattern combinators using the Pattern API directly
runCombinatorTests :: Effect Unit
runCombinatorTests = do
  -- cat: patterns play in sequence across cycles
  log "--- cat (slowCat) ---"
  testPatternDirect "cat [bd, sn] cycle 0"
    (cat [pure "bd", pure "sn"])
    (fromInt 0) (fromInt 1)
    1
    [{ sample: "bd", start: 0.0, stop: 1.0 }]

  testPatternDirect "cat [bd, sn] cycle 1"
    (cat [pure "bd", pure "sn"])
    (fromInt 1) (fromInt 2)
    1
    [{ sample: "sn", start: 1.0, stop: 2.0 }]

  testPatternDirect "cat [bd, sn] cycle 2 (wraps)"
    (cat [pure "bd", pure "sn"])
    (fromInt 2) (fromInt 3)
    1
    [{ sample: "bd", start: 2.0, stop: 3.0 }]

  log ""
  log "--- fastCat ---"
  testPatternDirect "fastCat [bd, sn] (both in one cycle)"
    (fastCat [pure "bd", pure "sn"])
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

  testPatternDirect "fastCat [bd, sn, hh] (three in one cycle)"
    (fastCat [pure "bd", pure "sn", pure "hh"])
    (fromInt 0) (fromInt 1)
    3
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "sn", start: 0.333, stop: 0.666 }
    , { sample: "hh", start: 0.666, stop: 1.0 }
    ]

  log ""
  log "--- stack ---"
  testPatternDirect "stack [bd, sn] (both simultaneous)"
    (stack [pure "bd", pure "sn"])
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 1.0 }
    , { sample: "sn", start: 0.0, stop: 1.0 }
    ]

  log ""
  log "--- rev ---"
  testPatternDirect "rev (bd sn) - reversed sequence"
    (rev (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "sn", start: 0.0, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 1.0 }
    ]

  testPatternDirect "rev (bd sn hh cp)"
    (rev (fastCat [pure "bd", pure "sn", pure "hh", pure "cp"]))
    (fromInt 0) (fromInt 1)
    4
    [ { sample: "cp", start: 0.0, stop: 0.25 }
    , { sample: "hh", start: 0.25, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- fast/slow ---"
  testPatternDirect "fast 2 bd"
    (fast (fromInt 2) (pure "bd"))
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 1.0 }
    ]

  testPatternDirect "fast 4 bd"
    (fast (fromInt 4) (pure "bd"))
    (fromInt 0) (fromInt 1)
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.5, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  testPatternDirect "slow 2 (bd sn)"
    (slow (fromInt 2) (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    1
    [{ sample: "bd", start: 0.0, stop: 1.0 }]

  testPatternDirect "slow 2 (bd sn) cycle 1"
    (slow (fromInt 2) (fastCat [pure "bd", pure "sn"]))
    (fromInt 1) (fromInt 2)
    1
    [{ sample: "sn", start: 1.0, stop: 2.0 }]

  log ""
  log "--- rotL/rotR (time rotation) ---"
  -- rotL shifts pattern earlier in time (events wrap around)
  -- Original: bd@0-0.5, sn@0.5-1.0
  -- After rotL 0.25: bd@-0.25-0.25, sn@0.25-0.75, bd@0.75-1.25 (wraps)
  -- Query 0-1 sees parts of all three
  testPatternDirect "rotL 0.25 (bd sn)"
    (rotL (1 % 4) (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    3
    [ { sample: "bd", start: 0.0, stop: 0.25 }   -- tail of first bd
    , { sample: "sn", start: 0.25, stop: 0.75 }  -- full sn
    , { sample: "bd", start: 0.75, stop: 1.0 }   -- head of wrapped bd
    ]

  -- rotR shifts pattern later in time
  -- Original: bd@0-0.5, sn@0.5-1.0
  -- After rotR 0.25: sn@-0.25-0.25, bd@0.25-0.75, sn@0.75-1.25 (wraps)
  testPatternDirect "rotR 0.25 (bd sn)"
    (rotR (1 % 4) (fastCat [pure "bd", pure "sn"]))
    (fromInt 0) (fromInt 1)
    3
    [ { sample: "sn", start: 0.0, stop: 0.25 }   -- tail of shifted sn
    , { sample: "bd", start: 0.25, stop: 0.75 }  -- full bd
    , { sample: "sn", start: 0.75, stop: 1.0 }   -- head of wrapped sn
    ]

  log ""
  log "--- fastAppend ---"
  testPatternDirect "fastAppend bd sn"
    (fastAppend (pure "bd") (pure "sn"))
    (fromInt 0) (fromInt 1)
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

-------------------------------------------------------------------------------
-- Toussaint Euclidean Paper Examples
-- Reference: "The Euclidean Algorithm Generates Traditional Musical Rhythms"
--            by Godfried Toussaint (2005)
-------------------------------------------------------------------------------

-- | Tests for Euclidean rhythms from Toussaint's paper
runToussaintTests :: Effect Unit
runToussaintTests = do
  -- From the Tidal test suite (UITest.hs) and Toussaint's paper
  -- Note: Hit positions are 0-indexed step numbers within the total steps

  log "--- Classic Euclidean Rhythms ---"

  -- E(1,2) = [1,0] - simple half note
  testPattern "bd(1,2)"
    "E(1,2) - half"
    1
    [{ sample: "bd", start: 0.0, stop: 0.5 }]

  -- E(1,3) = [1,0,0] - dotted half note feel
  testPattern "bd(1,3)"
    "E(1,3) - dotted half"
    1
    [{ sample: "bd", start: 0.0, stop: 0.333 }]

  -- E(1,4) = [1,0,0,0] - whole note
  testPattern "bd(1,4)"
    "E(1,4) - whole"
    1
    [{ sample: "bd", start: 0.0, stop: 0.25 }]

  -- E(2,3) = [1,0,1] - triadic rhythm
  testPattern "bd(2,3)"
    "E(2,3) - triadic"
    2
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "bd", start: 0.666, stop: 1.0 }
    ]

  -- E(2,5) = [1,0,1,0,0] - Persian rhythm (khafif-e-ramal)
  testPattern "bd(2,5)"
    "E(2,5) - khafif-e-ramal"
    2
    [ { sample: "bd", start: 0.0, stop: 0.2 }
    , { sample: "bd", start: 0.4, stop: 0.6 }
    ]

  -- E(3,4) = [1,1,0,1] - hits at 0,1,3
  testPattern "bd(3,4)"
    "E(3,4) - three of four"
    3
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "bd", start: 0.75, stop: 1.0 }
    ]

  -- E(3,5) = [1,0,1,0,1] - Persian rhythm (khafif-e-ramal variant)
  testPattern "bd(3,5)"
    "E(3,5) - Persian"
    3
    [ { sample: "bd", start: 0.0, stop: 0.2 }
    , { sample: "bd", start: 0.4, stop: 0.6 }
    , { sample: "bd", start: 0.8, stop: 1.0 }
    ]

  -- E(3,7) = [1,0,1,0,1,0,0] - Ruchenitza rhythm (Bulgarian)
  testPattern "bd(3,7)"
    "E(3,7) - Ruchenitza"
    3
    [ { sample: "bd", start: 0.0, stop: 0.142 }
    , { sample: "bd", start: 0.285, stop: 0.428 }
    , { sample: "bd", start: 0.571, stop: 0.714 }
    ]

  -- E(4,7) = [1,0,1,0,1,0,1] - alternating pattern
  testPattern "bd(4,7)"
    "E(4,7) - alternating 4/7"
    4
    [ { sample: "bd", start: 0.0, stop: 0.142 }
    , { sample: "bd", start: 0.285, stop: 0.428 }
    , { sample: "bd", start: 0.571, stop: 0.714 }
    , { sample: "bd", start: 0.857, stop: 1.0 }
    ]

  -- E(4,9) = [1,0,1,0,1,0,1,0,0] - Aksak rhythm (Turkey)
  testPattern "bd(4,9)"
    "E(4,9) - Aksak"
    4
    [ { sample: "bd", start: 0.0, stop: 0.111 }
    , { sample: "bd", start: 0.222, stop: 0.333 }
    , { sample: "bd", start: 0.444, stop: 0.555 }
    , { sample: "bd", start: 0.666, stop: 0.777 }
    ]

  -- E(5,6) = [1,1,1,0,1,1] - hits at 0,1,2,4,5
  testPattern "bd(5,6)"
    "E(5,6) - five of six"
    5
    [ { sample: "bd", start: 0.0, stop: 0.166 }
    , { sample: "bd", start: 0.166, stop: 0.333 }
    , { sample: "bd", start: 0.333, stop: 0.5 }
    , { sample: "bd", start: 0.666, stop: 0.833 }
    , { sample: "bd", start: 0.833, stop: 1.0 }
    ]

  -- E(5,7) = [1,0,1,1,0,1,1] - hits at 0,2,3,5,6
  testPattern "bd(5,7)"
    "E(5,7) - five of seven"
    5
    [ { sample: "bd", start: 0.0, stop: 0.142 }
    , { sample: "bd", start: 0.285, stop: 0.428 }
    , { sample: "bd", start: 0.428, stop: 0.571 }
    , { sample: "bd", start: 0.714, stop: 0.857 }
    , { sample: "bd", start: 0.857, stop: 1.0 }
    ]

  log ""
  log "--- Afro-Cuban Clave Patterns ---"

  -- E(5,8) = [1,0,1,1,0,1,1,0] - Cuban cinquillo
  testPattern "bd(5,8)"
    "E(5,8) - Cuban cinquillo"
    5
    [ { sample: "bd", start: 0.0, stop: 0.125 }
    , { sample: "bd", start: 0.25, stop: 0.375 }
    , { sample: "bd", start: 0.375, stop: 0.5 }
    , { sample: "bd", start: 0.625, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 0.875 }
    ]

  -- E(7,8) = [1,1,1,1,0,1,1,1] - seven of eight with gap at position 4
  testPattern "bd(7,8)"
    "E(7,8) - seven of eight"
    7
    [ { sample: "bd", start: 0.0, stop: 0.125 }
    , { sample: "bd", start: 0.125, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.375 }
    , { sample: "bd", start: 0.375, stop: 0.5 }
    , { sample: "bd", start: 0.625, stop: 0.75 }
    , { sample: "bd", start: 0.75, stop: 0.875 }
    , { sample: "bd", start: 0.875, stop: 1.0 }
    ]

  log ""
  log "--- African Bell Patterns ---"

  -- E(7,12) = [1,0,1,1,0,1,0,1,1,0,1,0] - West African bell (12/8 feel)
  testPattern "bd(7,12)"
    "E(7,12) - West African bell"
    7
    [ { sample: "bd", start: 0.0, stop: 0.083 }
    , { sample: "bd", start: 0.166, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.333 }
    , { sample: "bd", start: 0.416, stop: 0.5 }
    , { sample: "bd", start: 0.583, stop: 0.666 }
    , { sample: "bd", start: 0.666, stop: 0.75 }
    , { sample: "bd", start: 0.833, stop: 0.916 }
    ]

  -- E(5,12) = [1,0,0,1,0,1,0,0,1,0,1,0] - Venda children's song (South Africa)
  testPattern "bd(5,12)"
    "E(5,12) - Venda"
    5
    [ { sample: "bd", start: 0.0, stop: 0.083 }
    , { sample: "bd", start: 0.25, stop: 0.333 }
    , { sample: "bd", start: 0.416, stop: 0.5 }
    , { sample: "bd", start: 0.666, stop: 0.75 }
    , { sample: "bd", start: 0.833, stop: 0.916 }
    ]

  log ""
  log "=========================================="
  log "  Pitched Note Tests"
  log "=========================================="
  log ""

  log "--- Note Name Parsing ---"

  -- Basic note names (octave 5 = reference, c5 = 0)
  testNotePattern "c5"
    "C5 (middle C reference)"
    1
    [ { note: 0, start: 0.0, stop: 1.0 } ]

  testNotePattern "d5"
    "D5"
    1
    [ { note: 2, start: 0.0, stop: 1.0 } ]

  testNotePattern "e5"
    "E5"
    1
    [ { note: 4, start: 0.0, stop: 1.0 } ]

  testNotePattern "g5"
    "G5"
    1
    [ { note: 7, start: 0.0, stop: 1.0 } ]

  testNotePattern "a5"
    "A5"
    1
    [ { note: 9, start: 0.0, stop: 1.0 } ]

  testNotePattern "b5"
    "B5"
    1
    [ { note: 11, start: 0.0, stop: 1.0 } ]

  log ""
  log "--- Octave Variations ---"

  testNotePattern "c4"
    "C4 (one octave below)"
    1
    [ { note: -12, start: 0.0, stop: 1.0 } ]

  testNotePattern "c6"
    "C6 (one octave above)"
    1
    [ { note: 12, start: 0.0, stop: 1.0 } ]

  testNotePattern "a4"
    "A4 (concert pitch reference)"
    1
    [ { note: -3, start: 0.0, stop: 1.0 } ]

  log ""
  log "--- Accidentals ---"

  testNotePattern "cs5"
    "C# (C sharp)"
    1
    [ { note: 1, start: 0.0, stop: 1.0 } ]

  testNotePattern "df5"
    "Db (D flat)"
    1
    [ { note: 1, start: 0.0, stop: 1.0 } ]

  testNotePattern "fs4"
    "F#4 (F sharp, octave 4)"
    1
    [ { note: -6, start: 0.0, stop: 1.0 } ]

  testNotePattern "bf3"
    "Bb3 (B flat, octave 3)"
    1
    [ { note: -14, start: 0.0, stop: 1.0 } ]

  log ""
  log "--- Note Sequences ---"

  testNotePattern "c5 e5 g5"
    "C major triad"
    3
    [ { note: 0, start: 0.0, stop: 0.333 }
    , { note: 4, start: 0.333, stop: 0.666 }
    , { note: 7, start: 0.666, stop: 1.0 }
    ]

  testNotePattern "c4 d4 e4 f4 g4 a4 b4 c5"
    "C major scale"
    8
    [ { note: -12, start: 0.0, stop: 0.125 }
    , { note: -10, start: 0.125, stop: 0.25 }
    , { note: -8, start: 0.25, stop: 0.375 }
    , { note: -7, start: 0.375, stop: 0.5 }
    , { note: -5, start: 0.5, stop: 0.625 }
    , { note: -3, start: 0.625, stop: 0.75 }
    , { note: -1, start: 0.75, stop: 0.875 }
    , { note: 0, start: 0.875, stop: 1.0 }
    ]

  log ""
  log "--- MIDI Note Numbers ---"

  testNotePattern "60"
    "MIDI 60 (middle C)"
    1
    [ { note: 60, start: 0.0, stop: 1.0 } ]

  testNotePattern "0 12 24"
    "MIDI octaves"
    3
    [ { note: 0, start: 0.0, stop: 0.333 }
    , { note: 12, start: 0.333, stop: 0.666 }
    , { note: 24, start: 0.666, stop: 1.0 }
    ]

  log ""
  log "--- Note Pattern Modifiers ---"

  testNotePattern "c5*4"
    "C5 repeated 4 times"
    4
    [ { note: 0, start: 0.0, stop: 0.25 }
    , { note: 0, start: 0.25, stop: 0.5 }
    , { note: 0, start: 0.5, stop: 0.75 }
    , { note: 0, start: 0.75, stop: 1.0 }
    ]

  testNotePattern "[c5 e5 g5]*2"
    "C major triad doubled"
    6
    [ { note: 0, start: 0.0, stop: 0.166 }
    , { note: 4, start: 0.166, stop: 0.333 }
    , { note: 7, start: 0.333, stop: 0.5 }
    , { note: 0, start: 0.5, stop: 0.666 }
    , { note: 4, start: 0.666, stop: 0.833 }
    , { note: 7, start: 0.833, stop: 1.0 }
    ]

  log ""
  log "=========================================="
  log "  Chord Tests"
  log "=========================================="
  log ""

  log "--- Basic Triads ---"

  testChord "c'major"
    "C major triad"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 4, start: 0.0, stop: 1.0 }   -- E
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    ]

  testChord "c'minor"
    "C minor triad"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 3, start: 0.0, stop: 1.0 }   -- Eb
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    ]

  testChord "c'dim"
    "C diminished triad"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 3, start: 0.0, stop: 1.0 }   -- Eb
    , { note: 6, start: 0.0, stop: 1.0 }   -- Gb
    ]

  testChord "c'aug"
    "C augmented triad"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 4, start: 0.0, stop: 1.0 }   -- E
    , { note: 8, start: 0.0, stop: 1.0 }   -- G#
    ]

  log ""
  log "--- Seventh Chords ---"

  testChord "c'major7"
    "C major 7th"
    4
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 4, start: 0.0, stop: 1.0 }   -- E
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 11, start: 0.0, stop: 1.0 }  -- B
    ]

  testChord "c'dom7"
    "C dominant 7th"
    4
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 4, start: 0.0, stop: 1.0 }   -- E
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 10, start: 0.0, stop: 1.0 }  -- Bb
    ]

  testChord "c'minor7"
    "C minor 7th"
    4
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 3, start: 0.0, stop: 1.0 }   -- Eb
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 10, start: 0.0, stop: 1.0 }  -- Bb
    ]

  log ""
  log "--- Transposed Chords ---"

  testChord "e'minor"
    "E minor (transposed)"
    3
    [ { note: 4, start: 0.0, stop: 1.0 }   -- E
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 11, start: 0.0, stop: 1.0 }  -- B
    ]

  testChord "g'major"
    "G major (transposed)"
    3
    [ { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 11, start: 0.0, stop: 1.0 }  -- B
    , { note: 14, start: 0.0, stop: 1.0 }  -- D (octave up)
    ]

  testChord "fs'minor"
    "F# minor (with accidental)"
    3
    [ { note: 6, start: 0.0, stop: 1.0 }   -- F#
    , { note: 9, start: 0.0, stop: 1.0 }   -- A
    , { note: 13, start: 0.0, stop: 1.0 }  -- C#
    ]

  testChord "bf'major"
    "Bb major (with flat, octave 5)"
    3
    [ { note: 10, start: 0.0, stop: 1.0 }  -- Bb5 (B=11, flat=-1)
    , { note: 14, start: 0.0, stop: 1.0 }  -- D6
    , { note: 17, start: 0.0, stop: 1.0 }  -- F6
    ]

  log ""
  log "--- Chord Aliases ---"

  testChord "c'M"
    "C major (M alias)"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }
    , { note: 4, start: 0.0, stop: 1.0 }
    , { note: 7, start: 0.0, stop: 1.0 }
    ]

  testChord "c'm"
    "C minor (m alias)"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }
    , { note: 3, start: 0.0, stop: 1.0 }
    , { note: 7, start: 0.0, stop: 1.0 }
    ]

  testChord "c'7"
    "C7 (dominant 7th alias)"
    4
    [ { note: 0, start: 0.0, stop: 1.0 }
    , { note: 4, start: 0.0, stop: 1.0 }
    , { note: 7, start: 0.0, stop: 1.0 }
    , { note: 10, start: 0.0, stop: 1.0 }
    ]

  log ""
  log "--- Suspended Chords ---"

  testChord "c'sus4"
    "C sus4"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 5, start: 0.0, stop: 1.0 }   -- F
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    ]

  testChord "c'sus2"
    "C sus2"
    3
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 2, start: 0.0, stop: 1.0 }   -- D
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    ]

  log ""
  log "=========================================="
  log "  All Tests Complete"
  log "=========================================="

-------------------------------------------------------------------------------
-- Test helpers
-------------------------------------------------------------------------------

type ExpectedEvent =
  { sample :: String
  , start :: Number
  , stop :: Number
  }

type ExpectedNoteEvent =
  { note :: Int
  , start :: Number
  , stop :: Number
  }

-- | Test a Pattern directly (not through parsing)
testPatternDirect
  :: String
  -> Pattern String
  -> Rational
  -> Rational
  -> Int
  -> Array ExpectedEvent
  -> Effect Unit
testPatternDirect desc pat startTime stopTime expectedCount expectedEvents = do
  let events = queryArc pat startTime stopTime
  let actualCount = Array.length events

  -- Check count
  if actualCount /= expectedCount then do
    log $ "  ✗ " <> desc
    log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
    log $ "    Events: " <> formatEvents events
  else do
    -- Check each event
    let mismatches = findMismatches events expectedEvents
    if Array.length mismatches > 0 then do
      log $ "  ✗ " <> desc
      for_ mismatches \m -> log $ "    " <> m
      log $ "    Got: " <> formatEvents events
    else do
      log $ "  ✓ " <> desc <> ": " <> show actualCount <> " events"

-- | Test a pattern produces expected events
testPattern :: String -> String -> Int -> Array ExpectedEvent -> Effect Unit
testPattern input desc expectedCount expectedEvents = do
  let result = parseTPat input :: Either _ (TPat String)
  case result of
    Left err -> do
      log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let pat = tpatToPattern ast
      let events = queryArc pat (fromInt 0) (fromInt 1)
      let actualCount = Array.length events

      -- Check count
      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatEvents events
      else do
        -- Check each event
        let mismatches = findMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatEvents events
        else do
          log $ "  ✓ " <> desc <> " (\"" <> input <> "\"): " <> show actualCount <> " events"

-- | Test a Note pattern produces expected events
testNotePattern :: String -> String -> Int -> Array ExpectedNoteEvent -> Effect Unit
testNotePattern input desc expectedCount expectedEvents = do
  let result = parseTPat input :: Either _ (TPat Note)
  case result of
    Left err -> do
      log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let pat = tpatToPattern ast
      let events = queryArc pat (fromInt 0) (fromInt 1)
      let actualCount = Array.length events

      -- Check count
      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatNoteEvents events
      else do
        -- Check each event
        let mismatches = findNoteMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatNoteEvents events
        else do
          log $ "  ✓ " <> desc <> " (\"" <> input <> "\"): " <> show actualCount <> " events"

-- | Format events for display
formatEvents :: Array (Event String) -> String
formatEvents events =
  "[" <> Array.intercalate ", " (map formatEvent events) <> "]"

formatEvent :: Event String -> String
formatEvent = case _ of
  Digital { value, part: Arc { start, stop } } ->
    value <> "@" <> formatTime start <> "-" <> formatTime stop
  Analog { value, part: Arc { start, stop } } ->
    value <> "~" <> formatTime start <> "-" <> formatTime stop

formatTime :: Rational -> String
formatTime r = show (roundTo3 (toNumber r))

roundTo3 :: Number -> Number
roundTo3 n = Int.toNumber (Int.round (n * 1000.0)) / 1000.0

-- | Find mismatches between actual and expected events
-- | Sorts both by start time before comparing
findMismatches :: Array (Event String) -> Array ExpectedEvent -> Array String
findMismatches actuals expecteds =
  let
    -- Sort actuals by start time
    compareEventStart a b = compare (toNumber (eventStart a)) (toNumber (eventStart b))
    sortedActuals = Array.sortBy compareEventStart actuals
    -- Sort expecteds by start time
    sortedExpecteds = Array.sortBy (\a b -> compare a.start b.start) expecteds

    checkOne idx expected =
      case Array.index sortedActuals idx of
        Nothing -> Just $ "Event " <> show idx <> ": missing"
        Just actual -> checkEvent idx actual expected
  in
    Array.mapWithIndex checkOne sortedExpecteds # Array.catMaybes
  where
    checkEvent :: Int -> Event String -> ExpectedEvent -> Maybe String
    checkEvent idx actual expected =
      let
        actualSample = eventSample actual
        actualStart = toNumber (eventStart actual)
        actualStop = toNumber (eventStop actual)
        tolerance = 0.01
      in
        if actualSample /= expected.sample then
          Just $ "Event " <> show idx <> ": sample " <> actualSample <> " ≠ " <> expected.sample
        else if abs (actualStart - expected.start) > tolerance then
          Just $ "Event " <> show idx <> ": start " <> show actualStart <> " ≠ " <> show expected.start
        else if abs (actualStop - expected.stop) > tolerance then
          Just $ "Event " <> show idx <> ": stop " <> show actualStop <> " ≠ " <> show expected.stop
        else
          Nothing

eventSample :: Event String -> String
eventSample = case _ of
  Digital { value } -> value
  Analog { value } -> value

eventStart :: Event String -> Rational
eventStart = case _ of
  Digital { part: Arc { start } } -> start
  Analog { part: Arc { start } } -> start

eventStop :: Event String -> Rational
eventStop = case _ of
  Digital { part: Arc { stop } } -> stop
  Analog { part: Arc { stop } } -> stop

abs :: Number -> Number
abs n = if n < 0.0 then -n else n

-------------------------------------------------------------------------------
-- Note event helpers
-------------------------------------------------------------------------------

-- | Format Note events for display
formatNoteEvents :: Array (Event Note) -> String
formatNoteEvents events =
  "[" <> Array.intercalate ", " (map formatNoteEvent events) <> "]"

formatNoteEvent :: Event Note -> String
formatNoteEvent = case _ of
  Digital { value, part: Arc { start, stop } } ->
    show (noteValue value) <> "@" <> formatTime start <> "-" <> formatTime stop
  Analog { value, part: Arc { start, stop } } ->
    show (noteValue value) <> "~" <> formatTime start <> "-" <> formatTime stop

-- | Find mismatches between actual and expected Note events
findNoteMismatches :: Array (Event Note) -> Array ExpectedNoteEvent -> Array String
findNoteMismatches actuals expecteds =
  let
    -- Sort actuals by start time
    compareNoteEventStart a b = compare (toNumber (noteEventStart a)) (toNumber (noteEventStart b))
    sortedActuals = Array.sortBy compareNoteEventStart actuals
    -- Sort expecteds by start time
    sortedExpecteds = Array.sortBy (\a b -> compare a.start b.start) expecteds

    checkOne idx expected =
      case Array.index sortedActuals idx of
        Nothing -> Just $ "Event " <> show idx <> ": missing"
        Just actual -> checkNoteEvent idx actual expected
  in
    Array.mapWithIndex checkOne sortedExpecteds # Array.catMaybes
  where
    checkNoteEvent :: Int -> Event Note -> ExpectedNoteEvent -> Maybe String
    checkNoteEvent idx actual expected =
      let
        actualNote = noteValue (noteEventValue actual)
        actualStart = toNumber (noteEventStart actual)
        actualStop = toNumber (noteEventStop actual)
        tolerance = 0.01
      in
        if actualNote /= expected.note then
          Just $ "Event " <> show idx <> ": note " <> show actualNote <> " ≠ " <> show expected.note
        else if abs (actualStart - expected.start) > tolerance then
          Just $ "Event " <> show idx <> ": start " <> show actualStart <> " ≠ " <> show expected.start
        else if abs (actualStop - expected.stop) > tolerance then
          Just $ "Event " <> show idx <> ": stop " <> show actualStop <> " ≠ " <> show expected.stop
        else
          Nothing

noteEventValue :: Event Note -> Note
noteEventValue = case _ of
  Digital { value } -> value
  Analog { value } -> value

noteEventStart :: Event Note -> Rational
noteEventStart = case _ of
  Digital { part: Arc { start } } -> start
  Analog { part: Arc { start } } -> start

noteEventStop :: Event Note -> Rational
noteEventStop = case _ of
  Digital { part: Arc { stop } } -> stop
  Analog { part: Arc { stop } } -> stop

-- | Extract the note number from a Note
noteValue :: Note -> Int
noteValue n = (unwrap n).note

-------------------------------------------------------------------------------
-- Chord test helpers
-------------------------------------------------------------------------------

-- | Test a chord produces expected notes
testChord :: String -> String -> Int -> Array ExpectedNoteEvent -> Effect Unit
testChord input desc expectedCount expectedEvents = do
  let result = parseChord input
  case result of
    Left err -> do
      log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let pat = tpatToPattern ast
      let events = queryArc pat (fromInt 0) (fromInt 1)
      let actualCount = Array.length events

      -- Check count
      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatNoteEvents events
      else do
        -- Check each event (chords produce overlapping events, so don't sort by start)
        let mismatches = findChordMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc <> " (\"" <> input <> "\")"
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatNoteEvents events
        else do
          log $ "  ✓ " <> desc <> " (\"" <> input <> "\"): " <> show actualCount <> " notes"

-- | Find mismatches between actual and expected chord notes
-- | For chords, events all have the same time, so we compare by note value
findChordMismatches :: Array (Event Note) -> Array ExpectedNoteEvent -> Array String
findChordMismatches actuals expecteds =
  let
    -- Sort both by note value for comparison
    sortByNote :: Array (Event Note) -> Array (Event Note)
    sortByNote = Array.sortBy (\a b -> compare (noteValue (noteEventValue a)) (noteValue (noteEventValue b)))

    sortedActuals = sortByNote actuals
    sortedExpecteds = Array.sortBy (\a b -> compare a.note b.note) expecteds

    checkOne idx expected =
      case Array.index sortedActuals idx of
        Nothing -> Just $ "Note " <> show idx <> ": missing"
        Just actual -> checkChordEvent idx actual expected
  in
    Array.mapWithIndex checkOne sortedExpecteds # Array.catMaybes
  where
    checkChordEvent :: Int -> Event Note -> ExpectedNoteEvent -> Maybe String
    checkChordEvent idx actual expected =
      let
        actualNote = noteValue (noteEventValue actual)
        actualStart = toNumber (noteEventStart actual)
        actualStop = toNumber (noteEventStop actual)
        tolerance = 0.01
      in
        if actualNote /= expected.note then
          Just $ "Note " <> show idx <> ": pitch " <> show actualNote <> " ≠ " <> show expected.note
        else if abs (actualStart - expected.start) > tolerance then
          Just $ "Note " <> show idx <> ": start " <> show actualStart <> " ≠ " <> show expected.start
        else if abs (actualStop - expected.stop) > tolerance then
          Just $ "Note " <> show idx <> ": stop " <> show actualStop <> " ≠ " <> show expected.stop
        else
          Nothing
