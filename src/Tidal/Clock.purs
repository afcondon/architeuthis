-- | Clock state — the value held by a `tidal_clock` gen_statem.
-- |
-- | The Erlang gen_statem owns the timer mechanics, the running/paused
-- | state, and the integration with `tidal_link_anchor` (Link sync).
-- | This PureScript module just holds the configurable parameters
-- | (bpm, tick interval, lookahead, start time) and offers pure
-- | transitions for the gen_statem to call into.
-- |
-- | See `docs/per-voice-refactor-plan.md` §3 for the role of the clock
-- | in the per-voice supervision tree: on each tick it broadcasts
-- | `{compute_until, T}` to every voice in `tidal_voice_sup`. Voices
-- | are responsible for actually querying their patterns and pushing
-- | events to the dispatcher.
module Tidal.Clock
  ( Config
  , State
  , initialState
  , setBpm
  , Info
  , info
  , Snapshot
  , snapshot
  ) where

import Prelude

-- | Clock configuration.
-- |
-- |   * `bpm` — free-running tempo when no Link anchor is available.
-- |   * `tickIntervalMs` — wall-clock interval between scheduler ticks.
-- |     50 ms = 20 Hz is the existing default; matches the LFO sample
-- |     rate, which is the tightest constraint we have.
-- |   * `lookAheadMs` — how far ahead of "now" we ask voices to compute.
-- |     200 ms is the existing default — enough to absorb a tick's worth
-- |     of jitter without delivering events too early.
-- |   * `startTimeMs` — wall-clock start moment, used by the free-running
-- |     fallback in `tidal_link_anchor:scheduler_clock/2`.
type Config =
  { bpm :: Number
  , tickIntervalMs :: Int
  , lookAheadMs :: Number
  , startTimeMs :: Number
  }

newtype State = State Config

initialState :: Config -> State
initialState = State

setBpm :: Number -> State -> State
setBpm b (State s) = State (s { bpm = b })

-- | Full internal view — what the gen_statem reads on each tick.
type Info = Config

info :: State -> Info
info (State s) = s

-- | User-facing slice for the `state` verb. Excludes `startTimeMs`
-- | (internal detail not useful to JSON consumers).
type Snapshot =
  { bpm :: Number
  , tickIntervalMs :: Int
  , lookAheadMs :: Number
  }

snapshot :: State -> Snapshot
snapshot (State s) =
  { bpm: s.bpm
  , tickIntervalMs: s.tickIntervalMs
  , lookAheadMs: s.lookAheadMs
  }
