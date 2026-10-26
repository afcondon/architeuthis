-- | **A Selene POLYVOLT bank's outputs stepped on the clock: `# volts 3 "<0 1.2 2.5>"`.**
-- |
-- | The pure half of a volt stream (`tidal_dirt_voice`, stream
-- | `{volts, Socket, Bank}`, kept in step with the rack by `selene_mutes`),
-- | one per bank, holding each patterned output's pattern. A pattern is read
-- | as `n "<pattern>"`, so a value is a voltage (a trailing `V` is taken off
-- | before it is read). An output moves at each onset to that event's
-- | voltage and holds it, through a rest, until the next: a step sequencer,
-- | not a gate (AC, 2026-10-26: stepping Obsidian's MODEL from Selene).
-- |
-- | The window is timed as `Tidal.MuteVoice`'s: it begins where the last
-- | ended, and snaps to the present when the clock jumps.
module Tidal.VoltVoice
  ( State
  , Change
  , Held
  , initialState
  , setPatterns
  , computeVolts
  , voltsAt
  ) where

import Prelude

import Data.Array (any, concatMap, filter, foldl, last, mapMaybe, nub, sort, sortBy)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Haskell.Rational (Rational, fromInt, toNumber)
import Tidal.DirtVoice (Window)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), ControlPattern, Event(..), Value(..))

-- | An output's voltage, 1-based.
type Held = { slot :: Int, volts :: Number }

type State =
  { patterns :: Array { slot :: Int, pattern :: ControlPattern }
  -- | where the last window ended; `Nothing` before the first
  , until :: Maybe Rational
  -- | each patterned output's voltage as last said, so a change is said once
  , volts :: Array Held
  }

-- | From `atUnixUs` on, the patterned outputs hold these voltages.
type Change = { atUnixUs :: Number, volts :: Array Held }

initialState :: State
initialState = { patterns: [], until: Nothing, volts: [] }

-- | New patterns are heard from the next window; a voltage held is kept
-- | until the new pattern's next onset says otherwise.
setPatterns :: Array { slot :: Int, pattern :: ControlPattern } -> State -> State
setPatterns patterns st = st { patterns = patterns, volts = filter (\h -> any (\p -> p.slot == h.slot) patterns) st.volts }

computeVolts :: Window -> State -> { newState :: State, changes :: Array Change }
computeVolts w st =
  let
    now = toCycle w.currentCycle
    to = toCycle w.lookAheadCycle
    from = case st.until of
      Just u | u <= to && u >= now - oneCycle -> u
      _ -> now
    -- a stream that has just started, or whose clock jumped, takes up what
    -- each pattern holds at the window's start
    start = case st.until of
      Just u | u == from -> st.volts
      _ -> voltsAtCycle st.patterns from
    onsets = if from < to then concatMap (\p -> map (\o -> { at: o.at, slot: p.slot, volts: o.volts }) (onsetsIn p.pattern from to)) st.patterns else []
    moments = sort (nub (map _.at onsets))
    step acc t =
      let
        here = filter (\o -> o.at == t) onsets
        vs = foldl (\held o -> setHeld o.slot o.volts held) acc.held here
      in
        if vs == acc.held then acc else { held: vs, changes: acc.changes <> [ { atUnixUs: at t, volts: vs } ] }
    first = if start /= st.volts then [ { atUnixUs: at from, volts: start } ] else []
    done = foldl step { held: start, changes: first } moments
  in
    { newState: st { until = Just (max from to), volts = done.held }
    , changes: done.changes
    }
  where
  at t = w.nowUnixUs + (toNumber t - w.currentCycle) * w.cycleDurationMs * 1000.0

-- | What each pattern holds at a cycle: the voltage of its latest onset at
-- | or before it, looking back as far as 16 cycles. What a line's new
-- | pattern holds the moment it is evaluated, so the bank it sends is never
-- | at the wrong voltage.
voltsAt :: Array { slot :: Int, pattern :: ControlPattern } -> Number -> Array Held
voltsAt patterns c = voltsAtCycle patterns (toCycle c)

voltsAtCycle :: Array { slot :: Int, pattern :: ControlPattern } -> Rational -> Array Held
voltsAtCycle patterns t = sortBy (comparing _.slot) (mapMaybe held patterns)
  where
  held p = map (\o -> { slot: p.slot, volts: o.volts })
    (last (sortBy (comparing _.at) (filter (\o -> o.at <= t) (onsetsIn p.pattern (t - fromInt 16) (t + fromInt 1 / fromInt 1000000)))))

-- | Each onset in an arc, with its voltage.
onsetsIn :: ControlPattern -> Rational -> Rational -> Array { at :: Rational, volts :: Number }
onsetsIn pattern from to = mapMaybe onset (queryArc pattern from to)
  where
  onset = case _ of
    Digital e ->
      let
        Arc whole = e.whole
        Arc part = e.part
      in
        if whole.start == part.start && whole.start >= from && whole.start < to then map (\v -> { at: whole.start, volts: v }) (voltOf (Map.lookup "n" e.value)) else Nothing
    _ -> Nothing
  voltOf = case _ of
    Just (VNote v) -> Just v
    Just (VNumber v) -> Just v
    Just (VInt i) -> Just (Int.toNumber i)
    _ -> Nothing

setHeld :: Int -> Number -> Array Held -> Array Held
setHeld k v held = sortBy (comparing _.slot) (filter (\h -> h.slot /= k) held <> [ { slot: k, volts: v } ])

oneCycle :: Rational
oneCycle = fromInt 1

-- | Microcycle precision, as `Tidal.DirtVoice` converts the clock's cycles.
toCycle :: Number -> Rational
toCycle c = fromInt (Int.floor (c * 1000000.0)) / fromInt 1000000
