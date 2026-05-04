-- | Tiny ETS-backed state mirror.  The scheduler writes a JSON
-- | snapshot of its current configuration + registered bindings on
-- | every state-mutating message; the WebSocket handler reads it
-- | synchronously when answering the `state` verb.
-- |
-- | Avoids round-tripping through PureScript-typed message passing
-- | for what is fundamentally a debug-surface query — the scheduler
-- | writes once per mutation, the handler reads on demand, and a
-- | tens-of-microseconds staleness window is fine.
-- |
-- | The named ETS table `tidal_state_bus` is created once on boot
-- | (`init`) and lives for the life of the BEAM. `read` falls back
-- | to an empty-object JSON string when the table doesn't yet have
-- | a snapshot (handler called before scheduler's first mutation).
module Tidal.StateBus
  ( init
  , write
  , read
  ) where

import Prelude

import Effect (Effect)

-- | Create the ETS table.  Idempotent: re-init does not error.
foreign import init :: Effect Unit

-- | Write the current state snapshot as a JSON string.
foreign import write :: String -> Effect Unit

-- | Read the latest snapshot.  Returns `"{}"` when no scheduler
-- | mutation has fired yet (boot-window, before the first Tick).
foreign import read :: Effect String
