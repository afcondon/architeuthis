-- | Predictive event-shape tests.
-- |
-- | Each test states what events the pattern *should* produce, fully —
-- | value, `whole`, AND `part` — based on Tidal's pattern-evaluation
-- | spec. The point is that the prediction is written from the spec
-- | (or from understanding of how a given operator should behave),
-- | NOT golden-captured from current output. If a future regression
-- | shifts behaviour, the test fails with a diff showing what changed.
-- |
-- | Importantly these tests check the `whole` field, not just `part`.
-- | The slow-of-stack bug fixed in 196a54f hid for a long time because
-- | the existing helpers only looked at `part` — `part` was correct
-- | (the event covered the queried sub-arc), `whole` was wrong (clipped
-- | to query instead of spanning the full scaled cycle), and the
-- | scheduler dispatched off `part.start` so it fired chord-on-every-
-- | cycle even for `slow 4`. Predictive tests against `whole` would
-- | have caught this on day one.
-- |
-- | Layer 1 only: pure pattern semantics, no scheduler, no MIDI.
module Test.PredictiveSpec
  ( runPredictiveTests
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Haskell.Rational (Rational, fromInt, toNumber, (%))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Pattern.Core (every, fast, fastCat, queryArc, rev, slow, stack)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern)

-------------------------------------------------------------------------------
-- Expected event shape and assertion machinery
-------------------------------------------------------------------------------

-- | Fully-specified expected event: value plus both arcs.
type ExpectedFull =
  { value :: String
  , wholeStart :: Number
  , wholeStop :: Number
  , partStart :: Number
  , partStop :: Number
  }

-- | Compose an expected event with whole and part arcs that may differ.
-- | Use this when the event spans more cycles than the query reaches
-- | (typical under `slow N`): whole = full event arc, part = queried slice.
expect
  :: String
  -> { wholeStart :: Number, wholeStop :: Number }
  -> { partStart :: Number, partStop :: Number }
  -> ExpectedFull
expect v w p =
  { value: v
  , wholeStart: w.wholeStart, wholeStop: w.wholeStop
  , partStart: p.partStart, partStop: p.partStop
  }

-- | Convenience for events where whole == part. True for atoms inside
-- | their own cycle, sequences not under time-scaling combinators, etc.
aligned :: String -> Number -> Number -> ExpectedFull
aligned v s e =
  { value: v
  , wholeStart: s, wholeStop: e
  , partStart: s, partStop: e
  }

-- | Per-field tolerance for Number comparison. Rationals from the
-- | pattern engine round-trip cleanly through toNumber for the values
-- | we use (small fractions of integers); this guards against the
-- | last-bit float wobble.
eps :: Number
eps = 0.0001

approxEq :: Number -> Number -> Boolean
approxEq a b = (a - b < eps) && (b - a < eps)

eventDigital :: Event String -> Maybe { value :: String, ws :: Number, wstop :: Number, ps :: Number, pstop :: Number }
eventDigital = case _ of
  Digital { value, whole: Arc w, part: Arc p } ->
    Just
      { value
      , ws: toNumber w.start, wstop: toNumber w.stop
      , ps: toNumber p.start, pstop: toNumber p.stop
      }
  Analog _ -> Nothing

matches :: Event String -> ExpectedFull -> Boolean
matches ev e = case eventDigital ev of
  Nothing -> false
  Just a ->
    a.value == e.value
      && approxEq a.ws e.wholeStart
      && approxEq a.wstop e.wholeStop
      && approxEq a.ps e.partStart
      && approxEq a.pstop e.partStop

showExpected :: ExpectedFull -> String
showExpected e =
  e.value
    <> "  whole=[" <> show e.wholeStart <> ", " <> show e.wholeStop <> "]"
    <> "  part=["  <> show e.partStart <> ", " <> show e.partStop <> "]"

showActual :: Event String -> String
showActual ev = case eventDigital ev of
  Just a ->
    a.value
      <> "  whole=[" <> show a.ws <> ", " <> show a.wstop <> "]"
      <> "  part=["  <> show a.ps <> ", " <> show a.pstop <> "]"
  Nothing -> "(analog event)"

-- | Run a predictive test. Order-insensitive: events are compared after
-- | sorting both sides by (partStart, value). Tidal's pattern engine
-- | has a defined ordering, but the order of an event's appearance in
-- | the result array is an implementation detail — the spec is about
-- | which (value, whole, part) tuples appear, not the array index they
-- | land at. Asserting on order would produce spurious reds when an
-- | unrelated combinator changes its iteration shape.
testPattern
  :: String
  -> Pattern String
  -> Rational
  -> Rational
  -> Array ExpectedFull
  -> Effect Unit
testPattern desc pat from to expected = do
  let actual = queryArc pat from to
  let actualSorted = Array.sortWith eventSortKey actual
  let expectedSorted = Array.sortWith expectedSortKey expected
  let countOk = Array.length actualSorted == Array.length expectedSorted
  let pairs = Array.zip actualSorted expectedSorted
  let allMatch = Array.all (\(Tuple a e) -> matches a e) pairs
  if countOk && allMatch then
    log $ "  ✓ " <> desc
  else do
    log $ "  ✗ " <> desc
    log $ "    expected " <> show (Array.length expectedSorted) <> " events:"
    for_ expectedSorted \e -> log $ "      " <> showExpected e
    log $ "    actual " <> show (Array.length actualSorted) <> " events:"
    for_ actualSorted \e -> log $ "      " <> showActual e

-- | Sort key derived from an event: (partStart, value). PartStart
-- | breaks ties first because it's the most semantically meaningful
-- | ordering (when the event lands in the queried arc).
eventSortKey :: Event String -> { ps :: Number, value :: String }
eventSortKey e = case eventDigital e of
  Just a -> { ps: a.ps, value: a.value }
  Nothing -> { ps: 0.0, value: "" }

expectedSortKey :: ExpectedFull -> { ps :: Number, value :: String }
expectedSortKey e = { ps: e.partStart, value: e.value }

-------------------------------------------------------------------------------
-- Test sections
-------------------------------------------------------------------------------

runPredictiveTests :: Effect Unit
runPredictiveTests = do
  log ""
  log "============================================"
  log "  Predictive Pattern Spec Tests"
  log "  (declares expected whole AND part)"
  log "============================================"

  log ""
  log "--- Atoms ---"
  -- A single `pure` value is a pattern that fires once per cycle, with
  -- the event's whole spanning the full cycle [n, n+1).
  testPattern "pure x at [0, 1] — one event whole=part=[0,1]"
    (pure "x")
    (fromInt 0) (fromInt 1)
    [ aligned "x" 0.0 1.0 ]

  testPattern "pure x at [0, 2] — two events, one per cycle"
    (pure "x")
    (fromInt 0) (fromInt 2)
    [ aligned "x" 0.0 1.0
    , aligned "x" 1.0 2.0
    ]

  -- Sub-cycle queries return one event whose `whole` still spans the
  -- full cycle — `part` is the queried slice.
  testPattern "pure x at [0, 0.5] — whole spans full cycle, part is the slice"
    (pure "x")
    (fromInt 0) (1 % 2)
    [ expect "x" { wholeStart: 0.0, wholeStop: 1.0 } { partStart: 0.0, partStop: 0.5 } ]

  log ""
  log "--- fastCat (sequence inside one cycle) ---"
  -- fastCat distributes N elements evenly across one cycle. Each event's
  -- whole == part == its assigned sub-arc.
  testPattern "fastCat [a, b] at [0, 1] — two events, each 1/2 cycle"
    (fastCat [pure "a", pure "b"])
    (fromInt 0) (fromInt 1)
    [ aligned "a" 0.0 0.5
    , aligned "b" 0.5 1.0
    ]

  testPattern "fastCat [a, b, c, d] at [0, 1] — four events, each 1/4 cycle"
    (fastCat [pure "a", pure "b", pure "c", pure "d"])
    (fromInt 0) (fromInt 1)
    [ aligned "a" 0.0  0.25
    , aligned "b" 0.25 0.5
    , aligned "c" 0.5  0.75
    , aligned "d" 0.75 1.0
    ]

  log ""
  log "--- stack (parallel, simultaneous) ---"
  -- stack produces all members at the SAME time per cycle. Each event's
  -- whole spans the full cycle; multiple events at one moment.
  testPattern "stack [a, b] at [0, 1] — two simultaneous full-cycle events"
    (stack [pure "a", pure "b"])
    (fromInt 0) (fromInt 1)
    [ aligned "a" 0.0 1.0
    , aligned "b" 0.0 1.0
    ]

  testPattern "stack [a, b, c] at [0, 1] — three simultaneous events"
    (stack [pure "a", pure "b", pure "c"])
    (fromInt 0) (fromInt 1)
    [ aligned "a" 0.0 1.0
    , aligned "b" 0.0 1.0
    , aligned "c" 0.0 1.0
    ]

  log ""
  log "--- fast N (compress events into one cycle, repeat) ---"
  -- fast N replays the pattern N times per cycle. Each event's whole
  -- shrinks by 1/N.
  testPattern "fast 2 (pure x) at [0, 1] — two events, half-cycle each"
    (fast (fromInt 2) (pure "x"))
    (fromInt 0) (fromInt 1)
    [ aligned "x" 0.0 0.5
    , aligned "x" 0.5 1.0
    ]

  testPattern "fast 4 (pure x) at [0, 1] — four events, quarter-cycle each"
    (fast (fromInt 4) (pure "x"))
    (fromInt 0) (fromInt 1)
    [ aligned "x" 0.0  0.25
    , aligned "x" 0.25 0.5
    , aligned "x" 0.5  0.75
    , aligned "x" 0.75 1.0
    ]

  log ""
  log "--- slow N (stretch events across multiple cycles) ---"
  -- slow N takes N cycles for one iteration. The first onset's whole
  -- spans [0, N]; at scheduler cycle k (k < N) the event continues, so
  -- whole stays [0, N] but part = [k, k+1].
  testPattern "slow 2 (pure x) at [0, 1] — onset, whole=[0,2] part=[0,1]"
    (slow (fromInt 2) (pure "x"))
    (fromInt 0) (fromInt 1)
    [ expect "x" { wholeStart: 0.0, wholeStop: 2.0 } { partStart: 0.0, partStop: 1.0 } ]

  testPattern "slow 2 (pure x) at [1, 2] — continuation, whole=[0,2] part=[1,2]"
    (slow (fromInt 2) (pure "x"))
    (fromInt 1) (fromInt 2)
    [ expect "x" { wholeStart: 0.0, wholeStop: 2.0 } { partStart: 1.0, partStop: 2.0 } ]

  testPattern "slow 2 (pure x) at [2, 3] — next iteration, whole=[2,4]"
    (slow (fromInt 2) (pure "x"))
    (fromInt 2) (fromInt 3)
    [ expect "x" { wholeStart: 2.0, wholeStop: 4.0 } { partStart: 2.0, partStop: 3.0 } ]

  testPattern "slow 4 (pure x) at [0, 1] — once every 4 cycles"
    (slow (fromInt 4) (pure "x"))
    (fromInt 0) (fromInt 1)
    [ expect "x" { wholeStart: 0.0, wholeStop: 4.0 } { partStart: 0.0, partStop: 1.0 } ]

  testPattern "slow 4 (pure x) at [3, 4] — still inside the first iteration"
    (slow (fromInt 4) (pure "x"))
    (fromInt 3) (fromInt 4)
    [ expect "x" { wholeStart: 0.0, wholeStop: 4.0 } { partStart: 3.0, partStop: 4.0 } ]

  testPattern "slow 4 (pure x) at [4, 5] — second iteration onset"
    (slow (fromInt 4) (pure "x"))
    (fromInt 4) (fromInt 5)
    [ expect "x" { wholeStart: 4.0, wholeStop: 8.0 } { partStart: 4.0, partStop: 5.0 } ]

  log ""
  log "--- slow N (stack [...]) — the bug fixed in 196a54f ---"
  -- This is the exact case the bug masked. Each stack member produces
  -- one event per slow-N iteration, all simultaneous, with whole
  -- spanning [iN, (i+1)N] and part landing in the queried scheduler
  -- cycle. Pre-fix: whole was wrong (clipped to query) so the chord
  -- fired every cycle.
  testPattern "slow 4 (stack [a, b]) at [0, 1] — both onsets, whole=[0,4]"
    (slow (fromInt 4) (stack [pure "a", pure "b"]))
    (fromInt 0) (fromInt 1)
    [ expect "a" { wholeStart: 0.0, wholeStop: 4.0 } { partStart: 0.0, partStop: 1.0 }
    , expect "b" { wholeStart: 0.0, wholeStop: 4.0 } { partStart: 0.0, partStop: 1.0 }
    ]

  testPattern "slow 4 (stack [a, b]) at [1, 2] — continuation, whole=[0,4] part=[1,2]"
    (slow (fromInt 4) (stack [pure "a", pure "b"]))
    (fromInt 1) (fromInt 2)
    [ expect "a" { wholeStart: 0.0, wholeStop: 4.0 } { partStart: 1.0, partStop: 2.0 }
    , expect "b" { wholeStart: 0.0, wholeStop: 4.0 } { partStart: 1.0, partStop: 2.0 }
    ]

  testPattern "slow 4 (stack [a, b]) at [4, 5] — next iteration, whole=[4,8]"
    (slow (fromInt 4) (stack [pure "a", pure "b"]))
    (fromInt 4) (fromInt 5)
    [ expect "a" { wholeStart: 4.0, wholeStop: 8.0 } { partStart: 4.0, partStop: 5.0 }
    , expect "b" { wholeStart: 4.0, wholeStop: 8.0 } { partStart: 4.0, partStop: 5.0 }
    ]

  log ""
  log "--- slow N (fastCat [...]) — slow stretches the whole sequence ---"
  -- slow 2 of fastCat [a, b]: a takes one full scheduler cycle [0, 1],
  -- then b takes the next [1, 2]. Each event's whole is one whole
  -- scheduler cycle (a:[0,1], b:[1,2]).
  testPattern "slow 2 (fastCat [a, b]) at [0, 1] — a only, whole=[0,1]"
    (slow (fromInt 2) (fastCat [pure "a", pure "b"]))
    (fromInt 0) (fromInt 1)
    [ aligned "a" 0.0 1.0 ]

  testPattern "slow 2 (fastCat [a, b]) at [1, 2] — b only, whole=[1,2]"
    (slow (fromInt 2) (fastCat [pure "a", pure "b"]))
    (fromInt 1) (fromInt 2)
    [ aligned "b" 1.0 2.0 ]

  log ""
  log "--- fast/slow inverses ---"
  -- fast (1/N) ≡ slow N. Both should produce identical events.
  testPattern "fast (1/4) (pure x) at [0, 1] — same shape as slow 4"
    (fast (1 % 4) (pure "x"))
    (fromInt 0) (fromInt 1)
    [ expect "x" { wholeStart: 0.0, wholeStop: 4.0 } { partStart: 0.0, partStop: 1.0 } ]

  testPattern "slow (1/4) (pure x) at [0, 1] — slow with rate < 1 ≡ fast 4"
    (slow (1 % 4) (pure "x"))
    (fromInt 0) (fromInt 1)
    [ aligned "x" 0.0  0.25
    , aligned "x" 0.25 0.5
    , aligned "x" 0.5  0.75
    , aligned "x" 0.75 1.0
    ]

  log ""
  log "--- rev ---"
  -- rev reverses each cycle's content. fastCat [a, b] → fastCat [b, a]
  -- per cycle.
  testPattern "rev (fastCat [a, b]) at [0, 1] — order flipped"
    (rev (fastCat [pure "a", pure "b"]))
    (fromInt 0) (fromInt 1)
    [ aligned "b" 0.0 0.5
    , aligned "a" 0.5 1.0
    ]

  log ""
  log "--- every N f ---"
  -- OG Tidal: `every N f p` applies f when `cycle mod N == 0`. So
  -- cycle 0 is the FIRST one transformed, NOT the last of an N-cycle
  -- group. This is a frequent mental-model trap (and one I described
  -- backwards during the live tutorial that motivated this suite).
  testPattern "every 2 rev (fastCat [a, b]) at [0, 1] — rev applied (0 mod 2 = 0)"
    (every 2 rev (fastCat [pure "a", pure "b"]))
    (fromInt 0) (fromInt 1)
    [ aligned "b" 0.0 0.5
    , aligned "a" 0.5 1.0
    ]

  testPattern "every 2 rev (fastCat [a, b]) at [1, 2] — identity (1 mod 2 = 1)"
    (every 2 rev (fastCat [pure "a", pure "b"]))
    (fromInt 1) (fromInt 2)
    [ aligned "a" 1.0 1.5
    , aligned "b" 1.5 2.0
    ]

  testPattern "every 2 rev (fastCat [a, b]) at [2, 3] — rev applied (2 mod 2 = 0)"
    (every 2 rev (fastCat [pure "a", pure "b"]))
    (fromInt 2) (fromInt 3)
    [ aligned "b" 2.0 2.5
    , aligned "a" 2.5 3.0
    ]

  log ""
  log "============================================"
