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
  , whenMod
  , iter
  , iter'
  , linger
  , trunc
  , steptake
  , stepdrop
    -- * Oscillators (continuous patterns)
  , sine
  , cosine
  , saw
  , isaw
  , tri
  , square
  , rand
  , irand
    -- * Filtering and selection
  , filterEvents
  , filterDigital
  , filterAnalog
  , filterValues
    -- * Pattern queries
  , firstCycle
  , queryArc
    -- * Time utilities
  , sam
  , nextSam
  , cyclePos
  , wholeCycle
    -- * Arc operations (re-exported)
  , module ArcExports
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Ord (comparing)
import Data.Rational (Rational, fromInt, toNumber)
import Math (cos, floor, pi, sin)
import Tidal.Core.Types (Time)
import Tidal.Pattern.Types
  ( Arc(..)
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
  , Context
  , Event(..)
  , Pattern
  , State(..)
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
floorTime t = fromInt (Int.floor (toNumber t))

-------------------------------------------------------------------------------
-- Time manipulation
-------------------------------------------------------------------------------

-- | Speed up a pattern by a factor
-- |
-- | `fast 2 p` plays pattern `p` twice as fast
-- | `fast 0.5 p` plays at half speed (same as `slow 2 p`)
fast :: forall a. Rational -> Pattern a -> Pattern a
fast rate pat
  | rate == zero = silence
  | rate < zero = fast (negate rate) (rev pat)
  | otherwise = pattern \(State st) ->
      let
        -- Query a larger arc (scaled by rate)
        scaledArc = scaleArc rate st.arc
        events = query pat (State st { arc = scaledArc })
      in
        -- Scale the results back
        map (scaleEventTime (one / rate)) events

-- | Slow down a pattern by a factor
-- |
-- | `slow 2 p` plays pattern `p` at half speed
slow :: forall a. Rational -> Pattern a -> Pattern a
slow rate pat
  | rate == zero = silence
  | otherwise = fast (one / rate) pat

-- | Scale an arc's times by a factor
scaleArc :: Rational -> Arc -> Arc
scaleArc factor (Arc { start, stop }) =
  Arc { start: start * factor, stop: stop * factor }

-- | Scale an event's times by a factor
scaleEventTime :: forall a. Rational -> Event a -> Event a
scaleEventTime factor = case _ of
  Digital e -> Digital e
    { whole = scaleArc factor e.whole
    , part = scaleArc factor e.part
    }
  Analog e -> Analog e
    { part = scaleArc factor e.part
    }

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

-- | Reverse a pattern within each cycle
rev :: forall a. Pattern a -> Pattern a
rev pat = pattern \(State st) ->
  let
    -- Split query into per-cycle queries
    cycleArcs = splitArcByCycles st.arc

    processOneCycle :: Arc -> Array (Event a)
    processOneCycle cycleArc =
      let
        -- Mirror the query arc within the cycle
        cyc = sam (arcStart cycleArc)
        mirrorTime t = cyc + (one - (t - cyc))
        mirroredArc = Arc
          { start: mirrorTime (arcStop cycleArc)
          , stop: mirrorTime (arcStart cycleArc)
          }
        events = query pat (State st { arc = mirroredArc })
      in
        map (mirrorEvent cyc) events

    mirrorEvent :: Time -> Event a -> Event a
    mirrorEvent cyc = case _ of
      Digital e -> Digital e
        { whole = mirrorArc cyc e.whole
        , part = mirrorArc cyc e.part
        }
      Analog e -> Analog e
        { part = mirrorArc cyc e.part
        }

    mirrorArc :: Time -> Arc -> Arc
    mirrorArc cyc (Arc { start, stop }) =
      let mirrorT t = cyc + (one - (t - cyc))
      in Arc { start: mirrorT stop, stop: mirrorT start }
  in
    Array.concatMap processOneCycle cycleArcs

-------------------------------------------------------------------------------
-- Pattern structure
-------------------------------------------------------------------------------

-- | Concatenate patterns, playing each in sequence
-- |
-- | Each pattern gets one cycle, then speeds up to fit in one total cycle.
-- | `cat [a, b, c]` plays a in cycle 0, b in cycle 1, c in cycle 2,
-- | then repeats (with each pattern taking 1/3 of a cycle).
cat :: forall a. Array (Pattern a) -> Pattern a
cat [] = silence
cat pats = pattern \(State st) ->
  let
    n = Array.length pats
    -- Which cycle(s) are we querying?
    cycleArcs = splitArcByCycles st.arc

    processOneCycle :: Arc -> Array (Event a)
    processOneCycle cycleArc =
      let
        cyc = sam (arcStart cycleArc)
        -- Which pattern in this cycle?
        patIdx = mod (floorInt cyc) n
        -- Get the pattern
        mPat = Array.index pats patIdx
      in
        case mPat of
          Nothing -> []
          Just p -> query p (State st { arc = cycleArc })
  in
    Array.concatMap processOneCycle cycleArcs
  where
    floorInt :: Time -> Int
    floorInt t = Int.floor (toNumber t)

-- | Fast concatenation - all patterns fit in one cycle
-- |
-- | `fastCat [a, b, c]` compresses all patterns into one cycle,
-- | each taking 1/n of the cycle.
fastCat :: forall a. Array (Pattern a) -> Pattern a
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

-- | Segment a pattern into n equal events per cycle
-- |
-- | `segment 4 pat` discretizes the pattern into 4 events per cycle,
-- | sampling the pattern at each step.
segment :: forall a. Int -> Pattern a -> Pattern a
segment n pat
  | n <= 0 = silence
  | otherwise = pattern \(State st) ->
      let
        rate = fromInt n
        cycleArcs = splitArcByCycles st.arc

        processOneCycle :: Arc -> Array (Event a)
        processOneCycle cycleArc =
          let
            cyc = sam (arcStart cycleArc)
            -- Generate n sample points
            indices = Array.range 0 (n - 1)
            sampleAt i =
              let
                t = cyc + (fromInt i / rate)
                tNext = cyc + (fromInt (i + 1) / rate)
                sampleArc = Arc { start: t, stop: tNext }
                -- Only include if it overlaps our query
              in if arcOverlaps sampleArc cycleArc
                 then
                   -- Query at this instant
                   case Array.head (query pat (State { arc: Arc { start: t, stop: t + one / (rate * fromInt 100) }, controls: st.controls })) of
                     Nothing -> []
                     Just evt -> [ Digital { context: getContext evt, whole: sampleArc, part: sectArc sampleArc cycleArc, value: eventValue evt } ]
                 else []
          in Array.concatMap sampleAt indices
      in Array.concatMap processOneCycle cycleArcs
  where
    getContext :: Event a -> Context
    getContext (Digital e) = e.context
    getContext (Analog e) = e.context

    sectArc :: Arc -> Arc -> Arc
    sectArc (Arc a) (Arc b) =
      Arc { start: max a.start b.start, stop: min a.stop b.stop }

    arcOverlaps :: Arc -> Arc -> Boolean
    arcOverlaps (Arc a) (Arc b) = a.start < b.stop && b.start < a.stop

-- | Compress a pattern into a portion of each cycle
-- |
-- | `compress (0.25, 0.75) pat` squeezes the pattern into the middle half
-- | of each cycle.
compress :: forall a. Time -> Time -> Pattern a -> Pattern a
compress s e pat
  | s >= e = silence
  | otherwise = pattern \(State st) ->
      let
        scale = e - s
        -- Transform query time back to pattern time
        cycleArcs = splitArcByCycles st.arc

        processOneCycle :: Arc -> Array (Event a)
        processOneCycle cycleArc =
          let
            cyc = sam (arcStart cycleArc)
            compressedStart = cyc + s
            compressedEnd = cyc + e

            -- Check if query overlaps the compressed region
            Arc { start: qStart, stop: qStop } = cycleArc
          in if qStart >= compressedEnd || qStop <= compressedStart
             then []
             else
               let
                 -- Map query into pattern time (0-1)
                 patStart = (max qStart compressedStart - compressedStart) / scale
                 patStop = (min qStop compressedEnd - compressedStart) / scale
                 patArc = Arc { start: cyc + patStart, stop: cyc + patStop }

                 events = query pat (State st { arc = patArc })

                 -- Map events back to compressed time
                 mapEvent = case _ of
                   Digital ev ->
                     let
                       Arc w = ev.whole
                       Arc p = ev.part
                     in Digital ev
                          { whole = Arc { start: compressedStart + (w.start - cyc) * scale
                                        , stop: compressedStart + (w.stop - cyc) * scale
                                        }
                          , part = Arc { start: compressedStart + (p.start - cyc) * scale
                                       , stop: compressedStart + (p.stop - cyc) * scale
                                       }
                          }
                   Analog ev ->
                     let Arc p = ev.part
                     in Analog ev
                          { part = Arc { start: compressedStart + (p.start - cyc) * scale
                                       , stop: compressedStart + (p.stop - cyc) * scale
                                       }
                          }
               in map mapEvent events
      in Array.concatMap processOneCycle cycleArcs

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

-- | Apply a function every n cycles
-- |
-- | `every 4 rev pat` reverses the pattern every 4th cycle
every :: forall a. Int -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
every n f pat
  | n <= 0 = pat
  | otherwise = pattern \(State st) ->
      let
        cycleArcs = splitArcByCycles st.arc
        processOneCycle cycleArc =
          let
            cyc = floorInt (sam (arcStart cycleArc))
            shouldApply = mod cyc n == 0
            p = if shouldApply then f pat else pat
          in query p (State st { arc = cycleArc })
      in Array.concatMap processOneCycle cycleArcs
  where
    floorInt t = Int.floor (toNumber t)

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
    floorInt t = Int.floor (toNumber t)

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
    floorInt t = Int.floor (toNumber t)

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
    floorInt t = Int.floor (toNumber t)

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
queryArc pat start stop =
  let
    arc = Arc { start, stop }
    st = State { arc, controls: Map.empty }
  in
    query pat st

-------------------------------------------------------------------------------
-- Oscillators (continuous patterns)
-------------------------------------------------------------------------------

-- | Sine wave oscillator, 0 to 1 over each cycle
sine :: Pattern Number
sine = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    -- cyclePos gives 0-1 within cycle
    pos = midpoint - floor midpoint
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
    pos = midpoint - floor midpoint
    value = (cos (2.0 * pi * pos) + 1.0) / 2.0
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Sawtooth wave, 0 to 1 rising over each cycle
saw :: Pattern Number
saw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    value = midpoint - floor midpoint
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Inverse sawtooth wave, 1 to 0 falling over each cycle
isaw :: Pattern Number
isaw = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    value = 1.0 - (midpoint - floor midpoint)
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Triangle wave, 0 to 1 to 0 over each cycle
tri :: Pattern Number
tri = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    pos = midpoint - floor midpoint
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
    pos = midpoint - floor midpoint
    value = if pos < 0.5 then 0.0 else 1.0
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Pseudorandom values 0 to 1, deterministic based on cycle position
-- | Uses a simple hash function for repeatability
rand :: Pattern Number
rand = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    -- Simple hash: multiply by large prime, take fractional part
    hash = midpoint * 15485863.0
    value = hash - floor hash
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Random integers from 0 to n-1
irand :: Int -> Pattern Int
irand n = pattern \(State st) ->
  let
    Arc { start, stop } = st.arc
    midpoint = toNumber $ (start + stop) / fromInt 2
    hash = midpoint * 15485863.0
    frac = hash - floor hash
    value = Int.floor (frac * Int.toNumber n)
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

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
