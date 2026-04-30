-- | Ableton Link anchor consumer.
-- |
-- | Wraps the Erlang `tidal_link_anchor` registered process, which
-- | listens on UDP 57121 for `/link/anchor` messages from a Link bridge
-- | (e.g. `music/link-spike`) and stores the latest affine map. The map
-- | lets any caller derive Link beat / Tidal cycle from local time
-- | without participating in Link's network discovery itself — keeping
-- | the GPLv2+ Link surface confined to the bridge process.
-- |
-- | Wire format on the bridge side:
-- |   /link/anchor (h, d, d, d) =
-- |     (UnixMicrosAtAnchor, BeatAtAnchor, Tempo, Quantum)
-- |
-- | Consumers compute beat-at-local-time using:
-- |   beat(T) = beatAtAnchor + (T - unixUs) * tempo / 60_000_000
-- |   cycle = beat / quantum    (1 cycle = 1 bar in Tidal vocabulary)
-- |
-- | All queries return `Maybe`, with `Nothing` meaning "no anchor has
-- | been received yet" (so the scheduler can fall back to a free-running
-- | clock until link-spike comes online).
module Tidal.LinkAnchor
  ( AnchorInfo
  , CycleInfo
  , SchedulerClock
  , start
  , stop
  , info
  , cycleAt
  , beatAt
  , tempo
  , nowUnixUs
  , schedulerClock
  ) where

import Prelude

import Data.Maybe (Maybe)
import Effect (Effect)

-- | Snapshot of the latest anchor.
-- | All `*Us` fields are Unix microseconds (fits in Number until year 2255).
type AnchorInfo =
  { unixUs :: Number     -- anchor moment in Unix microseconds
  , beat :: Number       -- Link beat number at that moment
  , tempo :: Number      -- BPM
  , quantum :: Number    -- beats per Link "bar"
  , lastRecvUs :: Number -- when this process last received an anchor
  }

-- | Extrapolated cycle / tempo / quantum at a particular local time.
type CycleInfo =
  { cycle :: Number
  , tempo :: Number
  , quantum :: Number
  }

-- | Start the listener (idempotent — safe to call multiple times).
foreign import start :: Effect Unit

-- | Stop the listener and close its socket. Mainly for tests.
foreign import stop :: Effect Unit

-- | Synchronous read of the current anchor.
foreign import info :: Effect (Maybe AnchorInfo)

-- | Compute extrapolated cycle/tempo/quantum at the given local Unix-microsecond time.
-- | Returns Nothing if no anchor has arrived yet.
foreign import cycleAt :: Number -> Effect (Maybe CycleInfo)

-- | Compute extrapolated beat at the given local Unix-microsecond time.
-- | Returns Nothing if no anchor has arrived yet.
foreign import beatAt :: Number -> Effect (Maybe Number)

-- | Latest tempo (BPM), or Nothing if no anchor.
foreign import tempo :: Effect (Maybe Number)

-- | Current Unix time in microseconds. Distinct from Erlang's monotonic
-- | time — `cycleAt` etc. expect Unix microseconds because that's what
-- | link-spike publishes in the anchor.
foreign import nowUnixUs :: Effect Number

-- | Synthetic (elapsedMs, cycleDurationMs) pair the MIDI scheduler uses
-- | for its tick math. When a fresh Link anchor is available these
-- | values track Link's live cycle position and tempo; otherwise they
-- | fall back to a free-running clock from the scheduler's startTime
-- | and config BPM. The boolean is purely informational.
type SchedulerClock =
  { synced :: Boolean
  , elapsedMs :: Number
  , cycleDurationMs :: Number
  }

-- | All Link-vs-free-run policy lives in Erlang. The scheduler passes
-- | its `startTime` (ms since VM start, same base as `currentTimeMs`)
-- | and config BPM and gets back the (elapsedMs, cycleDurationMs) pair
-- | to use for this tick.
foreign import schedulerClock
  :: { startTimeMs :: Number, freeRunBpm :: Number }
  -> Effect SchedulerClock
