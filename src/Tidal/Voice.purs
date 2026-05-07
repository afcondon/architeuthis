-- | Per-voice state container — the value held by a `tidal_voice`
-- | gen_server.
-- |
-- | This module is deliberately minimal: state shape + pure transitions.
-- | Event computation (querying the pattern over a time window and
-- | emitting events to a dispatcher) doesn't live here yet — that's
-- | PR1.4 of the per-voice supervision refactor (see
-- | `docs/per-voice-refactor-plan.md`). Until then the gen_server's
-- | `compute_until` cast is a no-op; the voice exists, can hold a
-- | pattern + binding, and answer state queries.
module Tidal.Voice
  ( State
  , initialState
  , setPattern
  , clearPattern
  , setMuted
  , resetPhase
  , Snapshot
  , snapshot
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt)
import Tidal.Binding (Binding)
import Tidal.Pattern.Types (Pattern)

-- | Per-voice state.
-- |
-- |   * `name` — the bound name (`bass`, `lead`); the gen_server
-- |     registers as `tidal_voice_<name>`.
-- |   * `pattern` — current Pattern; `Nothing` between bind and first
-- |     pattern push.
-- |   * `binding` — dispatch-spec for events (gates, CV, MIDI). Set at
-- |     construction; mutated only via re-bind.
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

-- | Read-only snapshot for the `state` verb. Compiles to a flat Erlang
-- | map (no newtype wrapper) so the WS handler can serialize it directly.
-- | The full Pattern object isn't included — `hasPattern` flags whether
-- | one is set.
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
