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
import Tidal.Pattern.Core (cat, compress, cosine, every, fast, fastAppend, fastCat, irand, isaw, iter, iter', queryArc, rand, rev, rotL, rotR, saw, segment, sine, slow, square, stack, tri, zoom)
import Data.Newtype (unwrap)
import Tidal.Pattern.Types (Arc(..), Event(..), Note, Pattern, arcStart, arcStop, mkNote)
import Tidal.Scales as Scales

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
    "tilde rest"
    2
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "sn", start: 0.666, stop: 1.0 }
    ]

  testPattern "bd - sn"
    "dash rest"
    2
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "sn", start: 0.666, stop: 1.0 }
    ]

  testPattern "bd - - sn"
    "multiple dash rests"
    2
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "sn", start: 0.75, stop: 1.0 }
    ]

  testPattern "[bd - sn]"
    "dash in group"
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
  log "--- Dot Grouping ---"

  -- Dot creates equal-time groups: bd sd . hh hh hh = [bd sd] [hh hh hh]
  -- Each group gets 0.5 of the cycle
  testPattern "bd sd . hh hh hh"
    "dot groups equal time"
    5
    [ { sample: "bd", start: 0.0, stop: 0.25 }    -- first half: bd sd
    , { sample: "sd", start: 0.25, stop: 0.5 }
    , { sample: "hh", start: 0.5, stop: 0.666 }   -- second half: hh hh hh
    , { sample: "hh", start: 0.666, stop: 0.833 }
    , { sample: "hh", start: 0.833, stop: 1.0 }
    ]

  -- Three dot groups
  testPattern "bd . sn . hh"
    "three dot groups"
    3
    [ { sample: "bd", start: 0.0, stop: 0.333 }
    , { sample: "sn", start: 0.333, stop: 0.666 }
    , { sample: "hh", start: 0.666, stop: 1.0 }
    ]

  -- Dot with multiple items per group
  testPattern "bd bd . sn sn"
    "two items per dot group"
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 0.75 }
    , { sample: "sn", start: 0.75, stop: 1.0 }
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

  log ""
  log "--- Range Operator (..) ---"

  -- Note ranges - chromatic scale
  testNotePattern "c5 .. e5"
    "chromatic range c5 to e5"
    5
    [ { note: 0, start: 0.0, stop: 0.2 }   -- c5
    , { note: 1, start: 0.2, stop: 0.4 }   -- cs5
    , { note: 2, start: 0.4, stop: 0.6 }   -- d5
    , { note: 3, start: 0.6, stop: 0.8 }   -- ds5
    , { note: 4, start: 0.8, stop: 1.0 }   -- e5
    ]

  -- Descending range
  testNotePattern "e5 .. c5"
    "descending chromatic range"
    5
    [ { note: 4, start: 0.0, stop: 0.2 }   -- e5
    , { note: 3, start: 0.2, stop: 0.4 }   -- ds5
    , { note: 2, start: 0.4, stop: 0.6 }   -- d5
    , { note: 1, start: 0.6, stop: 0.8 }   -- cs5
    , { note: 0, start: 0.8, stop: 1.0 }   -- c5
    ]

  -- Octave range
  testNotePattern "c4 .. c5"
    "full octave range"
    13
    [ { note: -12, start: 0.0, stop: 0.076 }   -- c4
    , { note: -11, start: 0.076, stop: 0.153 }
    , { note: -10, start: 0.153, stop: 0.23 }
    , { note: -9, start: 0.23, stop: 0.307 }
    , { note: -8, start: 0.307, stop: 0.384 }
    , { note: -7, start: 0.384, stop: 0.461 }
    , { note: -6, start: 0.461, stop: 0.538 }
    , { note: -5, start: 0.538, stop: 0.615 }
    , { note: -4, start: 0.615, stop: 0.692 }
    , { note: -3, start: 0.692, stop: 0.769 }
    , { note: -2, start: 0.769, stop: 0.846 }
    , { note: -1, start: 0.846, stop: 0.923 }
    , { note: 0, start: 0.923, stop: 1.0 }     -- c5
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

  -- Important: verify dash-digit is negative, not silence
  testNotePattern "-12 0 12"
    "negative MIDI (dash-digit not silence)"
    3
    [ { note: -12, start: 0.0, stop: 0.333 }
    , { note: 0, start: 0.333, stop: 0.666 }
    , { note: 12, start: 0.666, stop: 1.0 }
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
  log "--- Chord Sequences (Integrated Patterns) ---"

  -- Two chords in sequence: each chord takes half the cycle
  -- c'major (notes 0,4,7) in first half, e'minor (notes 4,7,11) in second half
  testNotePattern "c'major e'minor"
    "Two chord sequence (C maj -> E min)"
    6
    [ { note: 0, start: 0.0, stop: 0.5 }   -- C (chord 1)
    , { note: 4, start: 0.0, stop: 0.5 }   -- E (chord 1)
    , { note: 7, start: 0.0, stop: 0.5 }   -- G (chord 1)
    , { note: 4, start: 0.5, stop: 1.0 }   -- E (chord 2)
    , { note: 7, start: 0.5, stop: 1.0 }   -- G (chord 2)
    , { note: 11, start: 0.5, stop: 1.0 }  -- B (chord 2)
    ]

  -- Four chord sequence (common I-V-vi-IV progression)
  testNotePattern "c'major g'major a'minor f'major"
    "Four chord progression (I-V-vi-IV)"
    12
    [ { note: 0, start: 0.0, stop: 0.25 }   -- C maj
    , { note: 4, start: 0.0, stop: 0.25 }
    , { note: 7, start: 0.0, stop: 0.25 }
    , { note: 7, start: 0.25, stop: 0.5 }   -- G maj
    , { note: 11, start: 0.25, stop: 0.5 }
    , { note: 14, start: 0.25, stop: 0.5 }
    , { note: 9, start: 0.5, stop: 0.75 }   -- A min
    , { note: 12, start: 0.5, stop: 0.75 }
    , { note: 16, start: 0.5, stop: 0.75 }
    , { note: 5, start: 0.75, stop: 1.0 }   -- F maj
    , { note: 9, start: 0.75, stop: 1.0 }
    , { note: 12, start: 0.75, stop: 1.0 }
    ]

  -- Mixed: single notes and chords in same pattern
  testNotePattern "c5 c'major g5"
    "Mixed notes and chords"
    5
    [ { note: 0, start: 0.0, stop: 0.333 }     -- C5 (single note)
    , { note: 0, start: 0.333, stop: 0.666 }   -- C (chord)
    , { note: 4, start: 0.333, stop: 0.666 }   -- E (chord)
    , { note: 7, start: 0.333, stop: 0.666 }   -- G (chord)
    , { note: 7, start: 0.666, stop: 1.0 }     -- G5 (single note)
    ]

  -- Chord with modifier (fast)
  testNotePattern "c'major*2"
    "Chord repeated twice"
    6
    [ { note: 0, start: 0.0, stop: 0.5 }   -- C maj (first)
    , { note: 4, start: 0.0, stop: 0.5 }
    , { note: 7, start: 0.0, stop: 0.5 }
    , { note: 0, start: 0.5, stop: 1.0 }   -- C maj (second)
    , { note: 4, start: 0.5, stop: 1.0 }
    , { note: 7, start: 0.5, stop: 1.0 }
    ]

  -- Chord in a group
  testNotePattern "[c'major e'minor]*2"
    "Chord group repeated"
    12
    [ { note: 0, start: 0.0, stop: 0.25 }
    , { note: 4, start: 0.0, stop: 0.25 }
    , { note: 7, start: 0.0, stop: 0.25 }
    , { note: 4, start: 0.25, stop: 0.5 }
    , { note: 7, start: 0.25, stop: 0.5 }
    , { note: 11, start: 0.25, stop: 0.5 }
    , { note: 0, start: 0.5, stop: 0.75 }
    , { note: 4, start: 0.5, stop: 0.75 }
    , { note: 7, start: 0.5, stop: 0.75 }
    , { note: 4, start: 0.75, stop: 1.0 }
    , { note: 7, start: 0.75, stop: 1.0 }
    , { note: 11, start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- Chord Modifiers ---"

  -- Inversion: move bass note up an octave
  -- C major = [0, 4, 7], inverted = [4, 7, 12]
  testChord "c'major'i"
    "C major first inversion"
    3
    [ { note: 4, start: 0.0, stop: 1.0 }   -- E (was bass)
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 12, start: 0.0, stop: 1.0 }  -- C (moved up)
    ]

  -- Double inversion: ii or i2
  -- C major inverted twice = [7, 12, 16]
  testChord "c'major'ii"
    "C major second inversion (ii)"
    3
    [ { note: 7, start: 0.0, stop: 1.0 }   -- G (was third)
    , { note: 12, start: 0.0, stop: 1.0 }  -- C
    , { note: 16, start: 0.0, stop: 1.0 }  -- E (moved up)
    ]

  testChord "c'major'i2"
    "C major second inversion (i2)"
    3
    [ { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 12, start: 0.0, stop: 1.0 }  -- C
    , { note: 16, start: 0.0, stop: 1.0 }  -- E
    ]

  -- Range: extend chord across octaves
  -- C major = [0, 4, 7], range 5 = [0, 4, 7, 12, 16]
  testChord "c'major'5"
    "C major range 5 (5 notes across octaves)"
    5
    [ { note: 0, start: 0.0, stop: 1.0 }   -- C
    , { note: 4, start: 0.0, stop: 1.0 }   -- E
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 12, start: 0.0, stop: 1.0 }  -- C (octave up)
    , { note: 16, start: 0.0, stop: 1.0 }  -- E (octave up)
    ]

  -- Open voicing: spread notes across octaves
  -- C major = [0, 4, 7], open = [-12, -5, 4]
  testChord "c'major'o"
    "C major open voicing"
    3
    [ { note: -12, start: 0.0, stop: 1.0 }  -- C (octave down)
    , { note: -5, start: 0.0, stop: 1.0 }   -- G (octave down)
    , { note: 4, start: 0.0, stop: 1.0 }    -- E (in place)
    ]

  -- Drop 1: drop the top note down an octave
  -- C major = [0, 4, 7], drop1 = [-5, 0, 4]
  testChord "c'major'd1"
    "C major drop 1 voicing"
    3
    [ { note: -5, start: 0.0, stop: 1.0 }   -- G (dropped)
    , { note: 0, start: 0.0, stop: 1.0 }    -- C
    , { note: 4, start: 0.0, stop: 1.0 }    -- E
    ]

  -- Combined: inversion + range
  testChord "c'major'i'5"
    "C major inverted then range 5"
    5
    [ { note: 4, start: 0.0, stop: 1.0 }   -- E (inverted bass)
    , { note: 7, start: 0.0, stop: 1.0 }   -- G
    , { note: 12, start: 0.0, stop: 1.0 }  -- C
    , { note: 16, start: 0.0, stop: 1.0 }  -- E (octave up)
    , { note: 19, start: 0.0, stop: 1.0 }  -- G (octave up)
    ]

  log ""
  log "=========================================="
  log "  Scale Tests"
  log "=========================================="

  log ""
  log "--- Scale Definitions ---"

  -- Test major scale intervals
  testScaleLookup "major" "Major scale lookup" [0.0, 2.0, 4.0, 5.0, 7.0, 9.0, 11.0]
  testScaleLookup "minor" "Minor scale lookup" [0.0, 2.0, 3.0, 5.0, 7.0, 8.0, 10.0]
  testScaleLookup "dorian" "Dorian mode lookup" [0.0, 2.0, 3.0, 5.0, 7.0, 9.0, 10.0]
  testScaleLookup "minPent" "Minor pentatonic lookup" [0.0, 3.0, 5.0, 7.0, 10.0]
  testScaleLookup "chromatic" "Chromatic scale lookup" [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0]

  log ""
  log "--- Scale Degree Conversion ---"

  -- Test noteInScale function
  testNoteInScale Scales.major 0 0.0 "Major degree 0 = root"
  testNoteInScale Scales.major 2 4.0 "Major degree 2 = major 3rd"
  testNoteInScale Scales.major 4 7.0 "Major degree 4 = perfect 5th"
  testNoteInScale Scales.major 7 12.0 "Major degree 7 = octave (wraps)"
  testNoteInScale Scales.major 14 24.0 "Major degree 14 = 2 octaves (wraps)"
  testNoteInScale Scales.minPent 5 12.0 "MinPent degree 5 = octave (wraps)"

  log ""
  log "=========================================="
  log "  Transformation Tests"
  log "=========================================="

  log ""
  log "--- Segment (Discretize) ---"

  -- segment 4 of "bd sn" should give 4 events: bd, bd, sn, sn
  testPattern "bd sn"
    "Pattern without segment"
    2
    [ { sample: "bd", start: 0.0, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 1.0 }
    ]

  -- Test segment function directly
  testSegment "bd sn"
    "segment 4 of bd sn"
    4
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "bd", start: 0.25, stop: 0.5 }
    , { sample: "sn", start: 0.5, stop: 0.75 }
    , { sample: "sn", start: 0.75, stop: 1.0 }
    ]

  log ""
  log "--- Compress ---"

  -- compress (0, 0.5) of "bd sn" puts both events in first half
  testCompress "bd sn"
    "compress 0-0.5 of bd sn"
    (fromInt 0) (one / fromInt 2)
    2
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "sn", start: 0.25, stop: 0.5 }
    ]

  log ""
  log "--- Zoom ---"

  -- zoom (0.5, 1) of "bd sn" takes only second half (sn) and stretches to full cycle
  testZoom "bd sn"
    "zoom 0.5-1 of bd sn (takes sn only)"
    (one / fromInt 2) one
    1
    [ { sample: "sn", start: 0.0, stop: 1.0 }
    ]

  log ""
  log "--- Every ---"

  -- every 2 rev of "bd sn" - first cycle is reversed
  testEvery "bd sn"
    "every 2 rev cycle 0 (should reverse)"
    2
    (fromInt 0) one
    2
    [ { sample: "sn", start: 0.0, stop: 0.5 }   -- reversed
    , { sample: "bd", start: 0.5, stop: 1.0 }
    ]

  -- every 2 rev cycle 1 should NOT reverse
  testEvery "bd sn"
    "every 2 rev cycle 1 (should not reverse)"
    2
    one (fromInt 2)
    2
    [ { sample: "bd", start: 1.0, stop: 1.5 }   -- not reversed
    , { sample: "sn", start: 1.5, stop: 2.0 }
    ]

  log ""
  log "--- Iter ---"

  -- iter 2 of "bd sn hh cp": cycle 0 starts at 0, cycle 1 starts at 0.5 (rotated)
  -- Cycle 0: bd sn hh cp (no rotation)
  testIter "bd sn hh cp"
    "iter 2 cycle 0 (no rotation)"
    2
    (fromInt 0) one
    4
    [ { sample: "bd", start: 0.0, stop: 0.25 }
    , { sample: "sn", start: 0.25, stop: 0.5 }
    , { sample: "hh", start: 0.5, stop: 0.75 }
    , { sample: "cp", start: 0.75, stop: 1.0 }
    ]

  -- iter 2 cycle 1: rotated by 1/2 so starts with hh cp bd sn
  testIter "bd sn hh cp"
    "iter 2 cycle 1 (rotated by 1/2)"
    2
    one (fromInt 2)
    4
    [ { sample: "hh", start: 1.0, stop: 1.25 }
    , { sample: "cp", start: 1.25, stop: 1.5 }
    , { sample: "bd", start: 1.5, stop: 1.75 }
    , { sample: "sn", start: 1.75, stop: 2.0 }
    ]

  log ""
  log "--- Oscillators ---"

  -- sine at cycle position 0 = 0.5, at 0.25 = 1.0, at 0.5 = 0.5, at 0.75 = 0.0
  -- Note: tolerance is higher because we sample the midpoint of query arc
  testOscillator sine "sine at t=0" 0.0 0.01 0.5 0.05
  testOscillator sine "sine at t=0.25" 0.25 0.26 1.0 0.05
  testOscillator sine "sine at t=0.5" 0.5 0.51 0.5 0.05
  testOscillator sine "sine at t=0.75" 0.75 0.76 0.0 0.05

  testOscillator saw "saw at t=0" 0.0 0.01 0.0 0.01
  testOscillator saw "saw at t=0.5" 0.5 0.51 0.5 0.01
  testOscillator saw "saw at t=0.99" 0.99 1.0 0.99 0.02

  testOscillator tri "tri at t=0" 0.0 0.01 0.0 0.02
  testOscillator tri "tri at t=0.25" 0.25 0.26 0.5 0.02
  testOscillator tri "tri at t=0.5" 0.5 0.51 1.0 0.02
  testOscillator tri "tri at t=0.75" 0.75 0.76 0.5 0.02

  testOscillator square "square at t=0.25" 0.25 0.26 0.0 0.01
  testOscillator square "square at t=0.75" 0.75 0.76 1.0 0.01

  -- rand produces values 0-1
  testOscillatorRange rand "rand produces 0-1 values" 0.0 1.0 0.0 1.0

  -- irand produces integers
  testIrandRange 4 "irand 4 produces 0-3" 0.0 1.0 0 3

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

-------------------------------------------------------------------------------
-- Scale test helpers
-------------------------------------------------------------------------------

-- | Test scale lookup returns expected intervals
testScaleLookup :: String -> String -> Array Number -> Effect Unit
testScaleLookup scaleName desc expected = do
  case Scales.lookupScale scaleName of
    Nothing -> log $ "  ✗ " <> desc <> ": scale not found"
    Just actual ->
      if actual == expected then
        log $ "  ✓ " <> desc
      else
        log $ "  ✗ " <> desc <> ": expected " <> show expected <> ", got " <> show actual

-- | Test noteInScale returns expected semitone offset
testNoteInScale :: Array Number -> Int -> Number -> String -> Effect Unit
testNoteInScale scale degree expected desc = do
  let actual = Scales.noteInScale scale degree
  let tolerance = 0.001
  if abs (actual - expected) < tolerance then
    log $ "  ✓ " <> desc
  else
    log $ "  ✗ " <> desc <> ": expected " <> show expected <> ", got " <> show actual

-------------------------------------------------------------------------------
-- Transformation test helpers
-------------------------------------------------------------------------------

-- | Test segment function
testSegment :: String -> String -> Int -> Int -> Array ExpectedEvent -> Effect Unit
testSegment input desc n expectedCount expectedEvents = do
  let result = parseTPat input
  case result of
    Left err -> log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let basePat = tpatToPattern ast
      let pat = segment n basePat
      let events = queryArc pat (fromInt 0) (fromInt 1)
      let actualCount = Array.length events

      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatEvents events
      else do
        let mismatches = findMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatEvents events
        else
          log $ "  ✓ " <> desc

-- | Test compress function
testCompress :: String -> String -> Rational -> Rational -> Int -> Array ExpectedEvent -> Effect Unit
testCompress input desc s e expectedCount expectedEvents = do
  let result = parseTPat input
  case result of
    Left err -> log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let basePat = tpatToPattern ast
      let pat = compress s e basePat
      let events = queryArc pat (fromInt 0) (fromInt 1)
      let actualCount = Array.length events

      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatEvents events
      else do
        let mismatches = findMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatEvents events
        else
          log $ "  ✓ " <> desc

-- | Test zoom function
testZoom :: String -> String -> Rational -> Rational -> Int -> Array ExpectedEvent -> Effect Unit
testZoom input desc s e expectedCount expectedEvents = do
  let result = parseTPat input
  case result of
    Left err -> log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let basePat = tpatToPattern ast
      let pat = zoom s e basePat
      let events = queryArc pat (fromInt 0) (fromInt 1)
      let actualCount = Array.length events

      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatEvents events
      else do
        let mismatches = findMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatEvents events
        else
          log $ "  ✓ " <> desc

-- | Test every function
testEvery :: String -> String -> Int -> Rational -> Rational -> Int -> Array ExpectedEvent -> Effect Unit
testEvery input desc n startTime stopTime expectedCount expectedEvents = do
  let result = parseTPat input
  case result of
    Left err -> log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let basePat = tpatToPattern ast
      let pat = every n rev basePat
      let events = queryArc pat startTime stopTime
      let actualCount = Array.length events

      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatEvents events
      else do
        let mismatches = findMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatEvents events
        else
          log $ "  ✓ " <> desc

-- | Test iter function
testIter :: String -> String -> Int -> Rational -> Rational -> Int -> Array ExpectedEvent -> Effect Unit
testIter input desc n startTime stopTime expectedCount expectedEvents = do
  let result = parseTPat input
  case result of
    Left err -> log $ "  ✗ " <> desc <> ": parse error - " <> show err
    Right ast -> do
      let basePat = tpatToPattern ast
      let pat = iter n basePat
      let events = queryArc pat startTime stopTime
      let actualCount = Array.length events

      if actualCount /= expectedCount then do
        log $ "  ✗ " <> desc
        log $ "    Expected " <> show expectedCount <> " events, got " <> show actualCount
        log $ "    Events: " <> formatEvents events
      else do
        let mismatches = findMismatches events expectedEvents
        if Array.length mismatches > 0 then do
          log $ "  ✗ " <> desc
          for_ mismatches \m -> log $ "    " <> m
          log $ "    Got: " <> formatEvents events
        else
          log $ "  ✓ " <> desc

-- | Test oscillator value at a specific time
testOscillator :: Pattern Number -> String -> Number -> Number -> Number -> Number -> Effect Unit
testOscillator pat desc startN stopN expectedValue tolerance = do
  let start = toRational startN
  let stop = toRational stopN
  let events = queryArc pat start stop
  case Array.head events of
    Nothing -> log $ "  ✗ " <> desc <> ": no events"
    Just event ->
      let value = getEventValue event
          diff = if value > expectedValue then value - expectedValue else expectedValue - value
      in if diff <= tolerance then
           log $ "  ✓ " <> desc
         else do
           log $ "  ✗ " <> desc
           log $ "    Expected ~" <> show expectedValue <> ", got " <> show value
  where
    toRational :: Number -> Rational
    toRational n = fromInt (Int.round (n * 1000.0)) / fromInt 1000

    getEventValue :: Event Number -> Number
    getEventValue (Digital e) = e.value
    getEventValue (Analog e) = e.value

-- | Test oscillator produces values in a range
testOscillatorRange :: Pattern Number -> String -> Number -> Number -> Number -> Number -> Effect Unit
testOscillatorRange pat desc startN stopN minVal maxVal = do
  let start = toRational startN
  let stop = toRational stopN
  let events = queryArc pat start stop
  let values = map getEventValue events
  let allInRange = Array.all (\v -> v >= minVal && v <= maxVal) values
  if allInRange then
    log $ "  ✓ " <> desc
  else do
    log $ "  ✗ " <> desc
    log $ "    Values out of range [" <> show minVal <> ", " <> show maxVal <> "]"
  where
    toRational n = fromInt (Int.round (n * 1000.0)) / fromInt 1000
    getEventValue (Digital e) = e.value
    getEventValue (Analog e) = e.value

-- | Test irand produces integers in range
testIrandRange :: Int -> String -> Number -> Number -> Int -> Int -> Effect Unit
testIrandRange n desc startN stopN minVal maxVal = do
  let pat = irand n
  let start = toRational startN
  let stop = toRational stopN
  let events = queryArc pat start stop
  let values = map getEventValue events
  let allInRange = Array.all (\v -> v >= minVal && v <= maxVal) values
  if allInRange then
    log $ "  ✓ " <> desc
  else do
    log $ "  ✗ " <> desc
    log $ "    Values out of range [" <> show minVal <> ", " <> show maxVal <> "]"
  where
    toRational n' = fromInt (Int.round (n' * 1000.0)) / fromInt 1000
    getEventValue :: Event Int -> Int
    getEventValue (Digital e) = e.value
    getEventValue (Analog e) = e.value
