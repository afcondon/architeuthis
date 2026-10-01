-- | Core pattern combinators
-- |
-- | This module provides the fundamental operations for transforming
-- | and combining patterns. These correspond to Tidal's Core.hs module.
-- |
-- | Design notes:
-- | - We avoid the underscore pattern explosion from Haskell Tidal
-- | - Functions take concrete values where Haskell had "patternify" variants
-- | - Use `fmap` or `(<$>)` to lift concrete functions to patterns
module Tidal.Pattern.Core
  ( -- * Time manipulation
    fast
  , slow
  , rotL
  , rotR
  , rev
  , repeatEvery
    -- * Pattern structure
  , cat
  , fastCat
  , slowCat
  , stack
  , overlay
  , append
  , fastAppend
    -- * Transformations
  , segment
  , compress
  , zoom
  , every
  , whenCycle
  , whenMod
  , iter
  , iter'
  , linger
  , trunc
  , steptake
  , stepdrop
    -- * Higher-order combinators
  , palindrome
  , superimpose
  , off
  , inside
  , outside
  , range
  , brak
  , loopFirst
  , stutter
  , ply
  , chunk
  , within
  , swingBy
  , swingByR
  , swing
    -- * Oscillators (continuous patterns)
  , sine
  , cosine
  , saw
  , isaw
  , tri
  , square
  , expSaw
  , iexpSaw
  , logSaw
  , ilogSaw
  , rand
  , irand
    -- * Haskell Tidal's machinery
  , withResultArc
  , withResultTime
  , withQueryTime
  , splitQueries
  , arcCyclesZW
  , timeCat
  , fastGap
  , innerJoin
  , unwrap
  , uncollect
  , patternify
  , rangeBy
  , chooseBy
  , degradeByUsing
  , euclid
  , euclidOff
  , bjorklund
    -- * Filtering and selection
  , filterEvents
  , filterDigital
  , filterAnalog
  , filterValues
    -- * Pattern queries
  , firstCycle
  , queryArc
  , queryArcWith
    -- * Time utilities
  , sam
  , nextSam
  , cyclePos
  , wholeCycle
    -- * Pattern conversion
  , patternStringToNumber
    -- * Arc operations (re-exported)
  , module ArcExports
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.Ord (comparing)
import Data.Foldable (foldl)
import Haskell.Rational (Rational, fromInt, toNumber)
import Data.Tuple (Tuple(..), fst)
import Partial.Unsafe (unsafeCrashWith)
import Tidal.Pattern.Random (timeToRand)
import Haskell.Double (cos, pi, sin, sqrt)
import Haskell.Double as Double
import Haskell.Integer as Integer
import Tidal.Core.Types (Time)
import Tidal.Notation (class Notation, toPattern)
import Tidal.Pattern.Types
  ( Arc(..)
  , ControlMap
  , Event(..)
  , Pattern(..)
  , State(..)
  , Context
  , emptyContext
  , arcStart
  , arcStop
  , eventPart
  , eventValue
  , isAnalog
  , isDigital
  , mapEventValue
  , mkArc
  , pattern
  , query
  , silence
  ) as ArcExports
import Tidal.Pattern.Types
  ( Arc(..)
  , ControlMap
  , Context
  , Event(..)
  , Pattern
  , State(..)
  , applyLeft
  , applyRight
  , eventPart
  , mapEventValue
  , floorDiv
  , floorMod
  , floorR
  , subArc
  , arcStart
  , arcStop
  , emptyContext
  , eventValue
  , isAnalog
  , isDigital
  , pattern
  , query
  )

-------------------------------------------------------------------------------
-- Time utilities
-------------------------------------------------------------------------------

-- | The start of the cycle containing this time (floor to integer)
sam :: Time -> Time
sam t =
  let n = floorTime t
  in if n <= t then n else n - one

-- | The start of the next cycle
nextSam :: Time -> Time
nextSam t = sam t + one

-- | Position within current cycle (0 to 1)
cyclePos :: Time -> Time
cyclePos t = t - sam t

-- | The arc spanning the whole cycle containing this time
wholeCycle :: Time -> Arc
wholeCycle t = Arc { start: sam t, stop: nextSam t }

-- | Floor a time to integer (as Rational)
floorTime :: Time -> Time
floorTime t = fromInt (floorR t)

-------------------------------------------------------------------------------
-- Time manipulation
-------------------------------------------------------------------------------

-- | Speed up a pattern by a factor: Haskell Tidal's `_fast`. A negative
-- | rate reverses the fast pattern (`rev (fast r p)`, not `fast r (rev p)`).
fast :: forall a. Rational -> Pattern a -> Pattern a
fast rate pat
  | rate == zero = silence
  | rate < zero = rev (fast (negate rate) pat)
  | otherwise = withResultTime (_ / rate) (withQueryTime (_ * rate) pat)

-- | Slow down a pattern by a factor
-- |
-- | `slow 2 p` plays pattern `p` at half speed
slow :: forall a. Rational -> Pattern a -> Pattern a
slow rate pat
  | rate == zero = silence
  | otherwise = fast (one / rate) pat

-- | Rotate a pattern left (earlier) in time
-- |
-- | `rotL t p` shifts pattern `p` earlier by time `t`
rotL :: forall a. Time -> Pattern a -> Pattern a
rotL t pat = pattern \(State st) ->
  let
    shiftedArc = Arc
      { start: arcStart st.arc + t
      , stop: arcStop st.arc + t
      }
    events = query pat (State st { arc = shiftedArc })
  in
    map (shiftEventTime (negate t)) events

-- | Rotate a pattern right (later) in time
rotR :: forall a. Time -> Pattern a -> Pattern a
rotR t = rotL (negate t)

-- | Repeat a pattern every n cycles.  Events that `pat` produces in
-- | the cycle range `[0, n)` are replayed at every subsequent n-cycle
-- | offset, indefinitely.
-- |
-- | Use when you've built a Pattern by direct event construction
-- | (i.e. handing `pattern \st -> events` events with absolute cycle
-- | positions) and need it to loop.  Patterns built from `cat`,
-- | `fastCat`, `pure` etc. already loop automatically via mod-cycle
-- | indexing — this combinator exists for the *non-cat* construction
-- | path that would otherwise go silent past cycle n.
-- |
-- | Trap this closes: if you write a Pattern that places events at
-- | cycles 0, 3, 7, 12 of an 18-cycle progression and forget to wrap
-- | it, playback will produce events for the first 18 cycles and
-- | then silence forever (no crash, no warning — just silence).
-- |
-- | n <= 0 yields silence.
repeatEvery :: forall a. Int -> Pattern a -> Pattern a
repeatEvery n pat
  | n <= 0 = silence
  | otherwise = pattern \(State st) ->
      let
        Arc q = st.arc
        nR = fromInt n
        -- Iteration range: which integer offsets k can produce events
        -- in the query arc.  An iteration k maps inner [0, n) to
        -- output [k*n, (k+1)*n); for it to overlap qArc we need
        -- k*n < q.stop AND (k+1)*n > q.start.
        qStartInt = floorR q.start
        qStopInt = floorR q.stop + 1
        kMin = (qStartInt `div` n) - 1
        kMax = (qStopInt `div` n) + 1
        eventsForIter k =
          let
            kShift = fromInt k * nR
            innerStart = max (fromInt 0) (q.start - kShift)
            innerStop  = min nR (q.stop - kShift)
          in
            if innerStart >= innerStop
              then []
              else
                let
                  innerArc = Arc { start: innerStart, stop: innerStop }
                  innerEvents = query pat (State st { arc = innerArc })
                in
                  map (shiftEventTime kShift) innerEvents
      in
        Array.concatMap eventsForIter (Array.range kMin kMax)

-- | Shift event times
shiftEventTime :: forall a. Time -> Event a -> Event a
shiftEventTime t = case _ of
  Digital e -> Digital e
    { whole = shiftArc t e.whole
    , part = shiftArc t e.part
    }
  Analog e -> Analog e
    { part = shiftArc t e.part
    }

-- | Shift an arc by a time offset
shiftArc :: Time -> Arc -> Arc
shiftArc t (Arc { start, stop }) = Arc { start: start + t, stop: stop + t }

-- | Reverse each cycle: Haskell Tidal's `rev`. The query is split by cycle
-- | and mirrored about the cycle's middle; an event's whole keeps its
-- | offsets from its part, so a fragment of a longer event stays one.
rev :: forall n a. Notation n a => n -> Pattern a
rev notation = splitQueries $ pattern \(State st) ->
  let
    pat = toPattern notation
    mid = sam (arcStart st.arc) + (one / fromInt 2)
    mirror (Arc a) = Arc { start: mid - (a.stop - mid), stop: mid + (mid - a.start) }
    flipEvent = case _ of
      Digital e ->
        let
          Arc w = e.whole
          Arc p = e.part
          Arc p' = mirror e.part
        in
          Digital e
            { part = Arc p'
            , whole = Arc { start: p'.start - (w.stop - p.stop), stop: p'.stop + (p.start - w.start) }
            }
      Analog e -> Analog e { part = mirror e.part }
  in
    map flipEvent (query pat (State st { arc = mirror st.arc }))

-------------------------------------------------------------------------------
-- Pattern structure
-------------------------------------------------------------------------------

-- | One pattern per cycle, in turn: Haskell Tidal's `cat`. Each pattern
-- | counts its own cycles, so in `cat [a, b]` cycle 2 plays a's cycle 1.
cat :: forall a. Array (Pattern a) -> Pattern a
cat [] = silence
cat [ p ] = p
cat pats = pattern \(State st) ->
  Array.concatMap (cycleOf st) (arcCyclesZW st.arc)
  where
  n = Array.length pats
  cycleOf st (Arc a) =
    let
      cyc = floorR a.start
      i = floorMod cyc n
      offset = fromInt (cyc - floorDiv (cyc - i) n)
    in
      case Array.index pats i of
        Nothing -> []
        Just p ->
          query (withResultTime (_ + offset) p)
            (State st { arc = Arc { start: a.start - offset, stop: a.stop - offset } })

-- | All the patterns in one cycle: Haskell Tidal's `fastCat`.
fastCat :: forall a. Array (Pattern a) -> Pattern a
fastCat [ p ] = p
fastCat pats = fast (fromInt (Array.length pats)) (cat pats)

-- | Slow concatenation - alias for `cat`
slowCat :: forall a. Array (Pattern a) -> Pattern a
slowCat = cat

-- | Stack patterns - all play simultaneously
-- |
-- | `stack [a, b, c]` plays all patterns layered on top of each other
stack :: forall a. Array (Pattern a) -> Pattern a
stack [] = silence
stack pats = pattern \st ->
  Array.concatMap (\p -> query p st) pats

-- | Overlay two patterns (infix-friendly stack)
overlay :: forall a. Pattern a -> Pattern a -> Pattern a
overlay a b = stack [a, b]

-- | Append patterns - first for one cycle, then second for one cycle
append :: forall a. Pattern a -> Pattern a -> Pattern a
append a b = cat [a, b]

-- | Fast append - both patterns in one cycle
fastAppend :: forall a. Pattern a -> Pattern a -> Pattern a
fastAppend a b = fastCat [a, b]

-------------------------------------------------------------------------------
-- Transformations
-------------------------------------------------------------------------------

-- | Sample a pattern n times a cycle: Haskell Tidal's `_segment`,
-- | `_fast n (pure id) <* p`.
segment :: forall a. Int -> Pattern a -> Pattern a
segment n pat = applyLeft (fast (fromInt n) (pure identity)) pat

-- | Squeeze each cycle into the span s..e of a cycle, leaving the rest
-- | empty: Haskell Tidal's `compressArc`.
compress :: forall a. Time -> Time -> Pattern a -> Pattern a
compress s e p
  | s > e || s > one || e > one || s < zero || e < zero || s == e = silence
  | otherwise = rotR s (fastGap (one / (e - s)) p)

-- | Haskell Tidal's `_fastGap`: speed up within each cycle, leaving a gap
-- | rather than starting the next cycle early. Queries split by cycle.
fastGap :: forall a. Time -> Pattern a -> Pattern a
fastGap r p
  | r == zero = silence
  | otherwise = splitQueries $ withResultArc munge $ pattern \(State st) ->
      let
        Arc q = st.arc
        a' = Arc { start: mungeQuery q.start, stop: mungeQuery q.stop }
      in
        if arcStart a' == nextSam q.start then [] else query p (State st { arc = a' })
  where
  r' = max r one
  mungeQuery t = sam t + min one (r' * cyclePos t)
  munge (Arc a) =
    let c = sam a.start
    in Arc { start: c + (a.start - c) / r', stop: c + (a.stop - c) / r' }

-- | Zoom into a portion of a pattern
-- |
-- | `zoom (0.25, 0.75) pat` takes the middle half of the pattern
-- | and stretches it to fill the whole cycle.
zoom :: forall a. Time -> Time -> Pattern a -> Pattern a
zoom s e pat
  | s >= e = silence
  | otherwise = pattern \(State st) ->
      let
        scale = e - s
        cycleArcs = splitArcByCycles st.arc

        processOneCycle :: Arc -> Array (Event a)
        processOneCycle cycleArc =
          let
            cyc = sam (arcStart cycleArc)
            Arc { start: qStart, stop: qStop } = cycleArc

            -- Map query from (cyc..cyc+1) to (cyc+s..cyc+e)
            patStart = cyc + s + (qStart - cyc) * scale
            patStop = cyc + s + (qStop - cyc) * scale
            patArc = Arc { start: patStart, stop: patStop }

            events = query pat (State st { arc = patArc })

            -- Map events back to full cycle
            mapEvent = case _ of
              Digital ev ->
                let
                  Arc w = ev.whole
                  Arc p = ev.part
                  mapTime t = cyc + (t - cyc - s) / scale
                in Digital ev
                     { whole = Arc { start: mapTime w.start, stop: mapTime w.stop }
                     , part = Arc { start: mapTime p.start, stop: mapTime p.stop }
                     }
              Analog ev ->
                let
                  Arc p = ev.part
                  mapTime t = cyc + (t - cyc - s) / scale
                in Analog ev
                     { part = Arc { start: mapTime p.start, stop: mapTime p.stop }
                     }
          in map mapEvent events
      in Array.concatMap processOneCycle cycleArcs

-- | Tidal's `_every`: apply the function in every nth cycle (`every 4 rev`
-- | reverses cycles 0, 4, 8, ...). `every 0` is the identity; a negative n
-- | acts as its absolute value, since Tidal tests `cycle `mod` n == 0`.
every :: forall notation a. Notation notation a => Int -> (Pattern a -> Pattern a) -> notation -> Pattern a
every n f notation
  | n == 0 = toPattern notation
  | otherwise = whenCycle (\c -> c `mod` n == 0) f (toPattern notation)

-- | Tidal's `when` (renamed: PureScript's Prelude has a `when`): apply the
-- | function in the cycles whose number passes the test, cycle by cycle.
-- | `when test f p = splitQueries $ p {query = apply}`, where `apply`
-- | queries `f p` if `test (floor $ start $ arc st)`, else `p`.
whenCycle :: forall a. (Int -> Boolean) -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
whenCycle test f p = splitQueries $ pattern \st@(State s) ->
  if test (floorR (arcStart s.arc)) then query (f p) st else query p st

-- | Apply a function when cycle modulo matches
-- |
-- | `whenMod 8 (< 4) rev pat` reverses cycles 0-3 out of every 8
whenMod :: forall a. Int -> (Int -> Boolean) -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
whenMod n pred f pat = pattern \(State st) ->
  let
    cycleArcs = splitArcByCycles st.arc
    processOneCycle cycleArc =
      let
        cyc = floorInt (sam (arcStart cycleArc))
        cycMod = mod cyc n
        shouldApply = pred cycMod
        p = if shouldApply then f pat else pat
      in query p (State st { arc = cycleArc })
  in Array.concatMap processOneCycle cycleArcs
  where
    floorInt t = floorR t

-- | Iterate through a pattern
-- |
-- | `iter 4 pat` divides the pattern into 4 parts and rotates through them
-- | each cycle: cycle 0 plays from 0, cycle 1 from 1/4, cycle 2 from 1/2, etc.
iter :: forall a. Int -> Pattern a -> Pattern a
iter n pat
  | n <= 0 = pat
  | otherwise = pattern \(State st) ->
      let
        cycleArcs = splitArcByCycles st.arc
        processOneCycle cycleArc =
          let
            cyc = floorInt (sam (arcStart cycleArc))
            offset = fromInt (mod cyc n) / fromInt n
            p = rotL offset pat
          in query p (State st { arc = cycleArc })
      in Array.concatMap processOneCycle cycleArcs
  where
    floorInt t = floorR t

-- | Reverse iteration through a pattern
-- |
-- | `iter' 4 pat` is like `iter` but rotates in the opposite direction
iter' :: forall a. Int -> Pattern a -> Pattern a
iter' n pat
  | n <= 0 = pat
  | otherwise = pattern \(State st) ->
      let
        cycleArcs = splitArcByCycles st.arc
        processOneCycle cycleArc =
          let
            cyc = floorInt (sam (arcStart cycleArc))
            offset = fromInt (mod cyc n) / fromInt n
            p = rotR offset pat
          in query p (State st { arc = cycleArc })
      in Array.concatMap processOneCycle cycleArcs
  where
    floorInt t = floorR t

-- | Linger on the first part of a pattern
-- |
-- | `linger 0.25 pat` takes the first quarter of the pattern
-- | and stretches it to fill the whole cycle
linger :: forall a. Rational -> Pattern a -> Pattern a
linger d pat
  | d <= zero = silence
  | d >= one = pat
  | otherwise = compress zero d pat

-- | Truncate a pattern, keeping only the first part
-- |
-- | `trunc 0.5 pat` keeps only the first half of each cycle
trunc :: forall a. Rational -> Pattern a -> Pattern a
trunc d pat
  | d <= zero = silence
  | d >= one = pat
  | otherwise = zoom zero d pat

-- | Take the first n steps of a pattern
-- |
-- | Works with stepwise patterns by taking events from cycle 0
steptake :: forall a. Int -> Pattern a -> Pattern a
steptake n pat
  | n <= 0 = silence
  | otherwise = pattern \(State st) ->
      let
        -- Get events from the first cycle
        events = query pat (State st { arc = Arc { start: zero, stop: one } })
        -- Sort by start time and take first n
        sorted = Array.sortBy (comparing eventStart) events
        taken = Array.take n sorted
        -- Map them back to the query arc
      in mapEventTimes (scaleToArc st.arc (Array.length taken)) <$> taken
  where
    eventStart (Digital e) = arcStart e.part
    eventStart (Analog e) = arcStart e.part

    scaleToArc :: Arc -> Int -> Rational -> Rational
    scaleToArc (Arc arc) count t =
      let duration = arc.stop - arc.start
          scaled = arc.start + (t * duration / fromInt count)
      in scaled

    mapEventTimes :: (Rational -> Rational) -> Event a -> Event a
    mapEventTimes f (Digital e) =
      let Arc p = e.part
          Arc w = e.whole
      in Digital e { part = Arc { start: f p.start, stop: f p.stop }
                   , whole = Arc { start: f w.start, stop: f w.stop } }
    mapEventTimes f (Analog e) =
      let Arc p = e.part
      in Analog e { part = Arc { start: f p.start, stop: f p.stop } }

-- | Drop the first n steps of a pattern
-- |
-- | Works with stepwise patterns by dropping events from cycle 0
stepdrop :: forall a. Int -> Pattern a -> Pattern a
stepdrop n pat
  | n <= 0 = pat
  | otherwise = pattern \(State st) ->
      let
        -- Get events from the first cycle
        events = query pat (State st { arc = Arc { start: zero, stop: one } })
        -- Sort by start time and drop first n
        sorted = Array.sortBy (comparing eventStart) events
        dropped = Array.drop n sorted
        -- Map them back to the query arc
      in mapEventTimes (scaleToArc st.arc (Array.length dropped)) <$> dropped
  where
    eventStart (Digital e) = arcStart e.part
    eventStart (Analog e) = arcStart e.part

    scaleToArc :: Arc -> Int -> Rational -> Rational
    scaleToArc (Arc arc) count t =
      if count == 0 then arc.start
      else
        let duration = arc.stop - arc.start
            scaled = arc.start + (t * duration / fromInt count)
        in scaled

    mapEventTimes :: (Rational -> Rational) -> Event a -> Event a
    mapEventTimes f (Digital e) =
      let Arc p = e.part
          Arc w = e.whole
      in Digital e { part = Arc { start: f p.start, stop: f p.stop }
                   , whole = Arc { start: f w.start, stop: f w.stop } }
    mapEventTimes f (Analog e) =
      let Arc p = e.part
      in Analog e { part = Arc { start: f p.start, stop: f p.stop } }

-------------------------------------------------------------------------------
-- Higher-order combinators
-------------------------------------------------------------------------------

-- | Play a pattern forwards then backwards.
-- |
-- | `palindrome p` plays p in cycle 0, then `rev p` in cycle 1, then loops.
palindrome :: forall a. Pattern a -> Pattern a
palindrome p = cat [p, rev p]

-- | Layer the original pattern with a transformed copy.
-- |
-- | `superimpose rev p` plays p stacked with `rev p`.
superimpose :: forall a. (Pattern a -> Pattern a) -> Pattern a -> Pattern a
superimpose f p = stack [p, f p]

-- | Layer the original pattern with a delayed, transformed copy.
-- |
-- | `off (1 % 8) (fast 2) p` overlays a sped-up p shifted right by 1/8 cycle.
off :: forall a. Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
off t f p = stack [p, rotR t (f p)]

-- | Apply a transform to a pattern slowed by n, then speed back up.
-- |
-- | `inside 2 rev p` reverses pairs of cycles instead of single cycles.
-- | Equivalent to `fast n (f (slow n p))`.
inside :: forall a. Rational -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
inside n f p = fast n (f (slow n p))

-- | Dual of `inside`: apply a transform to a pattern sped up by n, then slow back down.
outside :: forall a. Rational -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
outside n f p = slow n (f (fast n p))

-- | Scale a continuous numeric pattern from [0, 1] to [lo, hi].
-- |
-- | `range 100.0 200.0 sine` produces a sine that swings between 100 and 200.
range :: Number -> Number -> Pattern Number -> Pattern Number
range lo hi p = (\v -> v * (hi - lo) + lo) <$> p

-- | "Broken beat" — on odd cycles, squeeze the pattern into the middle half
-- | of the cycle, with silence padding either side. Even cycles play normally.
brak :: forall a. Pattern a -> Pattern a
brak = whenMod 2 (\m -> m == 1) (\p -> rotR (one / fromInt 4) (fastCat [p, silence]))

-- | Replay the first cycle of a pattern over and over.
-- |
-- | `loopFirst p` queries cycle 0 of p for every requested cycle, shifting
-- | events to the appropriate time so the pattern appears to repeat its
-- | opening cycle indefinitely.
loopFirst :: forall a. Pattern a -> Pattern a
loopFirst pat = pattern \(State st) ->
  let
    cycleArcs = splitArcByCycles st.arc

    processOneCycle cycleArc =
      let
        cyc = sam (arcStart cycleArc)
        Arc { start: qs, stop: qe } = cycleArc
        mappedArc = Arc { start: qs - cyc, stop: qe - cyc }
        events = query pat (State st { arc = mappedArc })
      in map (shiftEventTime cyc) events
  in Array.concatMap processOneCycle cycleArcs

-- | Repeat each event by overlaying n copies of the pattern, each shifted
-- | by t cycles relative to the previous one.
-- |
-- | `stutter 3 (1 % 8) p` stacks p, p shifted by 1/8, and p shifted by 2/8.
stutter :: forall a. Int -> Time -> Pattern a -> Pattern a
stutter n t p
  | n <= 0 = silence
  | n == 1 = p
  | otherwise = stack
      (map (\i -> rotR (fromInt i * t) p) (Array.range 0 (n - 1)))

-- | Repeat each event n times within its own time slot.
-- |
-- | `ply 3 (s "bd sn")` turns each "bd" and "sn" event into three rapid hits
-- | filling the same duration.
ply :: forall a. Int -> Pattern a -> Pattern a
ply n pat
  | n <= 0 = silence
  | n == 1 = pat
  | otherwise = pattern \(State st) ->
      let
        Arc q = st.arc
        events = query pat (State st)

        plyEvent (Digital e) =
          let
            Arc w = e.whole
            len = w.stop - w.start
            sub = len / fromInt n
            mkSub i =
              let
                whStart = w.start + fromInt i * sub
                whStop = whStart + sub
                pStart = max whStart q.start
                pStop = min whStop q.stop
              in if pStart >= pStop
                 then Nothing
                 else Just (Digital
                   { context: e.context
                   , whole: Arc { start: whStart, stop: whStop }
                   , part: Arc { start: pStart, stop: pStop }
                   , value: e.value
                   })
          in Array.mapMaybe mkSub (Array.range 0 (n - 1))
        plyEvent (Analog e) = [Analog e]
      in Array.concatMap plyEvent events

-- | Divide each cycle into n parts, applying f to a different part each cycle.
-- |
-- | `chunk 4 (fast 2) p` plays p with `fast 2` applied to slice 0 in cycle 0,
-- | slice 1 in cycle 1, slice 2 in cycle 2, slice 3 in cycle 3, then loops.
chunk :: forall a. Int -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
chunk n f p
  | n <= 0 = p
  | otherwise = cat (map applyAtIndex (Array.range 0 (n - 1)))
  where
    applyAtIndex i =
      let
        s = fromInt i / fromInt n
        e = fromInt (i + 1) / fromInt n
        inSlice ev =
          let t = cyclePos (eventStartTime ev)
          in t >= s && t < e
      in stack
           [ filterEvents inSlice (f p)
           , filterEvents (not <<< inSlice) p
           ]

    eventStartTime :: Event a -> Time
    eventStartTime (Digital ev) = let Arc a = ev.part in a.start
    eventStartTime (Analog ev) = let Arc a = ev.part in a.start

-- | Apply `f` only to events whose cycle position falls in the half-open slice
-- | `[s, e)`; events outside the slice pass through untouched. The predicate is
-- | tested on each event's (possibly transformed) start, so `within s e (rotR x)`
-- | keeps the shifted copies that land in the slice — the building block of
-- | `swingBy`. (Tidal's `within`, specialised to two `Time` bounds.)
within :: forall a. Time -> Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
within s e f p =
  stack
    [ filterEvents inSlice (f p)
    , filterEvents (not <<< inSlice) p
    ]
  where
    inSlice ev = let t = cyclePos (evStart ev) in t >= s && t < e
    evStart :: Event a -> Time
    evStart (Digital ev) = let Arc a = ev.part in a.start
    evStart (Analog ev) = let Arc a = ev.part in a.start

-- | Swing. Divide each cycle into `n` equal parts and nudge the *second half*
-- | of every part later by `amt` (measured in part-units), producing the
-- | long-short lilt. `swingBy (fromInt 1 / fromInt 3) (fromInt 4)` is classic
-- | triplet 8th-note swing in 4/4; `amt = 0` is dead straight.
-- |
-- | Swing is phase-locked to the cycle and deterministic, so the *same*
-- | `swingBy amt n` applied to any pattern displaces its offbeats identically.
-- | That is the property a shared groove relies on: wrap every voice that should
-- | swing with one `swingBy` and they lock to a single feel — while voices left
-- | unwrapped (and the clock itself, which is upstream of any pattern) stay
-- | straight.
swingBy :: forall a. Time -> Time -> Pattern a -> Pattern a
swingBy amt n = inside n (within half one (rotR amt))
  where
    half = fromInt 1 / fromInt 2
    one = fromInt 1

-- | `swing n = swingBy (1/3) n` — the default triplet swing, dividing the cycle
-- | into `n` parts.
swing :: forall a. Time -> Pattern a -> Pattern a
swing = swingBy (fromInt 1 / fromInt 3)

-- | `swingBy` with the amount given as the integer ratio `num/den` of a slice
-- | and the subdivision `n` as an Int — so code generators can express swing
-- | with plain integers and never need to emit `Rational` arithmetic (the
-- | division happens here, where the numeric `Prelude` is in scope).
-- | `swingByR 1 6 4` ≈ a true-triplet 8th swing; `swingByR 1 3 4` = the default
-- | hard swing. `num = 0` is straight.
swingByR :: forall a. Int -> Int -> Int -> Pattern a -> Pattern a
swingByR num den n = swingBy (fromInt num / fromInt den) (fromInt n)

-------------------------------------------------------------------------------
-- Filtering
-------------------------------------------------------------------------------

-- | Filter events by a predicate
filterEvents :: forall a. (Event a -> Boolean) -> Pattern a -> Pattern a
filterEvents pred pat = pattern \st ->
  Array.filter pred (query pat st)

-- | Keep only digital events
filterDigital :: forall a. Pattern a -> Pattern a
filterDigital = filterEvents isDigital

-- | Keep only analog events
filterAnalog :: forall a. Pattern a -> Pattern a
filterAnalog = filterEvents isAnalog

-- | Filter events by their value
filterValues :: forall a. (a -> Boolean) -> Pattern a -> Pattern a
filterValues pred = filterEvents (pred <<< eventValue)

-------------------------------------------------------------------------------
-- Pattern queries
-------------------------------------------------------------------------------

-- | Query the first cycle of a pattern (0 to 1)
firstCycle :: forall a. Pattern a -> Array (Event a)
firstCycle pat = queryArc pat zero one

-- | Query a pattern for a specific time range
queryArc :: forall a. Pattern a -> Time -> Time -> Array (Event a)
queryArc = queryArcWith Map.empty

-- | Query a pattern for a specific time range, with a caller-supplied
-- | ControlMap.  Used by the voice scheduler to thread the live
-- | control bus snapshot into pattern queries — `Tidal.LiveControl.live`
-- | reads from this map.
queryArcWith :: forall a. ControlMap -> Pattern a -> Time -> Time -> Array (Event a)
queryArcWith controls pat start stop =
  let
    arc = Arc { start, stop }
    st = State { arc, controls }
  in
    query pat st

-------------------------------------------------------------------------------
-- Oscillators (continuous patterns)
-------------------------------------------------------------------------------

-- | Tidal's `mod' x 1` on a Double: `x - fromInteger (floor x)`.
frac :: Number -> Number
frac x = x - Integer.toNumber (Double.floor x)

-- | Sine wave oscillator, 0 to 1 over each cycle
sine :: Pattern Number
sine = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    -- cyclePos gives 0-1 within cycle
    pos = frac midpoint
    -- sine from 0-1: (sin(2*pi*t) + 1) / 2
    value = (sin (2.0 * pi * pos) + 1.0) / 2.0
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Cosine wave oscillator, 0 to 1 over each cycle
cosine :: Pattern Number
cosine = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = frac midpoint
    value = (cos (2.0 * pi * pos) + 1.0) / 2.0
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Sawtooth wave, 0 to 1 rising over each cycle
saw :: Pattern Number
saw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    value = frac midpoint
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Inverse sawtooth wave, 1 to 0 falling over each cycle
isaw :: Pattern Number
isaw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    value = 1.0 - (frac midpoint)
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Triangle wave, 0 to 1 to 0 over each cycle
tri :: Pattern Number
tri = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = frac midpoint
    -- Triangle: rises 0-0.5, falls 0.5-1
    value = if pos < 0.5
            then pos * 2.0
            else 2.0 - pos * 2.0
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Square wave, 0 for first half of cycle, 1 for second half
square :: Pattern Number
square = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = frac midpoint
    value = if pos < 0.5 then 0.0 else 1.0
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Exponential ramp: rises 0 → 1 with a slow start and fast finish
-- | (`pos²`).  Modular-style "exp" curve.  Pairs with `saw` (linear)
-- | and `logSaw` (concave-down).
expSaw :: Pattern Number
expSaw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = frac midpoint
    value = pos * pos
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Inverse exponential: falls 1 → 0 with a fast start and slow tail
-- | (`(1-pos)²`).  Useful as a percussion-style decay envelope at LFO
-- | rates — `range 0.2 1.0 (slow 4 iexpSaw)` is a slow filter pluck.
iexpSaw :: Pattern Number
iexpSaw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = frac midpoint
    inv = 1.0 - pos
    value = inv * inv
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Logarithmic ramp: rises 0 → 1 with a fast start and slow approach
-- | (`sqrt(pos)`).  Modular-style "log" curve — concave-down.
logSaw :: Pattern Number
logSaw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = frac midpoint
    value = sqrt pos
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Inverse logarithmic: falls 1 → 0 with a slow start and fast finish
-- | (`1 - sqrt(pos)`).  Mirror of `logSaw`.
ilogSaw :: Pattern Number
ilogSaw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = frac midpoint
    value = 1.0 - sqrt pos
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Haskell Tidal's `rand`: one analog event per query, its value
-- | `timeToRand` of the query's start, so it is a function of time alone.
rand :: Pattern Number
rand = pattern \(State st) ->
  [ Analog { context: emptyContext, part: st.arc, value: timeToRand (arcStart st.arc) } ]

-- | Haskell Tidal's `irand`: `floor (rand * n)`.
irand :: Int -> Pattern Int
irand n = map (\x -> Int.floor (x * Int.toNumber n)) rand

-------------------------------------------------------------------------------
-- Haskell Tidal's machinery (Sound.Tidal.Pattern, Core, UI; 1.10.1)
-------------------------------------------------------------------------------

mapArc :: (Time -> Time) -> Arc -> Arc
mapArc f (Arc a) = Arc { start: f a.start, stop: f a.stop }

-- | Apply a function to every whole and part a pattern returns.
withResultArc :: forall a. (Arc -> Arc) -> Pattern a -> Pattern a
withResultArc f pat = pattern \st -> map onEvent (query pat st)
  where
  onEvent = case _ of
    Digital e -> Digital e { whole = f e.whole, part = f e.part }
    Analog e -> Analog e { part = f e.part }

withResultTime :: forall a. (Time -> Time) -> Pattern a -> Pattern a
withResultTime f = withResultArc (mapArc f)

withQueryTime :: forall a. (Time -> Time) -> Pattern a -> Pattern a
withQueryTime f pat = pattern \(State st) -> query pat (State st { arc = mapArc f st.arc })

-- | An arc cut at cycle boundaries; a zero-width arc is kept as it is.
arcCyclesZW :: Arc -> Array Arc
arcCyclesZW (Arc a)
  | a.start == a.stop = [ Arc a ]
  | otherwise = arcCycles (Arc a)

arcCycles :: Arc -> Array Arc
arcCycles (Arc a) =
  if a.start >= a.stop then []
  else if sam a.start == sam a.stop then [ Arc a ]
  else Array.cons (Arc a { stop = nextSam a.start }) (arcCycles (Arc a { start = nextSam a.start }))

-- | Query cycle by cycle, so a pattern can assume no query spans cycles.
splitQueries :: forall a. Pattern a -> Pattern a
splitQueries pat = pattern \(State st) ->
  Array.concatMap (\a -> query pat (State st { arc = a })) (arcCyclesZW st.arc)

-- | Patterns side by side in one cycle, each given its share of the time:
-- | Haskell Tidal's `timeCat`, what a mini-notation sequence becomes.
timeCat :: forall a. Array (Tuple Time (Pattern a)) -> Pattern a
timeCat [ Tuple _ p ] = p
timeCat tps =
  stack (arrange zero (Array.filter (\(Tuple t _) -> t > zero) tps))
  where
  total = foldl (\acc (Tuple t _) -> acc + t) zero tps
  arrange from = Array.uncons >>> case _ of
    Nothing -> []
    Just { head: Tuple t p, tail } ->
      Array.cons (compress (from / total) ((from + t) / total) p) (arrange (from + t) tail)

-- | A pattern of patterns, with structure from the inner patterns only:
-- | Haskell Tidal's `innerJoin`, behind every patterned argument.
innerJoin :: forall a. Pattern (Pattern a) -> Pattern a
innerJoin pp = pattern \st@(State s) ->
  Array.concatMap
    (\oe -> Array.mapMaybe (munge s.arc oe) (query (eventValue oe) (State s { arc = eventPart oe })))
    (query pp st)
  where
  munge qarc oe ie = do
    p <- subArc qarc (eventPart ie)
    p' <- subArc p qarc
    pure case ie of
      Digital i -> Digital i { part = p', context = i.context <> eventContext' oe }
      Analog i -> Analog i { part = p', context = i.context <> eventContext' oe }
  eventContext' = case _ of
    Digital e -> e.context
    Analog e -> e.context

-- | Haskell Tidal's `uncollect`: an event holding a list becomes one event
-- | per value, with the same whole and part (how a chord sounds).
uncollect :: forall a. Pattern (Array a) -> Pattern a
uncollect pat = pattern \st ->
  Array.concatMap (\e -> map (\v -> mapEventValue (const v) e) (eventValue e)) (query pat st)

-- | Haskell Tidal's `unwrap`; also this library's `bind`.
unwrap :: forall a. Pattern (Pattern a) -> Pattern a
unwrap pp = pp >>= identity

-- | A function of a value, patterned: Haskell's `patternify`, without its
-- | shortcut for a pure argument (callers that know the argument is
-- | constant call the function directly).
patternify :: forall t a. (t -> Pattern a -> Pattern a) -> Pattern t -> Pattern a -> Pattern a
patternify f pt p = innerJoin (map (\t -> f t p) pt)

-- | Haskell Tidal's `range`, `(\from to v -> v * (to - from) + from) <$>
-- | fromP *> toP *> p`: structure from the values.
rangeBy :: Number -> Number -> Pattern Number -> Pattern Number
rangeBy from to p = applyRight (applyRight (map (\_ _ v -> v * (to - from) + from) (pure from)) (pure to)) p

-- | Haskell Tidal's `chooseBy`: a value from the list, picked by a
-- | pattern of numbers in [0, 1).
chooseBy :: forall a. Pattern Number -> Array a -> Pattern a
chooseBy f xs = case Array.length xs of
  0 -> silence
  n -> map (\x -> pick (floorMod (Int.floor x) n)) (rangeBy 0.0 (Int.toNumber n) f)
  where
  pick i = case Array.index xs i of
    Just v -> v
    Nothing -> unsafeCrashWith "chooseBy: the index is reduced modulo the length"

-- | Haskell Tidal's `_degradeByUsing`: keep the events where the random
-- | pattern, sampled with structure from the events, is at least x.
degradeByUsing :: forall a. Pattern Number -> Number -> Pattern a -> Pattern a
degradeByUsing prand x p =
  map fst (filterValues (\(Tuple _ r) -> r >= x) (applyLeft (map Tuple p) prand))

-- | Haskell Tidal's `_euclid`: n pulses spread over k steps (Bjorklund);
-- | a negative n plays the gaps instead.
euclid :: forall a. Int -> Int -> Pattern a -> Pattern a
euclid n k a
  | n >= 0 = fastCat (map (\b -> if b then a else silence) (bjorklund n k))
  | otherwise = fastCat (map (\b -> if b then silence else a) (bjorklund (negate n) k))

-- | Haskell Tidal's `_euclidOff`: `euclid`, turned left by s steps.
euclidOff :: forall a. Int -> Int -> Int -> Pattern a -> Pattern a
euclidOff n k s p
  | k == 0 = silence
  | otherwise = rotL (fromInt s / fromInt k) (euclid n k p)

-- | Haskell Tidal's Bjorklund (Rohan Drape's, in Sound.Tidal.Bjorklund).
bjorklund :: Int -> Int -> Array Boolean
bjorklund i j' =
  let
    j = j' - i
    { xs, ys } = go i j (Array.replicate i [ true ]) (Array.replicate j [ false ])
  in
    Array.concat xs <> Array.concat ys
  where
  go a b xs ys
    | min a b <= 1 = { xs, ys }
    | a > b =
        let
          xs' = Array.take b xs
          xs'' = Array.drop b xs
        in
          go b (a - b) (zipConcat xs' ys) xs''
    | otherwise =
        let
          ys' = Array.take a ys
          ys'' = Array.drop a ys
        in
          go a (b - a) (zipConcat xs ys') ys''
  -- `zipWith (++)`, truncating to the shorter, as Haskell's does. Not
  -- Data.Array.zipWith: on Erlang 28 that crashes on unequal lengths.
  zipConcat as bs =
    let m = min (Array.length as) (Array.length bs)
    in
      if m == 0 then []
      else map (\k -> fromArr (Array.index as k) <> fromArr (Array.index bs k)) (Array.range 0 (m - 1))
  fromArr = case _ of
    Just v -> v
    Nothing -> []

-------------------------------------------------------------------------------
-- Internal utilities
-------------------------------------------------------------------------------

-- | Split an arc into per-cycle chunks
splitArcByCycles :: Arc -> Array Arc
splitArcByCycles (Arc { start, stop }) =
  let
    startCycle = sam start
    go acc s =
      if s >= stop then acc
      else
        let cycleEnd = s + one
            arcEnd = min stop cycleEnd
            arcStart' = max start s
        in go (acc <> [Arc { start: arcStart', stop: arcEnd }]) cycleEnd
  in go [] startCycle

-- | The silent pattern (re-exported from Types but useful here)
silence :: forall a. Pattern a
silence = pattern \_ -> []

-- | Coerce a `Pattern String` into a `Pattern Number` by parsing each
-- | event's value as a number.  Tokens that don't parse become `0.0`
-- | (silence-equivalent for CC / continuous CV — a `~` rest in the
-- | source mini-notation never reaches this fmap because the parser
-- | filters rest events out before producing the Pattern).
-- |
-- | Legacy helper for the bare-mini parse path; the typed-cue path
-- | uses `patternPitchToNumber` instead.
patternStringToNumber :: Pattern String -> Pattern Number
patternStringToNumber = map parseOrZero
  where
  parseOrZero s = case Number.fromString s of
    Just n -> n
    Nothing -> 0.0
