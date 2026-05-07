-- | Dispatcher state — the value held by a `tidal_dispatcher` gen_server.
-- |
-- | The dispatcher is the OSC-output owner: it receives events from
-- | voices, looks up each event's binding, formats and sends OSC to
-- | link-spike (gates / MIDI / triggers) or cv-router (CV buses /
-- | ESX-8CV / ES-5).
-- |
-- | At PR1.3 this is scaffolding only: the state holds a counter, the
-- | gen_server accepts `dispatch_event` casts, and events are logged
-- | rather than routed. The OSC client + bridge_client handles, the
-- | binding-registry lookup, and the per-PrimAction format/send code
-- | all migrate from MIDIScheduler in PR1.4 — that's the point at
-- | which MIDIScheduler is dismantled.
-- |
-- | See `docs/per-voice-refactor-plan.md` §3 and §4 PR1.4.
module Tidal.Dispatcher
  ( State
  , initialState
  , recordEvent
  , Snapshot
  , snapshot
  ) where

import Prelude

newtype State = State
  { eventsReceived :: Int
  -- bridgeClient :: Maybe MIDIBridge.Client     -- added in PR1.4
  -- oscClient :: Maybe OSC.Client               -- added in PR1.4
  -- bindings :: BindingRegistry                 -- added in PR1.5
  }

initialState :: State
initialState = State { eventsReceived: 0 }

-- | Increment the events-received counter. Currently the only
-- | bookkeeping the dispatcher does; PR1.4 adds the actual route +
-- | format + send pipeline.
recordEvent :: State -> State
recordEvent (State s) = State (s { eventsReceived = s.eventsReceived + 1 })

type Snapshot = { eventsReceived :: Int }

snapshot :: State -> Snapshot
snapshot (State s) = { eventsReceived: s.eventsReceived }
