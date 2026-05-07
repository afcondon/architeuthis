-- | Per-voice state container — the value held by a `tidal_voice`
-- | gen_server.
-- |
-- | The voice's two responsibilities:
-- |   1. Hold its current Pattern, Binding, phase, and mute state.
-- |   2. On `compute_until` cast (driven by the clock), query the
-- |      Pattern for events in the requested window and produce a
-- |      list of `EventToDispatch` records — token + absolute Unix
-- |      microsecond wall-time. The Erlang gen_server iterates these
-- |      and casts each to `tidal_dispatcher`.
-- |
-- | Side-effecting work (the cast loop) lives in Erlang; PureScript
-- | only does pure pattern math. The State newtype is opaque to
-- | Erlang and round-trips through gen_server's State parameter.
module Tidal.Voice
  ( State
  , initialState
  , setPattern
  , clearPattern
  , setMuted
  , resetPhase
  , Snapshot
  , snapshot
  , Window
  , EventToDispatch
  , ComputeResult
  , computeUntil
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt)
import Data.Rational as R
import Tidal.Binding (Binding)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern)

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- | Per-voice state.
-- |
-- |   * `name` — the bound name (`bass`, `lead`); the gen_server
-- |     registers as `tidal_voice_<name>`.
-- |   * `pattern` — current Pattern; `Nothing` between bind and first
-- |     pattern push.
-- |   * `binding` — dispatch-spec for events. Set at construction;
-- |     mutated only via re-bind.
-- |   * `phase` — cycle position. Carries over `setPattern` by default;
-- |     reset by `resetPhase`.
-- |   * `lastEmittedUntil` — cycle-time up to which events have been
-- |     dispatched; the next compute window starts here.
-- |   * `muted` — when true the pattern still queries (phase advances)
-- |     but events are dropped at the dispatch boundary. Distinct from
-- |     stop and from clock-level pause.
newtype State = State
  { name :: String
  , pattern :: Maybe (Pattern String)
  , binding :: Binding
  , phase :: Rational
  , lastEmittedUntil :: Rational
  , muted :: Boolean
  }

initialState :: String -> Binding -> State
initialState name binding = State
  { name
  , pattern: Nothing
  , binding
  , phase: fromInt 0
  , lastEmittedUntil: fromInt 0
  , muted: false
  }

setPattern :: Pattern String -> State -> State
setPattern p (State s) = State (s { pattern = Just p })

clearPattern :: State -> State
clearPattern (State s) = State (s { pattern = Nothing })

setMuted :: Boolean -> State -> State
setMuted m (State s) = State (s { muted = m })

resetPhase :: State -> State
resetPhase (State s) = State
  (s { phase = fromInt 0, lastEmittedUntil = fromInt 0 })

-- ---------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------

-- | Read-only snapshot for the `state` verb. Compiles to a flat Erlang
-- | map (no newtype wrapper) so the WS handler can serialize it
-- | directly. The full Pattern object isn't included — `hasPattern`
-- | flags whether one is set.
type Snapshot =
  { name :: String
  , hasPattern :: Boolean
  , muted :: Boolean
  }

snapshot :: State -> Snapshot
snapshot (State s) =
  { name: s.name
  , hasPattern: case s.pattern of
      Just _ -> true
      Nothing -> false
  , muted: s.muted
  }

-- ---------------------------------------------------------------------------
-- Compute window — the per-tick query the clock broadcasts to voices.
-- ---------------------------------------------------------------------------

-- | The clock's view of "now" + lookahead, packaged for voices.
-- |
-- | Same affine map every voice uses on a given tick; sent in one
-- | message rather than each voice querying LinkAnchor independently.
type Window =
  { currentCycle :: Number
  , lookAheadCycle :: Number
  , cycleDurationMs :: Number
  , nowUnixUs :: Number
  }

-- | One event the voice wants the dispatcher to send.
type EventToDispatch =
  { token :: String
  , wallTimeUs :: Number
  }

-- | Result of `computeUntil`: new voice state plus the events to
-- | dispatch this tick. The Erlang gen_server iterates `events` and
-- | casts each to `tidal_dispatcher`.
type ComputeResult =
  { newState :: State
  , events :: Array EventToDispatch
  }

-- | Query the voice's pattern for events in the (lastEmittedUntil,
-- | window.lookAheadCycle] range; convert each to an absolute Unix
-- | microsecond wall-time. Phase always advances (lastEmittedUntil
-- | is bumped); event emission depends on `muted`.
-- |
-- | Pure function — no side effects. The cast loop happens in Erlang.
computeUntil :: Window -> State -> ComputeResult
computeUntil w (State s) = case s.pattern of
  Nothing -> { newState: State s, events: [] }
  Just pat ->
    let
      fromCycleNum = max (R.toNumber s.lastEmittedUntil) w.currentCycle
      toCycleNum = w.lookAheadCycle
      fromCycle = fromInt (Int.floor fromCycleNum)
      toCycle = fromInt (Int.floor toCycleNum + 1)
    in
      if fromCycle >= toCycle then
        { newState: State s, events: [] }
      else
        let
          queryEvents = queryArc pat fromCycle toCycle
          inWindow e =
            let cN = R.toNumber (eventStartCycle e)
            in cN >= fromCycleNum && cN < toCycleNum
          kept = Array.filter inWindow queryEvents
          toDispatch e =
            let
              cycleN = R.toNumber (eventStartCycle e)
              delayMs = (cycleN - w.currentCycle) * w.cycleDurationMs
              delayClamped = max 0.0 delayMs
              wallTimeUs = w.nowUnixUs + delayClamped * 1000.0
            in
              { token: eventSample e, wallTimeUs }
          evs = if s.muted then [] else map toDispatch kept
          newSt = State (s { lastEmittedUntil = toCycle })
        in
          { newState: newSt, events: evs }

-- ---------------------------------------------------------------------------
-- Event helpers (private — not yet promoted to Pattern.Types).
-- ---------------------------------------------------------------------------

-- | Start cycle of an event. Digital events use `whole.start`
-- | (the canonical event boundary, Tidal-style); Analog events fall
-- | back to `part.start` (analog has no whole).
eventStartCycle :: Event String -> Rational
eventStartCycle = case _ of
  Digital { whole: Arc { start } } -> start
  Analog { part: Arc { start } } -> start

eventSample :: Event String -> String
eventSample = case _ of
  Digital { value } -> value
  Analog { value } -> value
