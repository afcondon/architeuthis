-- | WebSocket handler config used by `Tidal.WebSocket.Server`.
-- |
-- | The actual live-wire parsing and dispatch is done in the Erlang
-- | shell `tidal_webSocket_handler@foreign` (`Handler.erl`); this
-- | module just provides the `Config` record + a constructor used by
-- | the Server module to wire the scheduler pid into Cowboy's handler
-- | initial state.
module Tidal.WebSocket.Handler
  ( Config
  , wsHandler
  ) where

import Erl.Process (Process)
import Tidal.Scheduler (Msg)

-- | Configuration passed to init.
type Config =
  { schedulerPid :: Process Msg
  }

-- | Build a Config from a scheduler pid. Server.purs feeds this into
-- | Cowboy's route dispatch as the handler's initial state.
wsHandler :: Process Msg -> Config
wsHandler schedulerPid = { schedulerPid }
