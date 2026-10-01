-- | Guided tour through `Tidal.Pattern.Branched`.
-- |
-- | This file is meant to be **read alongside `make tour` output**. Each
-- | section has:
-- |
-- |   1. A musical-idea comment describing what the cell is for
-- |   2. A small expression building a `Branched` (or merge thereof)
-- |   3. A one-cycle query
-- |   4. Pretty-printed events you can read like a tiny score
-- |
-- | Edit a cell, run `make tour`, observe. When something surprises you,
-- | that's the cell to dig into. The reference for the underlying API
-- | is `src/Tidal/Pattern/Branched.purs`; further examples live in
-- | `src/Tidal/Pattern/BranchedExamples.purs` and
-- | `src/Tidal/Pattern/BranchedHardCases.purs`.
module Test.BranchedTour where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Haskell.Rational (Rational, denominator, fromInt, numerator)
import Data.String.CodeUnits as String
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Pattern.Branched
  ( Branched(..)
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
import Tidal.Pattern.Core (every, fast, fastCat, queryArc, rev, slow, stack)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern, eventPart, eventValue)

-- A small reusable melody. Four notes per cycle.
m4 :: Pattern String
m4 = fastCat (map pure [ "c4", "e4", "g4", "b4" ])

-- A simpler 2-note pattern.
m2 :: Pattern String
m2 = fastCat (map pure [ "c4", "g4" ])

-- A drum-ish pattern.
dm :: Pattern String
dm = fastCat (map pure [ "bd", "sn", "hh", "sn" ])

-------------------------------------------------------------------------------
-- Pretty printing
-------------------------------------------------------------------------------

-- | Show a Rational as `n/d`, or just `n` if denominator is 1.
showRat :: Rational -> String
showRat r =
  let n = numerator r
      d = denominator r
  in if d == one then show n else show n <> "/" <> show d

-- | Pad a string on the left to a given width.
padLeft :: Int -> String -> String
padLeft w s =
  let need = w - String.length s
  in if need > 0 then replicate' need ' ' <> s else s

-- | Print events sorted by start time, one per line, in a score-like form.
showScore :: String -> Array (Event String) -> Effect Unit
showScore label events = do
  log $ "  " <> label <> " — " <> show (Array.length events) <> " events:"
  let sorted = Array.sortBy (\a b -> compare (start' a) (start' b)) events
  if Array.null sorted
    then log "    (silence)"
    else for_ sorted \ev -> log $ "    " <> formatRow ev
  log ""
  where
    start' :: Event String -> Rational
    start' ev = case eventPart ev of Arc { start } -> start

    formatRow :: Event String -> String
    formatRow ev =
      let
        Arc { start, stop } = eventPart ev
        s = padLeft 5 (showRat start)
        e = padLeft 5 (showRat stop)
      in s <> " → " <> e <> "   " <> eventValue ev

-- | Per-voice view: query each voice's pattern individually, print as a
-- | mini-score per voice. Useful for seeing what each branch contributes
-- | before any merge collapses it.
showBranched :: String -> Branched String -> Effect Unit
showBranched label (Branched bs) = do
  log $ "  " <> label <> " (per-voice view):"
  if Array.null bs
    then log "    (no voices)"
    else for_ bs \(Tuple (Voice v) p) -> do
      let evs = queryArc p (fromInt 0) (fromInt 1)
      log $ "    voice \"" <> v <> "\" — " <> show (Array.length evs) <> " events:"
      let sorted = Array.sortBy (\a b -> compare (start' a) (start' b)) evs
      for_ sorted \ev ->
        log $ "      " <> padLeft 5 (showRat (start' ev)) <> "   " <> eventValue ev
  log ""
  where
    start' :: Event String -> Rational
    start' ev = case eventPart ev of Arc { start } -> start

-- Helpers (ports from Foldable / String we need that aren't in Prelude).

for_ :: forall a. Array a -> (a -> Effect Unit) -> Effect Unit
for_ arr f = case Array.uncons arr of
  Nothing -> pure unit
  Just { head, tail } -> do
    f head
    for_ tail f

replicate' :: Int -> Char -> String
replicate' n c =
  if n <= 0 then ""
  else String.singleton c <> replicate' (n - 1) c

-------------------------------------------------------------------------------
-- Tour
-------------------------------------------------------------------------------

runTour :: Effect Unit
runTour = do
  log ""
  log "=========================================="
  log "  Branched — Guided Tour"
  log "=========================================="
  log ""

  section1
  section2
  section3
  section4
  section5
  section6
  section7
  section8

  log "End of tour. Edit Test/BranchedTour.purs to vary cells, run `make tour`."
  log ""

-- ---------------------------------------------------------------------------
-- Section 1 — fanOut + merge: the basic split-and-rejoin
-- ---------------------------------------------------------------------------
-- `fanOut` builds a labeled split: the same pattern, transformed per Voice.
-- `merge` collapses the split into a single Pattern by stacking all branches.
-- This is upstream Tidal's `stack` of one-pattern-per-branch — but with the
-- Voice labels visible to the renderer / binding layer.
section1 :: Effect Unit
section1 = do
  log "── Section 1 — fanOut + merge ─────────────────────────────────────────"
  log "Musical idea: play melody twice — once as-is, once reversed —"
  log "stacked. Same shape as `stack [m4, rev m4]` but with Voice labels."
  log ""

  let split = fanOut
        [ voiced "L" identity
        , voiced "R" rev
        ] m4

  showBranched "split" split

  let merged = merge split
  showScore "merge split" (queryArc merged (fromInt 0) (fromInt 1))

-- ---------------------------------------------------------------------------
-- Section 2 — jux: classic stereo split
-- ---------------------------------------------------------------------------
-- `jux f p` is sugar for `mult [voiced "L" identity, voiced "R" f] p`.
-- It's the most familiar live-coding form. The L/R Voice labels exist so
-- the binding layer can route each side to a different MIDI channel /
-- destination — but on its own jux is "stack with one side transformed."
section2 :: Effect Unit
section2 = do
  log "── Section 2 — jux ────────────────────────────────────────────────────"
  log "Musical idea: melody on the left, reversed melody on the right."
  log ""

  showScore "jux rev m4" (queryArc (jux rev m4) (fromInt 0) (fromInt 1))

  log "Try varying the transform: `jux (slow (fromInt 2)) m4`,"
  log "`jux (fast (fromInt 2)) m4`, `jux (every 2 rev) m4`."
  log ""

-- ---------------------------------------------------------------------------
-- Section 3 — mult: n-way fan-out (Fugue Machine)
-- ---------------------------------------------------------------------------
-- `mult` is the general primitive: any number of branches with arbitrary
-- transforms. `jux` is the 2-branch case. Three- or four-way mult expresses
-- the iPad "Fugue Machine" idiom: the same melody played at multiple speeds
-- simultaneously, each routed to its own destination.
section3 :: Effect Unit
section3 = do
  log "── Section 3 — mult (Fugue Machine vocabulary) ────────────────────────"
  log "Musical idea: same melody at three speeds at once — half, one, double."
  log ""

  let fugue3 = mult
        [ voiced "head1" identity
        , voiced "head2" (slow (fromInt 2))
        , voiced "head3" (fast (fromInt 2))
        ]
        m4

  showScore "fugue3" (queryArc fugue3 (fromInt 0) (fromInt 1))

  log "Notice: head2 (slow 2) only emits half its events in cycle 0;"
  log "head3 (fast 2) emits two complete passes."
  log ""

-- ---------------------------------------------------------------------------
-- Section 4 — gate: per-voice mute
-- ---------------------------------------------------------------------------
-- `gate` takes a `Map Voice (Pattern Boolean)` and masks each branch by
-- its corresponding gate. Missing keys are treated as OPEN (decision #3) —
-- adding a voice to a fan-out can't accidentally mute it via a stale gate
-- cell. There is no mini-notation equivalent for this — branch-conditional
-- muting is one of the things Branched lets you express that you can't
-- write inside a `bd, sn, hh` stack.
section4 :: Effect Unit
section4 = do
  log "── Section 4 — gate ───────────────────────────────────────────────────"
  log "Musical idea: a 3-voice ensemble (lead, pad, bass), but mute the pad."
  log ""

  let ensemble = fanOut
        [ voiced "lead" identity
        , voiced "pad"  (slow (fromInt 2))
        , voiced "bass" identity
        ]
        m4

  showBranched "ensemble" ensemble

  let muted = gate
        (Map.fromFoldable
           [ voiced "lead" (pure true)
           , voiced "pad"  (pure false)   -- silence the pad
           , voiced "bass" (pure true)
           ])
        ensemble

  showScore "merge muted-pad" (queryArc muted (fromInt 0) (fromInt 1))

  log "The pad's events are gone. Try removing the `pad` entry from the"
  log "gate map — it should pass through unchanged (open default)."
  log ""

-- ---------------------------------------------------------------------------
-- Section 5 — crossfade: schedule-driven voice select
-- ---------------------------------------------------------------------------
-- `crossfade :: Pattern Voice -> Branched a -> Pattern a` lets a separate
-- pattern decide WHICH branch is audible at each moment. Like `gate`, no
-- mini-notation equivalent — schedule-driven voice selection is unique to
-- Branched.
section5 :: Effect Unit
section5 = do
  log "── Section 5 — crossfade ──────────────────────────────────────────────"
  log "Musical idea: 4 quarter-cycle slots, each picks a voice to play."
  log "Slots: lead, pad, lead, bass — the 'bridge' from BranchedExamples."
  log ""

  let ensemble = fanOut
        [ voiced "lead" identity
        , voiced "pad"  (slow (fromInt 2))
        , voiced "bass" identity
        ]
        m4

  let schedule = fastCat
        [ pure (Voice "lead")
        , pure (Voice "pad")
        , pure (Voice "lead")
        , pure (Voice "bass")
        ]

  showScore "crossfade schedule ensemble"
    (queryArc (crossfade schedule ensemble) (fromInt 0) (fromInt 1))

  log "Each voice contributes only during its slot. Compare to merge:"
  log ""

  showScore "merge ensemble (full mix)"
    (queryArc (merge ensemble) (fromInt 0) (fromInt 1))

-- ---------------------------------------------------------------------------
-- Section 6 — alternate: round-robin per cycle
-- ---------------------------------------------------------------------------
-- `alternate` plays voice 0 in cycle 0, voice 1 in cycle 1, etc., cycling.
-- This matches upstream Tidal `<a b c>` mini-notation. Per-cycle granularity
-- is the only one currently supported (decision #4).
section6 :: Effect Unit
section6 = do
  log "── Section 6 — alternate ──────────────────────────────────────────────"
  log "Musical idea: drum kit trades — kit-a in cycle 0, kit-b reversed in"
  log "cycle 1, kit-c at double speed in cycle 2, repeat."
  log ""

  let trade = alternate
        (fanOut
          [ voiced "kit-a" identity
          , voiced "kit-b" rev
          , voiced "kit-c" (fast (fromInt 2))
          ]
          dm)

  showScore "trade — cycle 0" (queryArc trade (fromInt 0) (fromInt 1))
  showScore "trade — cycle 1" (queryArc trade (fromInt 1) (fromInt 2))
  showScore "trade — cycle 2" (queryArc trade (fromInt 2) (fromInt 3))
  showScore "trade — cycle 3 (back to kit-a)"
    (queryArc trade (fromInt 3) (fromInt 4))

-- ---------------------------------------------------------------------------
-- Section 7 — same fan-out, three different merges per section
-- ---------------------------------------------------------------------------
-- The big payoff of separating fork from merge: a piece can have ONE
-- ensemble and apply DIFFERENT merges per section. Verse, chorus, bridge
-- have the same voices; the rule for combining them changes.
section7 :: Effect Unit
section7 = do
  log "── Section 7 — verse / chorus / bridge with one ensemble ──────────────"
  log "Musical idea: same 3-voice ensemble. Verse mixes everyone; chorus"
  log "gates pad off; bridge crossfades lead → bass."
  log ""

  let ensemble = fanOut
        [ voiced "lead" identity
        , voiced "pad"  (slow (fromInt 2))
        , voiced "bass" identity
        ]
        m4

  let verse = merge ensemble

  let chorus = gate
        (Map.fromFoldable
           [ voiced "pad" (pure false) ])
        ensemble

  let bridge = crossfade
        (fastCat [ pure (Voice "lead"), pure (Voice "bass") ])
        ensemble

  showScore "verse  (merge)"   (queryArc verse  (fromInt 0) (fromInt 1))
  showScore "chorus (gate pad off)"  (queryArc chorus (fromInt 0) (fromInt 1))
  showScore "bridge (crossfade lead↔bass)" (queryArc bridge (fromInt 0) (fromInt 1))

  log "Three completely different sections from one fan-out + three merges."
  log "This is the 'compositional thinking' decision in code. To change a"
  log "section's character you don't rebuild the voices — you swap the merge."
  log ""

-- ---------------------------------------------------------------------------
-- Section 8 — composing: jux on top of mult; nested fan-out
-- ---------------------------------------------------------------------------
-- A `Branched` returns a `Pattern` after merge, so the next operator can
-- treat it as just another pattern. Nesting works: a leaf inside one
-- fan-out can itself be a `merge` of an inner fan-out. (The catch: the
-- inner fan-out's topology is invisible to the renderer once merged —
-- see BranchedHardCases case D for the cost.)
section8 :: Effect Unit
section8 = do
  log "── Section 8 — composing ─────────────────────────────────────────────"
  log "Musical idea: lead splits internally into soprano + alto harmony,"
  log "then the outer jux puts that harmony on the left and the bass on"
  log "the right."
  log ""

  let leadHarmony = merge
        (fanOut
          [ voiced "soprano" identity
          , voiced "alto" (slow (fromInt 2))
          ]
          m4)

  let stereoEnsemble = mult
        [ voiced "L" (\_ -> leadHarmony)
        , voiced "R" identity
        ]
        m2  -- the outer "anchor" pattern; transforms ignore it on the L branch

  showScore "stereoEnsemble" (queryArc stereoEnsemble (fromInt 0) (fromInt 1))

  log "Notice how nesting compiles down: the outer merge sees more events"
  log "than a flat 2-voice mult would, because the inner harmony already"
  log "stacked two patterns before the outer split saw it."
  log ""

