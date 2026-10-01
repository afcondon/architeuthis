-- | Tidal.Conductor — the section-firing tick.
-- |
-- | A `Section` (defined in Calypso.Prelude) is `Pattern AnyPart`:
-- | each event of the outer pattern carries a typed part body and
-- | the mvoice name to arm it on.  This module exposes the per-tick
-- | query mirrored on `Tidal.Voice.computeDiscrete` and the BEAM-side
-- | `tidal_conductor` calls it on each clock tick.
-- |
-- | An ArmCommand is the per-event surface returned to the BEAM —
-- | wall-time, mvoice name, and a `Pattern PitchedNote12` body suitable for
-- | the same dispatch path that the `play-armed` WS verb uses.
-- | Today the BEAM fires arms as it sees them; the wallTimeUs is
-- | preserved so a future cycle-accurate scheduler can use it.
module Tidal.Conductor
  ( State
  , initialState
  , ArmCommand
  , Destination(..)
  , TickResult
  , conductorTick
  ) where

import Prelude

import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Haskell.Rational (Rational, fromInt)
import Haskell.Rational as R

import Calypso.Prelude (AnyPart(..), DrumKit, Instrument, Section)
import Tidal.Pattern.Core (queryArcWith)
import Tidal.Pattern.Types
  ( Event
  , eventValue
  , eventWhole
  , eventPart
  , Arc(..)
  )
import Tidal.Sound (Sound)
import Tidal.Pattern.Types (Pattern)
import Tidal.Voice (Window) as TV

-- | The discriminated destination an arm command targets.  PR 2a
-- | introduced this sum so the Erlang conductor can unwrap to the
-- | right ETS key on its side without inspecting PureScript-encoded
-- | shapes.  PR 2b will rebalance: each drum hit becomes its own
-- | binding under `<kitAlias>.<hitName>`, at which point `DestDrumKit`
-- | grows a hit-name field (or the discriminator moves to per-event).
data Destination
  = DestInstrument Instrument
  | DestDrumKit DrumKit

-- | One arm command surfaced to the BEAM.  Wall time is the precise
-- | moment the arm "should" land; today the BEAM fires arms as it
-- | sees them, but a future scheduler can use this field.
-- |
-- | `destination` carries the part's bound `Instrument` or `DrumKit`
-- | (wrapped in the `Destination` sum); the BEAM-side walker keeps an
-- | ETS map from destination-value → binding name, which the conductor
-- | unwraps and uses to find the right voice supervisor.
-- |
-- | `body` is always `Pattern Sound`: both PitchedParts and DrumParts
-- | now carry their body as the unified `Sound` payload (the lift from
-- | the pitch carrier happens at the `on` boundary in Calypso.Prelude),
-- | so the conductor passes it through unchanged to the same dispatch
-- | path the `play-armed` WS verb uses.
type ArmCommand =
  { wallTimeUs :: Number
  , mvoice :: String
  , destination :: Destination
  , body :: Pattern Sound
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

eventToArm :: TV.Window -> Event AnyPart -> ArmCommand
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
  in
    case eventValue e of
      AnyPitchedPart p ->
        { wallTimeUs
        , mvoice: p.mvoice
        , destination: DestInstrument p.destination
        , body: p.body
        }
      AnyDrumPart d ->
        { wallTimeUs
        , mvoice: d.mvoice
        , destination: DestDrumKit d.destination
        , body: d.body
        }
