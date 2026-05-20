-- | Sessions.VirtualLfoGrids — the simplest end-to-end demo of a
-- | virtual polysignal driving a vmod.
-- |
-- | A `polyLfo (Virtual "lfoBank")` runs entirely in BEAM, no FH-2
-- | round-trip.  Its eight outputs land on the live-control bus at
-- | `lfoBank.0`..`lfoBank.7` and the Grids voice reads two of them
-- | via `liveIntOr` for its x/y density inputs — producing
-- | continuously evolving drum patterns with no external CV
-- | source.
-- |
-- | The user-facing difference from `Sessions.Polysignals` is
-- | exactly one identifier: `Virtual "lfoBank"` instead of
-- | `fh2Main`.  Everything else (slot shape, LFO ratios, Grids
-- | config, `liveIntOr` usage) is unchanged.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful.
module Sessions.VirtualLfoGrids where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- Virtual LFO bank — diagnostic configuration, designed so the audible
-- pattern movement is unambiguous and easy to attribute.
--
-- Slot 0: square at ratio 0.125 — full period 8 cycles, half-period
--         4 cycles.  Output snaps between 0 and 255 every 4 cycles.
--         Routed to Grids `x`.  Density should switch between two
--         distinct settings every four bars, with a hard step (no
--         glide).
-- Slot 1: saw at ratio 1.0 — full period 1 cycle.  Output ramps from
--         0 to 255 over each bar, then snaps back.  Routed to Grids
--         `fillHh`.  Hi-hat fill should grow steadily across each bar
--         from sparse to dense, then reset on the downbeat.
-- Slots 2..7: still ticking (unused — proves they cost nothing).
-- ---------------------------------------------------------------------------

studioVirtualLfo :: PolySignal "studioVirtualLfo"
studioVirtualLfo = polyLfo (Virtual "lfoBank")
  [ { ratio: 0.125, shape: LfoSqr }
  , { ratio: 1.0,   shape: LfoSaw }
  , { ratio: 2.0,   shape: LfoSin }
  , { ratio: 4.0,   shape: LfoSqr }
  , { ratio: 0.25,  shape: LfoTri }
  , { ratio: 0.5,   shape: LfoSaw }
  , { ratio: 1.0,   shape: LfoSin }
  , { ratio: 0.5,   shape: LfoSqr }
  ]
  Nothing

-- ---------------------------------------------------------------------------
-- Grids voice — two slots driven by the diagnostic LFOs above:
--   x      ← lfoBank.0 (8-bar square)
--   fillHh ← lfoBank.1 (1-bar saw)
-- The other config slots keep their static defaults so we can
-- attribute audible movement purely to those two LFOs.
-- ---------------------------------------------------------------------------

studioGrids :: Grids "studioGrids"
studioGrids = grids iac 12 $ gridsConfig
  { x          = liveIntOr 128 "lfoBank.0"
  , y          = liveIntOr 128 "grids.y"
  , fillBd     = liveIntOr 220 "grids.fillBd"
  , fillSd     = liveIntOr 100 "grids.fillSd"
  , fillHh     = liveIntOr 200 "lfoBank.1"
  , randomness = liveIntOr 32  "grids.randomness"
  }

-- ---------------------------------------------------------------------------
-- The session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
