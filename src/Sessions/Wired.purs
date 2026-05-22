-- | Sessions.Wired — first cross-machine wiring demo.
-- |
-- | A virtual octoEuclid bank emits gates on bus keys
-- | `rhythmBank.0`..`rhythmBank.7`.  A René voice reads slot 0 as
-- | its `advance` input.  Result: the octoEuclid clocks the René,
-- | step-by-step, with no Tidal pattern, no MIDI controller, no
-- | hardware — entirely in BEAM, signal flowing between machines
-- | through the live-control bus.
-- |
-- | This is the architectural keystone from the signals-and-sources
-- | note: a Source (virtual octoEuclid) wired to a Sink (René's
-- | advance input) via the bus, with no special-case code per
-- | combination.  The same shape extends to octoClock-clocking-
-- | Balistes, octoLfo-modulating-Repetitor-density, etc.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful.
module Sessions.Wired where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- The clock source — a virtual octoEuclid bank running in BEAM.
-- Eight slots, each emitting a euclidean rhythm to a bus key.  Only
-- slot 0 is consumed in this demo (by René's advance); the rest
-- still tick (proves the polysignal infrastructure does the work
-- whether or not anyone's reading) and are available for further
-- wirings.
-- ---------------------------------------------------------------------------

studioRhythm :: Selene "studioRhythm"
studioRhythm = octoEuclid (Virtual "rhythmBank")
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
-- Same notes layout as Sessions.Odonus (15 Cs + 1 D) so we can hear
-- the engine traversal directly, but now clocked by the
-- polysignal instead of by a self-contained Tidal pattern.
-- Swap "rhythmBank.0" → "rhythmBank.1" / .2 / etc. to listen to
-- different euclidean rhythms from the same polysignal source.
-- ---------------------------------------------------------------------------

studioOdonus :: Odonus "studioOdonus"
studioOdonus = odonusWith
  { device:  iac
  , channel: 11
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 16
  , notes:   odonusDefaultNotes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavForward
  , config:
      { stepYNow: liveBoolOr false "odonus.stepY"
      , notes:    liveIntArrayOr odonusDefaultNotes "odonus.note"
      , skip:     liveBoolArrayOr (replicate16 false) "odonus.skip"
      , advance:  gateFromBus "rhythmBank.0"
      }
  }
  where
    odonusDefaultNotes =
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
