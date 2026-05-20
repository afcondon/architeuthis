-- | Sessions.Wired — first cross-machine wiring demo.
-- |
-- | A virtual polyEuclid bank emits gates on bus keys
-- | `rhythmBank.0`..`rhythmBank.7`.  A René voice reads slot 0 as
-- | its `advance` input.  Result: the polyEuclid clocks the René,
-- | step-by-step, with no Tidal pattern, no MIDI controller, no
-- | hardware — entirely in BEAM, signal flowing between machines
-- | through the live-control bus.
-- |
-- | This is the architectural keystone from the signals-and-sources
-- | note: a Source (virtual polyEuclid) wired to a Sink (René's
-- | advance input) via the bus, with no special-case code per
-- | combination.  The same shape extends to polyClock-clocking-
-- | Grids, polyLfo-modulating-Repetitor-density, etc.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful.
module Sessions.Wired where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- The clock source — a virtual polyEuclid bank running in BEAM.
-- Eight slots, each emitting a euclidean rhythm to a bus key.  Only
-- slot 0 is consumed in this demo (by René's advance); the rest
-- still tick (proves the polysignal infrastructure does the work
-- whether or not anyone's reading) and are available for further
-- wirings.
-- ---------------------------------------------------------------------------

studioRhythm :: PolySignal "studioRhythm"
studioRhythm = polyEuclid (Virtual "rhythmBank")
  [ { beats: 3, steps: 8,  rate: 1, accentRate: 1 }  -- 3-against-8 clave
  , { beats: 5, steps: 8,  rate: 1, accentRate: 1 }  -- 5-against-8
  , { beats: 7, steps: 8,  rate: 1, accentRate: 1 }  -- 7-against-8
  , { beats: 3, steps: 16, rate: 1, accentRate: 1 }  -- sparse 3-against-16
  , { beats: 5, steps: 16, rate: 1, accentRate: 1 }
  , { beats: 7, steps: 16, rate: 1, accentRate: 1 }
  , { beats: 9, steps: 16, rate: 1, accentRate: 1 }
  , { beats: 1, steps: 4,  rate: 1, accentRate: 1 }  -- on-the-beat
  ]
  Nothing

-- ---------------------------------------------------------------------------
-- The René voice — reads rhythmBank.0 as its advance gate.
-- Same notes layout as Sessions.Rene (15 Cs + 1 D) so we can hear
-- the engine traversal directly, but now clocked by the
-- polysignal instead of by a self-contained Tidal pattern.
-- Swap "rhythmBank.0" → "rhythmBank.1" / .2 / etc. to listen to
-- different euclidean rhythms from the same polysignal source.
-- ---------------------------------------------------------------------------

studioRene :: Rene "studioRene"
studioRene = reneWith
  { device:  iac
  , channel: 11
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 16
  , notes:   reneDefaultNotes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavForward
  , config:
      { stepYNow: liveBoolOr false "rene.stepY"
      , notes:    liveIntArrayOr reneDefaultNotes "rene.note"
      , skip:     liveBoolArrayOr (replicate16 false) "rene.skip"
      , advance:  gateFromBus "rhythmBank.0"
      }
  }
  where
    reneDefaultNotes =
      [ 60, 60, 60, 60
      , 60, 60, 60, 60
      , 60, 60, 60, 60
      , 60, 60, 60, 62
      ]

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
