-- | FFI surface for the per-yarns-cell voice allocator state.
-- |
-- | The Erlang module `tidal_yarns_state` owns the ETS-backed
-- | allocator; this module is the thin PureScript wrapper the
-- | dispatcher uses on each YarnsDispatch event.
-- |
-- | `AllocResult` distinguishes the three possible outcomes:
-- |
-- |   * `AllocSingle Int`        — poly / mono allocated voice index
-- |   * `AllocBroadcast (Array Int)` — unison: fire all voices
-- |   * `AllocFailed`            — yarns name unknown or other error
-- |                                (treat as no-op at dispatch time)
module Tidal.YarnsState
  ( AllocResult(..)
  , installYarns
  , removeYarns
  , allocateVoice
  ) where

import Prelude
import Effect (Effect)

data AllocResult
  = AllocSingle Int
  | AllocBroadcast (Array Int)
  | AllocFailed

foreign import installYarns
  :: String   -- yarns name
  -> String   -- mode (poly / mono / unison)
  -> String   -- alloc (round-robin / steal-oldest / …)
  -> Int      -- voice count
  -> Effect Unit

foreign import removeYarns :: String -> Effect Unit

foreign import allocateVoice
  :: String   -- yarns name
  -> Number   -- now (microseconds; threaded for future steal-oldest)
  -> Effect AllocResult
