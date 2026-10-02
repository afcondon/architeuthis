-- | **A Tidal stream to SuperDirt: `d1`..`d16`, timed as Tidal times them.**
-- |
-- | The pure half of `tidal_dirt_voice`. On each clock tick it is handed the
-- | window (`tidal_clock`'s, the same every voice hears) and returns the
-- | `/dirt/play` messages to send, each with the wall-clock instant it should
-- | sound. Haskell Tidal's rules, from `Sound.Tidal.Stream.Process`:
-- |
-- | - the arc queried each tick begins where the last one ended, so no event
-- |   is sent twice and none is skipped;
-- | - only events whose onset falls in that arc are sent (`peHasOnset`), so a
-- |   long event is played once, at its start;
-- | - a message carries every control in the event, plus `cps`, `cycle` (the
-- |   onset), `delta` (the whole's length in seconds) and `_id_` (the stream's
-- |   number), the event's own values winning; keys go in map order;
-- | - it goes as a timetagged bundle, so SuperDirt plays it on time rather
-- |   than on arrival.
-- |
-- | A new pattern is heard from the next arc: there is no backlog to drain.
-- | When the clock jumps (Link's free-run to sync hand-over, a BPM change),
-- | the arc snaps to the present, and what fell in the gap is dropped, as
-- | `tidal_step_window` does for the step voices: late is worse than never.
-- |
-- | The timetag is the onset itself, as the rig's other SuperDirt voice
-- | (Conspicillum's) stamps it. Haskell Tidal adds a 0.2 s latency; whether
-- | the rig should is a question for the ear, with both engines on Link.
module Tidal.DirtVoice
  ( State
  , Window
  , Message
  , initialState
  , setPattern
  , computeUntil
  , Onset
  , onsetsUntil
  ) where

import Prelude

import Data.Array (mapMaybe)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Haskell.Rational (Rational, fromInt, toNumber)
import Data.Tuple (Tuple(..))
import Foreign (Foreign, unsafeToForeign)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), ControlPattern, arcStart, Event(..), Value(..), ValueMap, silence)

type State =
  { stream :: Int
  , pattern :: ControlPattern
  -- Where the last arc ended; `Nothing` before the first tick.
  , until :: Maybe Rational
  }

-- | The clock's window, as `tidal_clock` sends it (it carries more fields;
-- | these are the ones a stream needs).
type Window =
  { currentCycle :: Number
  , lookAheadCycle :: Number
  , cycleDurationMs :: Number
  , nowUnixUs :: Number
  }

-- | One `/dirt/play`: when it should sound, and its arguments as
-- | alternating names and values (binaries, floats, integers), ready for
-- | `dirt_osc:encode_msg`.
type Message = { atUnixUs :: Number, args :: Array Foreign }

initialState :: Int -> State
initialState stream = { stream, pattern: silence, until: Nothing }

setPattern :: ControlPattern -> State -> State
setPattern pattern st = st { pattern = pattern }

computeUntil :: Window -> State -> { newState :: State, messages :: Array Message }
computeUntil w st =
  let r = onsetsUntil w st
  in { newState: r.newState, messages: map message r.onsets }
  where
  message o =
    let
      extras = Map.fromFoldable
        [ Tuple "_id_" (VString (show st.stream))
        , Tuple "cps" (VNumber o.cps)
        , Tuple "cycle" (VNumber o.cycle)
        , Tuple "delta" (VNumber o.deltaS)
        ]
    in { atUnixUs: o.atUnixUs, args: oscArgs (Map.union o.value extras) }

-- | One event that begins in the window: when it sounds, its cycle, its
-- | length in seconds, and its controls.
type Onset = { atUnixUs :: Number, cps :: Number, cycle :: Number, deltaS :: Number, value :: ValueMap }

-- | The events that begin between where the last window ended and the
-- | window's look-ahead, with the timing rules above. `computeUntil` makes
-- | `/dirt/play` messages of them; the drum stream (`Tidal.DrumVoice`) makes
-- | drum hits.
onsetsUntil :: Window -> State -> { newState :: State, onsets :: Array Onset }
onsetsUntil w st =
  let
    now = toCycle w.currentCycle
    to = toCycle w.lookAheadCycle
    -- Resume where the last arc ended, unless the clock has jumped: more
    -- than a cycle behind, or ahead of where the window now reaches.
    from = case st.until of
      Just u | u <= to && u >= now - one -> u
      _ -> now
    events = if from < to then queryArc st.pattern from to else []
    cps = 1000.0 / w.cycleDurationMs
  in
    { newState: st { until = Just (max from to) }
    , onsets: mapMaybe (onset cps) events
    }
  where
  onset cps = case _ of
    Digital e | arcStart e.whole == arcStart e.part ->
      let
        Arc whole = e.whole
        start = toNumber whole.start
      in
        Just
          { atUnixUs: w.nowUnixUs + (start - w.currentCycle) * w.cycleDurationMs * 1000.0
          , cps
          , cycle: start
          , deltaS: toNumber (whole.stop - whole.start) / cps
          , value: e.value
          }
    _ -> Nothing

-- | Microcycle precision, as `Tidal.Voice` converts the clock's cycles.
toCycle :: Number -> Rational
toCycle c = fromInt (Int.floor (c * 1000000.0)) / fromInt 1000000

oscArgs :: ValueMap -> Array Foreign
oscArgs m = Map.toUnfoldable m >>= \(Tuple k v) -> [ unsafeToForeign k, datum v ]
  where
  datum = case _ of
    VString x -> unsafeToForeign x
    VNumber x -> unsafeToForeign x
    VNote x -> unsafeToForeign x
    VRational r -> unsafeToForeign (toNumber r)
    VInt i -> unsafeToForeign i
    VBool b -> unsafeToForeign (if b then 1 else 0)
