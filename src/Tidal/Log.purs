module Tidal.Log
  ( debug
  , info
  , err
  ) where

import Prelude (Unit)
import Effect (Effect)

-- | Per-event spam (every MIDI send, every "skipping" warning). Off by default.
foreign import debug :: String -> Effect Unit

-- | Default-on. Startup, state changes, parse summaries.
foreign import info :: String -> Effect Unit

-- | Always prints regardless of log level.
foreign import err :: String -> Effect Unit
