-- | Sessions.FugueMachine — Slab 6.2 smoke test.
-- |
-- | Demonstrates the (V=1, P=4) configuration of the unified sequencer:
-- | one Odonus voice on IAC ch1 with four playheads walking the same
-- | 16-cell grid at different speeds and transpositions.
-- |
-- |   * Playhead 0 — speed 1.0, transp  0  (baseline melody)
-- |   * Playhead 1 — speed 2.0, transp  7  (fifth above, double-time)
-- |   * Playhead 2 — speed 0.5, transp 12  (octave above, half-time)
-- |   * Playhead 3 — speed 1.5, transp -5  (fourth below, dotted rate)
-- |
-- | All four emit on the same MIDI channel; Live's instrument plays
-- | them as a chord-with-counterpoint.  Same grid means a Twister
-- | sweep on Notes (bank 0) cascades to all four — the user can edit
-- | the underlying melody live and hear all four playheads pick up
-- | the change on their next emit.
-- |
-- | To activate: load via Calypso's session-library dropdown.
module Sessions.FugueMachine where

import Calypso.Prelude
import Studio (iac)
import Data.Functor (map)

-- | C-major scale ascending over two octaves, then descending — gives
-- | each playhead enough melodic surface to be audibly distinct as
-- | speed offsets them.
fugueNotes :: Array Int
fugueNotes =
  [ 60, 62, 64, 65, 67, 69, 71, 72
  , 74, 76, 77, 79, 77, 76, 74, 72
  ]

fugueMachine :: Odonus "fugueMachine"
fugueMachine = odonusWith
  { device:  iac
  , channel: 1
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 16
  , heads:   4
  , notes:   fugueNotes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavForward
  , config:
      -- All per-cell params bus-wired so the rotary banks (Notes /
      -- Velocity / Probability / Ratchet / Mod1-4) can edit the
      -- underlying grid live while the playheads run.  Read-side
      -- fallbacks here become the audible defaults until knobs are
      -- touched.
      { stepYNow:     pure false
      , notes:        liveIntArrayOr    fugueNotes              "odonus.note"
      , skip:         liveBoolArrayOr   (replicate16 false)     "odonus.skip"
      , ratchet:      liveIntArrayOr    (replicate16 1)         "odonus.ratchet"
      , probability:  liveNumberArrayOr (replicate16 1.0)       "odonus.probability"
      , gate:         liveBoolArrayOr   (replicate16 true)      "odonus.gate"
      , glide:        liveBoolArrayOr   (replicate16 false)     "odonus.glide"
      , vel:          liveIntArrayOr    (replicate16 100)       "odonus.vel"
      , mod1:         liveIntArrayOr    (replicate16 0)         "odonus.mod1."
      , mod2:         liveIntArrayOr    (replicate16 0)         "odonus.mod2."
      , mod3:         liveIntArrayOr    (replicate16 0)         "odonus.mod3."
      , mod4:         liveIntArrayOr    (replicate16 0)         "odonus.mod4."
      -- The four playheads.  Each entry is a Pattern, sampled per step
      -- — could be wired to the bus later (Twister bank 9 Speed / bank
      -- 10 Transp), but for now they're static `pure` values.
      -- Per-playhead fields wired to the live-control bus so the
      -- L-top Fugue dashboard (Slab 6.6c) can mutate them in real
      -- time.  The arrays here are the read-side fallbacks the engine
      -- sees if nothing has touched the bus yet.
      , transp:       liveIntArrayOr    [  0,  7, 12, -5  ] "odonus.transp"
      , speed:        liveNumberArrayOr [ 1.0, 2.0, 0.5, 1.5 ] "odonus.speed"
      , direction:    liveIntArrayOr    [ 0, 0, 0, 0 ] "odonus.direction"
      , mute:         liveBoolArrayOr   [ false, false, false, false ]
                                        "odonus.mute"
      , scale:        cChromatic
      , distribution: Natural
      , advance:      pure true
      }
  }

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
