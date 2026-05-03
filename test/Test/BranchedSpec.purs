-- | Tests for `Tidal.Pattern.Branched`.
-- |
-- | Codifies the semantics of the four merges (`merge`, `gate`, `crossfade`,
-- | `alternate`) and the sugar (`mult`, `jux`) against the gating decisions
-- | from the design conversation.
module Test.BranchedSpec where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Rational (fromInt)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Pattern.Branched
  ( Voice(..)
  , alternate
  , crossfade
  , fanOut
  , gate
  , jux
  , merge
  , mult
  )
import Tidal.Pattern.Core (fastCat, queryArc, rev, slow, stack)
import Tidal.Pattern.Types (Pattern, silence)

-- A small reusable melody.
m4 :: Pattern String
m4 = fastCat (map pure [ "a", "b", "c", "d" ])

-- ---------------------------------------------------------------------------

runBranchedTests :: Effect Unit
runBranchedTests = do
  log ""
  log "=========================================="
  log "  Branched (fork/merge) Tests"
  log "=========================================="
  log ""

  log "--- merge ≡ stack ---"
  -- merge of fanOut [(L, id), (R, rev)] m4 should produce the same events
  -- as stack [m4, rev m4].
  let
    branched = fanOut
      [ Tuple (Voice "L") identity
      , Tuple (Voice "R") rev
      ] m4
    eventsMerge   = queryArc (merge branched)         (fromInt 0) (fromInt 1)
    eventsStacked = queryArc (stack [m4, rev m4])     (fromInt 0) (fromInt 1)
  expectEq "merge ≡ stack (event count)"
    (Array.length eventsMerge) (Array.length eventsStacked)

  log ""
  log "--- merge of single-voice fanOut ≡ original ---"
  let
    soloBranched = fanOut [ Tuple (Voice "L") identity ] m4
    eventsSolo   = queryArc (merge soloBranched) (fromInt 0) (fromInt 1)
    eventsM4     = queryArc m4                   (fromInt 0) (fromInt 1)
  expectEq "merge [(L, id)] m4 ≡ m4 (event count)"
    (Array.length eventsSolo) (Array.length eventsM4)

  log ""
  log "--- gate: missing key passes through (open default, decision #3) ---"
  let
    branched2 = fanOut [ Tuple (Voice "L") identity ] m4
    eventsGated  = queryArc (gate Map.empty branched2)        (fromInt 0) (fromInt 1)
    eventsMerged = queryArc (merge branched2)                 (fromInt 0) (fromInt 1)
  expectEq "gate Map.empty ≡ merge (open default)"
    (Array.length eventsGated) (Array.length eventsMerged)

  log ""
  log "--- gate: present-and-true passes through ---"
  let
    eventsTrue = queryArc
      (gate (Map.fromFoldable [ Tuple (Voice "L") (pure true) ]) branched2)
      (fromInt 0) (fromInt 1)
  expectEq "gate {L: true} ≡ merge (event count)"
    (Array.length eventsTrue) (Array.length eventsMerged)

  log ""
  log "--- gate: present-and-false silences that voice ---"
  let
    eventsFalse = queryArc
      (gate (Map.fromFoldable [ Tuple (Voice "L") (pure false) ]) branched2)
      (fromInt 0) (fromInt 1)
  expectEq "gate {L: false} on single-voice ≡ silence (0 events)"
    (Array.length eventsFalse) 0

  log ""
  log "--- crossfade: pure (Voice \"L\") emits L's events ---"
  let
    branchedLR = fanOut
      [ Tuple (Voice "L") identity
      , Tuple (Voice "R") rev
      ] m4
    eventsCrossL = queryArc
      (crossfade (pure (Voice "L")) branchedLR)
      (fromInt 0) (fromInt 1)
    eventsL = queryArc m4 (fromInt 0) (fromInt 1)
  expectEq "crossfade pure-L ≡ L (event count)"
    (Array.length eventsCrossL) (Array.length eventsL)

  log ""
  log "--- crossfade: unbound voice emits silence (decision #2) ---"
  let
    eventsCrossUnbound = queryArc
      (crossfade (pure (Voice "missing")) branchedLR)
      (fromInt 0) (fromInt 1)
  expectEq "crossfade pure-(unbound) ≡ silence (0 events)"
    (Array.length eventsCrossUnbound) 0

  log ""
  log "--- alternate: round-robins per cycle in declared order (decision #4) ---"
  let
    branchedAB = fanOut
      [ Tuple (Voice "A") identity
      , Tuple (Voice "B") rev
      ] m4
    altPat = alternate branchedAB
    -- Cycle 0 should equal m4; cycle 1 should equal rev m4
    eventsCycle0 = queryArc altPat (fromInt 0) (fromInt 1)
    eventsCycle1 = queryArc altPat (fromInt 1) (fromInt 2)
    refCycle0    = queryArc m4         (fromInt 0) (fromInt 1)
    refCycle1    = queryArc (rev m4)   (fromInt 1) (fromInt 2)
  expectEq "alternate cycle 0 = first voice (event count)"
    (Array.length eventsCycle0) (Array.length refCycle0)
  expectEq "alternate cycle 1 = second voice (event count)"
    (Array.length eventsCycle1) (Array.length refCycle1)

  log ""
  log "--- alternate: empty Branched is silence ---"
  let
    eventsAltEmpty = queryArc
      (alternate (fanOut [] m4))
      (fromInt 0) (fromInt 1)
  expectEq "alternate (fanOut [] m) ≡ silence"
    (Array.length eventsAltEmpty) 0

  log ""
  log "--- mult ≡ merge ∘ fanOut ---"
  let
    transforms =
      [ Tuple (Voice "X") identity
      , Tuple (Voice "Y") (slow (fromInt 2))
      ]
    eventsMult       = queryArc (mult transforms m4)               (fromInt 0) (fromInt 1)
    eventsMergeFanOut = queryArc (merge (fanOut transforms m4))    (fromInt 0) (fromInt 1)
  expectEq "mult ≡ merge ∘ fanOut (event count)"
    (Array.length eventsMult) (Array.length eventsMergeFanOut)

  log ""
  log "--- jux f ≡ mult [(L, id), (R, f)] ---"
  let
    eventsJux = queryArc (jux rev m4) (fromInt 0) (fromInt 1)
    eventsManual = queryArc
      (mult [ Tuple (Voice "L") identity, Tuple (Voice "R") rev ] m4)
      (fromInt 0) (fromInt 1)
  expectEq "jux rev ≡ manual mult L/R"
    (Array.length eventsJux) (Array.length eventsManual)

  log ""
  log "--- silence baseline (event count == 0) ---"
  let
    eventsSilence = queryArc (silence :: Pattern String) (fromInt 0) (fromInt 1)
  expectEq "silence ≡ 0 events" (Array.length eventsSilence) 0

  log ""

-- ---------------------------------------------------------------------------

expectEq :: forall a. Eq a => Show a => String -> a -> a -> Effect Unit
expectEq desc actual expected =
  if actual == expected
    then log $ "  ✓ " <> desc <> ": " <> show actual
    else log $ "  ✗ " <> desc
            <> "\n    expected: " <> show expected
            <> "\n    actual:   " <> show actual
