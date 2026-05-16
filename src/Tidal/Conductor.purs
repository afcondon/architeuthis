-- | Tidal.Conductor — the section-firing tick.
-- |
-- | A `Section` (defined in Calypso.Prelude) is `Pattern AnyCue`:
-- | each event of the outer pattern carries a typed cue body and
-- | the mvoice name to arm it on.  This module exposes the per-tick
-- | query mirrored on `Tidal.Voice.computeDiscrete` and the BEAM-side
-- | `tidal_conductor` calls it on each clock tick.
-- |
-- | An ArmCommand is the per-event surface returned to the BEAM —
-- | wall-time, mvoice name, and a `Pattern Pitch` body suitable for
-- | the same dispatch path that the `play-armed` WS verb uses.
-- | Today the BEAM fires arms as it sees them; the wallTimeUs is
-- | preserved so a future cycle-accurate scheduler can use it.
module Tidal.Conductor
  ( State
  , initialState
  , ArmCommand
  , TickResult
  , conductorTick
  ) where

import Prelude

import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt)
import Data.Rational as R

import Calypso.Prelude (AnyCue(..), Channel, Section)
import Tidal.Pattern.Core (queryArcWith)
import Tidal.Pattern.Types
  ( Event
  , eventValue
  , eventWhole
  , eventPart
  , Arc(..)
  )
import Tidal.Pitch (Pitch)
import Tidal.Pattern.Types (Pattern)
import Tidal.Voice (Window) as TV

-- | One arm command surfaced to the BEAM.  Wall time is the precise
-- | moment the arm "should" land; today the BEAM fires arms as it
-- | sees them, but a future scheduler can use this field.
-- |
-- | `destination` carries the cue's bound channel (a `Channel` value
-- | like `bass1` / `qd1`); the BEAM-side `tidal_session_walker` keeps
-- | an ETS map from Channel → binding name, which the conductor uses
-- | to find the right voice supervisor.  `mvoice` is the type-level
-- | phantom (`"bass"`, `"drums"`) preserved for logging only.
type ArmCommand =
  { wallTimeUs :: Number
  , mvoice :: String
  , destination :: Channel
  , body :: Pattern Pitch
  }

-- | Conductor state.  `lastEmittedUntil` is an integer-rational cycle
-- | boundary; events whose `whole.start` falls before it have already
-- | been emitted on a prior tick.
type State =
  { lastEmittedUntil :: Rational }

initialState :: State
initialState = { lastEmittedUntil: R.fromInt 0 }

type TickResult =
  { arms :: Array ArmCommand
  , newState :: State
  }

-- | The per-tick conductor query.  Mirrors `Tidal.Voice.computeDiscrete`
-- | for window handling so arms and notes share the same look-ahead
-- | semantics — events whose `whole.start` lands in the new window
-- | become arm commands.
conductorTick :: TV.Window -> Section -> State -> TickResult
conductorTick w sec s =
  let
    fromCycleNum = max (R.toNumber s.lastEmittedUntil) w.currentCycle
    toCycleNum = w.lookAheadCycle
    fromCycle = fromInt (Int.floor fromCycleNum)
    toCycle = fromInt (Int.floor toCycleNum + 1)
  in
    if fromCycle >= toCycle then
      { arms: [], newState: s }
    else
      let
        events = queryArcWith Map.empty sec fromCycle toCycle
        arms = map (eventToArm w) events
      in
        { arms, newState: { lastEmittedUntil: toCycle } }

eventToArm :: TV.Window -> Event AnyCue -> ArmCommand
eventToArm w e =
  let
    startCycle = case eventWhole e of
      Just (Arc { start }) -> start
      Nothing -> case eventPart e of
        Arc { start } -> start
    cycleN = R.toNumber startCycle
    delayMs = (cycleN - w.currentCycle) * w.cycleDurationMs
    delayClamped = max 0.0 delayMs
    wallTimeUs = w.nowUnixUs + delayClamped * 1000.0
    AnyCue ac = eventValue e
  in
    { wallTimeUs
    , mvoice: ac.mvoice
    , destination: ac.destination
    , body: ac.body
    }
