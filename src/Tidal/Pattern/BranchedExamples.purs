-- | Illustrative cells for `Tidal.Pattern.Branched`.
-- |
-- | These exist to validate the surface ergonomically — *if the cells feel
-- | right, the design is right*. They compile but aren't run by the test
-- | suite (no event-count assertions). They're the design artefact.
-- |
-- | Each example uses the canonical Branched primitives directly. The
-- | mini-notation parser doesn't yet know about Branched; that's Layer-2
-- | wiring, deferred per question 5.
module Tidal.Pattern.BranchedExamples where

import Prelude

import Data.Map as Map
import Data.Rational (fromInt)
import Tidal.Pattern.Branched
  ( Branched
  , Voice(..)
  , alternate
  , crossfade
  , fanOut
  , gate
  , jux
  , merge
  , mult
  , voiced
  )
import Tidal.Pattern.Core (every, fast, fastCat, rev, slow, stack)
import Tidal.Pattern.Types (Pattern, pattern, query, silence)

-- A few placeholder note patterns. In a real cell these would come from
-- the mini-notation parser; here they're stubs whose shape is what the
-- examples care about, not the contents.

melody :: Pattern String
melody = fastCat (map pure [ "c4", "e4", "g4", "b4" ])

ostinato :: Pattern String
ostinato = fastCat (map pure [ "c2", "c2", "g2", "c2" ])

drums :: Pattern String
drums = fastCat (map pure [ "bd", "sn", "hh", "sn" ])

-------------------------------------------------------------------------------
-- 1. Plain stereo jux: classic Tidal idiom.
--    `jux rev` routes the original to L, the reverse to R.
-------------------------------------------------------------------------------

example_jux :: Pattern String
example_jux = jux rev melody

-------------------------------------------------------------------------------
-- 2. Three-way fan-out à la Fugue Machine: original, half-speed, double-speed.
--    `mult` collapses back to one stream; the binding layer can route each
--    Voice to a different destination.
-------------------------------------------------------------------------------

example_fugue3 :: Pattern String
example_fugue3 = mult
  [ voiced "head1" identity
  , voiced "head2" (slow (fromInt 2))
  , voiced "head3" (fast (fromInt 2))
  ]
  melody

-------------------------------------------------------------------------------
-- 3. Verse/chorus structure via per-section merges.
--    Same fan-out (lead, pad, bass) — the *merge* changes per section.
--    Verse: everyone plays. Chorus: only the lead is gated.
-------------------------------------------------------------------------------

ensemble :: Branched String
ensemble = fanOut
  [ voiced "lead" identity
  , voiced "pad"  (slow (fromInt 2))
  , voiced "bass" identity
  ]
  melody  -- placeholder — in a piece each branch would fork from its own source

example_verse :: Pattern String
example_verse = merge ensemble

example_chorus :: Pattern String
example_chorus = gate
  (Map.fromFoldable
     [ voiced "lead" (pure true)
     , voiced "pad"  (pure false)
     , voiced "bass" (pure false)
     ])
  ensemble

-------------------------------------------------------------------------------
-- 4. Crossfade: a Pattern Voice picks who's audible.
--    Bridge section: alternate one cycle of lead, one cycle of pad, etc.
--    (The same effect could be written with `alternate`; this version
--    parameterises the schedule explicitly.)
-------------------------------------------------------------------------------

bridgeSchedule :: Pattern Voice
bridgeSchedule = fastCat
  [ pure (Voice "lead")
  , pure (Voice "pad")
  , pure (Voice "lead")
  , pure (Voice "bass")
  ]

example_bridge :: Pattern String
example_bridge = crossfade bridgeSchedule ensemble

-------------------------------------------------------------------------------
-- 5. `alternate`: round-robin per cycle, declared order.
--    Drum solo trade-offs: kit A in cycle 0, kit B in cycle 1, kit C in
--    cycle 2, repeat. Useful for trades between voices in a single bus.
-------------------------------------------------------------------------------

example_trade :: Pattern String
example_trade = alternate
  (fanOut
    [ voiced "kit-a" identity
    , voiced "kit-b" (every 2 rev)
    , voiced "kit-c" (fast (fromInt 2))
    ]
    drums)

-------------------------------------------------------------------------------
-- 6. Fan-out without merge: leaving the Branched un-collapsed lets the
--    routing layer dispatch each voice to its own destination, no mixdown.
--    Conceptually this is what `mult` returns *before* the merge.
-------------------------------------------------------------------------------

example_unmerged :: Branched String
example_unmerged = fanOut
  [ voiced "plaits" identity
  , voiced "rample" (slow (fromInt 2))
  ]
  melody
