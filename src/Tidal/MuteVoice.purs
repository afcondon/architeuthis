-- | **A Selene bank's outputs muted on the clock: `# mute "<~ 1 [1,2] 2>"`.**
-- |
-- | The pure half of a mute stream (`tidal_dirt_voice`, stream
-- | `{mutes, Socket, Bank}`, kept in step with the rack by `selene_mutes`).
-- | The pattern is read as `s "<pattern>"`, so a token is a word: `1`..`8` is
-- | that slot of the bank, `all` is every slot. At any moment the slots muted
-- | are those named by the events in force then; `~` names none, so nothing
-- | is muted there.
-- |
-- | Where a retrig fires on onsets alone, a mute holds for its event's
-- | length, so this reads each window for every moment the muted set can
-- | change (an event beginning or ending) and gives each change once, with
-- | when it falls. The window is timed as `d1`..`d16` are
-- | (`Tidal.DirtVoice.onsetsUntil`): it begins where the last ended, and
-- | snaps to the present when the clock jumps.
module Tidal.MuteVoice
  ( State
  , Change
  , initialState
  , setPattern
  , computeMutes
  ) where

import Prelude

import Data.Array (concatMap, filter, mapMaybe, nub, range, sort)
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Haskell.Rational (Rational, fromInt, toNumber)
import Tidal.DirtVoice (Window)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), ControlPattern, Event(..), Value(..), silence)

type State =
  { pattern :: ControlPattern
  -- | where the last window ended; `Nothing` before the first
  , until :: Maybe Rational
  -- | the slots muted as last said, so a change is said once
  , muted :: Array Int
  }

-- | From `atUnixUs` on, these slots (1-based, sorted) are muted.
type Change = { atUnixUs :: Number, muted :: Array Int }

initialState :: State
initialState = { pattern: silence, until: Nothing, muted: [] }

setPattern :: ControlPattern -> State -> State
setPattern pattern st = st { pattern = pattern }

computeMutes :: Window -> State -> { newState :: State, changes :: Array Change }
computeMutes w st =
  let
    now = toCycle w.currentCycle
    to = toCycle w.lookAheadCycle
    from = case st.until of
      Just u | u <= to && u >= now - one -> u
      _ -> now
    events = if from < to then mapMaybe held (queryArc st.pattern from to) else []
    -- every moment in the window the set can change: its start, and each
    -- event's beginning and end inside it
    moments = sort (nub ([ from ] <> filter (\t -> t > from && t < to) (concatMap (\e -> [ e.start, e.stop ]) events)))
    mutedAt t = sort (nub (concatMap _.slots (filter (\e -> e.start <= t && t < e.stop) events)))
    step acc t =
      let m = mutedAt t
      in if m == acc.last then acc else { last: m, changes: acc.changes <> [ { atUnixUs: at t, muted: m } ] }
    done = if from < to then foldl step { last: st.muted, changes: [] } moments else { last: st.muted, changes: [] }
  in
    { newState: st { until = Just (max from to), muted = done.last }
    , changes: done.changes
    }
  where
  at t = w.nowUnixUs + (toNumber t - w.currentCycle) * w.cycleDurationMs * 1000.0
  -- an event's part (what of it falls in the window) and the slots it names
  held = case _ of
    Digital e ->
      let Arc part = e.part
      in case slotsOf (Map.lookup "s" e.value) of
           [] -> Nothing
           slots -> Just { start: part.start, stop: part.stop, slots }
    _ -> Nothing
  slotsOf = case _ of
    Just (VString "all") -> range 1 8
    Just (VString s) -> oneSlot (Int.fromString s)
    Just (VInt i) -> oneSlot (Just i)
    _ -> []
  oneSlot = case _ of
    Just n | n >= 1 && n <= 8 -> [ n ]
    _ -> []

-- | Microcycle precision, as `Tidal.DirtVoice` converts the clock's cycles.
toCycle :: Number -> Rational
toCycle c = fromInt (Int.floor (c * 1000000.0)) / fromInt 1000000
