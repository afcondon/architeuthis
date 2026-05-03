-- | Harder cells for `Tidal.Pattern.Branched`. These exist to find the
-- | design's limits — the cases that *don't* read fluently expose what
-- | the surface still needs.
-- |
-- | Each case is annotated with a verdict: ✓ works fluently, ~ works
-- | with workaround, ✗ not expressible without a new primitive.
module Tidal.Pattern.BranchedHardCases where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Rational (fromInt)
import Data.Tuple (Tuple(..))
import Tidal.Pattern.Branched
  ( Branched
  , Voice(..)
  , alternate
  , crossfade
  , fanOut
  , gate
  , merge
  , mult
  )
import Tidal.Pattern.Core (cat, every, fast, fastCat, rev, slow, stack, whenMod)
import Tidal.Pattern.Types (Pattern)

-- Stub source patterns. Real cells would parse mini-notation.
melody :: Pattern String
melody = fastCat (map pure [ "c4", "e4", "g4", "b4" ])

ostinato :: Pattern String
ostinato = fastCat (map pure [ "c2", "c2", "g2", "c2" ])

drums :: Pattern String
drums = fastCat (map pure [ "bd", "sn", "hh", "sn" ])

ensemble :: Branched String
ensemble = fanOut
  [ Tuple (Voice "lead") identity
  , Tuple (Voice "pad")  (slow (fromInt 2))
  , Tuple (Voice "bass") identity
  ]
  melody

-------------------------------------------------------------------------------
-- A.  Section-scale arrangement: 16 bars verse + 16 bars chorus + 8 bars bridge
-------------------------------------------------------------------------------
-- VERDICT: ~ works, but reveals two missing primitives.
--
-- Naively you'd want:  arrange [(16, verse), (16, chorus), (8, bridge)]
-- That requires `timeCat :: Array (Tuple Time (Pattern a)) -> Pattern a`,
-- which doesn't exist in Pattern.Core. Available is `cat` (equal-time
-- concatenation, one cycle each) and `slow`.
--
-- Workaround #1: replicate-then-cat for equal-weight sections — clunky.
-- Each pattern in the array gets one cycle in the arrangement; `slow`
-- of the whole thing scales the arrangement back to the desired total.

verseSection :: Pattern String
verseSection = merge ensemble

chorusSection :: Pattern String
chorusSection = gate
  (Map.fromFoldable
     [ Tuple (Voice "lead") (pure true)
     , Tuple (Voice "pad")  (pure false)
     , Tuple (Voice "bass") (pure true)
     ])
  ensemble

bridgeSection :: Pattern String
bridgeSection = alternate ensemble

-- 16+16+8 = 40 cycles total, but `cat` gives equal weights. The
-- workaround is replication: 16 copies of verse, 16 of chorus, 8 of
-- bridge, then `slow 40` so the whole arrangement maps to one parent
-- cycle. Reads as a balance sheet, not a score.
example_arrangement_clunky :: Pattern String
example_arrangement_clunky =
  slow (fromInt 40)
    (cat
      (   Array.replicate 16 verseSection
       <> Array.replicate 16 chorusSection
       <> Array.replicate  8 bridgeSection))

-- Want: example_arrangement = arrange [(16, verseSection), ...]
-- Gap to surface: `arrange` / `timeCat` primitive.

-------------------------------------------------------------------------------
-- B.  Call and response — voice B answers voice A with one-cycle delay
-------------------------------------------------------------------------------
-- VERDICT: ✗ not expressible inside Branched. Branches are siblings; no
-- branch can read another's events. The natural form is to construct A
-- once at the Pattern layer and use it twice as siblings:

callA :: Pattern String
callA = melody

response :: Pattern String -> Pattern String
response = slow (fromInt 2) <<< rev   -- placeholder transform

example_call_response :: Pattern String
example_call_response = mult
  [ Tuple (Voice "call")     identity
  , Tuple (Voice "response") response
  ]
  callA

-- This works at the *pattern* level (response is `f callA`), but the
-- relationship "response *answers* call" isn't visible to the renderer
-- — both are top-level branches of one fan-out. A Sankey would draw two
-- parallel arrows from `callA`, not an arrow from call → response.
--
-- Gap to surface: an inter-voice-edge construct. Would need `Tree
-- Voice (Pattern a)` with edges labelled by transforms — exactly the
-- nesting we deferred. Calling this out as the natural motivation for
-- nested Branched: when one branch's pattern depends on another's
-- *identity* (not just its events), flat fan-out doesn't capture it.

-------------------------------------------------------------------------------
-- C.  Voice-conditional behaviour — "if pad is active, double the lead"
-------------------------------------------------------------------------------
-- VERDICT: ✗ not expressible. No primitive lets one branch query another
-- branch's events. By design — branches are stateless and independent
-- (decision #4). The use-case suggests a *signal* layer: voices emit
-- side-channel signals that other voices subscribe to. That's strictly
-- more than fork/merge; it's full graph topology with feedback edges.
--
-- Workaround: hoist the condition out to a shared Pattern Boolean that
-- both gates feed off. This works for static or schedule-driven
-- conditions but not for "X reacts to events of Y."

leadActive :: Pattern Boolean
leadActive = pure true   -- a real condition would be cycle-aware

example_static_condition :: Pattern String
example_static_condition = gate
  (Map.fromFoldable [ Tuple (Voice "lead") leadActive ])
  ensemble

-- Note this is just `gate` — it doesn't *react* to anything.

-------------------------------------------------------------------------------
-- D.  Nested fan-out — voice "lead" itself splits into harmonies
-------------------------------------------------------------------------------
-- VERDICT: ✓ works fluently, *because* `merge` collapses the inner
-- Branched back to a Pattern. The inner topology is invisible to the
-- outer — the renderer only sees one "lead" branch, not two harmonies
-- inside it.

leadHarmonies :: Pattern String
leadHarmonies = merge
  (fanOut
    [ Tuple (Voice "lead-soprano") identity
    , Tuple (Voice "lead-alto")    (slow (fromInt 2))
    ]
    melody)

-- Outer fan-out routes "lead" to a destination; the destination receives
-- a stacked pattern but doesn't know it came from an inner fan-out.
example_nested :: Pattern String
example_nested = mult
  [ Tuple (Voice "lead") (\_ -> leadHarmonies)
  , Tuple (Voice "bass") identity
  ]
  ostinato

-- Gap to surface: nesting compiles down but the topology is *erased*
-- by the inner `merge`. A future `Tree`-based Branched would preserve
-- it and let the renderer draw harmonies as sub-branches of "lead."

-------------------------------------------------------------------------------
-- E.  Reusing one fan-out under two unrelated downstream uses
-------------------------------------------------------------------------------
-- VERDICT: ✓ works fluently. `Branched` is a value, sharable. Two
-- merges of the same fan-out give two independent patterns.

example_two_uses :: { audible :: Pattern String, recordable :: Pattern String }
example_two_uses =
  let
    e = ensemble
    audibleMix = gate
      (Map.fromFoldable [ Tuple (Voice "pad") (pure false) ])
      e
    recordableMix = merge e
  in { audible: audibleMix, recordable: recordableMix }

-- Both patterns share the same underlying Branched value. Downstream
-- can do whatever it wants. This is one of the things you couldn't
-- do if `mult` had no inspectable middle representation.

-------------------------------------------------------------------------------
-- F.  Time-varying voice mute (chorus only on cycles 4–7)
-------------------------------------------------------------------------------
-- VERDICT: ✓ works, *but* relies on a cycle-aware Pattern Boolean.
-- Right now we have `whenMod` and `every` for cycle-conditioned
-- structure but no obvious "active for cycles m..n" primitive. The
-- gate map can take any Pattern Boolean, so the question is whether
-- the Boolean pattern is easy to build.

chorusActiveCycles :: Pattern Boolean
chorusActiveCycles =
  whenMod 8 (\c -> c >= 4) (\_ -> pure true) (pure false)
-- whenMod n pred f p = on cycles where pred (cycle `mod` n), apply f to p.
-- Reads correctly but fragile — building the predicate every time and
-- threading both true and false sides is more ceremony than the
-- musical idea ("active for cycles 4..7 of 8") deserves.

example_temporal_gate :: Pattern String
example_temporal_gate = gate
  (Map.fromFoldable
     [ Tuple (Voice "pad") chorusActiveCycles ])
  ensemble

-- Gap to surface: a clearer "during cycles a..b" primitive. Useful far
-- beyond Branched.

-------------------------------------------------------------------------------
-- Summary of gaps surfaced (for the worklog)
-- =============================================================================
-- 1. `arrange` / `timeCat` for weighted section-scale concatenation
--    (Case A). High value: section structure is *the* gap I called out
--    in question 4.
-- 2. Inter-voice references (Case B). Argues for `Tree Voice` nesting
--    sooner rather than later, with edges meaning "B derives from A."
-- 3. Voice-conditional behaviour (Case C). Likely a separate primitive
--    class above fork/merge — graph with feedback. Park.
-- 4. "During cycles a..b" Boolean-pattern primitive (Case F). Cheap,
--    high-utility. Probably belongs in Pattern.Core, not Branched.
-------------------------------------------------------------------------------
