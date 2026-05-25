-- | Sessions.TwisterOdonusDemo — Thread 6 (Slab 6.0c) smoke test.
-- |
-- | One Odonus voice on IAC ch1, with three of its 16-cell arrays
-- | wired to the live-control bus.  Companion to the Twister-side
-- | banked-controller (`twisterOdonusNotes` / `twisterOdonusSkip` /
-- | `twisterOdonusRatchet` in Calypso's Bindings.purs):
-- |
-- |   * Press Twister knob 3 → enter "odonus.notes" bank,
-- |     turn any knob → retune that cell's pitch.
-- |   * Press Twister knob 4 → enter "odonus.skip" bank,
-- |     turn any knob → toggle that cell's skip (rough binary —
-- |     knob full-CCW = false, anywhere else ≈ true; refined later).
-- |   * Press Twister knob 5 → enter "odonus.ratchet" bank,
-- |     turn any knob → set that cell's ratchet 1..8.
-- |
-- | The bus prefix `odonus.note*` matches Wired.purs's voice for
-- | familiarity; if both sessions are loaded back-to-back the
-- | Twister muscle-memory carries over.
-- |
-- | To activate: load via Calypso's session-library dropdown in the
-- | topbar.  Disk-edit path is documented as the recurring trap
-- | (see [[reference_calypso_buffer_overwrites_disk]]).
module Sessions.TwisterOdonusDemo where

import Calypso.Prelude
import Studio (iac)

-- | The default per-cell pitches if nothing has touched the bus yet.
-- | 16 notes ascending through two octaves of C major from middle C —
-- | a pleasant "the bank is alive" baseline, distinct from
-- | OdonusDail's chromatic ladder.
defaultNotes :: Array Int
defaultNotes =
  [ 60, 62, 64, 65, 67, 69, 71, 72
  , 74, 76, 77, 79, 81, 83, 84, 86
  ]

-- | One Odonus voice running at 16 stepsPerCycle on IAC ch1.
-- | Notes / skip / ratchet read live from the bus; probability stays
-- | at 1.0 (no `liveNumberArrayOr` helper yet — follow-up slab).
-- | Defaults match the static arrays so the voice plays sensibly
-- | before any knob has been touched.
twisterOdonus :: Odonus "twisterOdonus"
twisterOdonus = odonusWith
  { device:  iac
  , channel: 1
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 16
  , heads:   1
  , notes:   defaultNotes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavForward
  , config:
      { stepYNow:     pure false
      , notes:        liveIntArrayOr defaultNotes "odonus.note"
      , skip:         liveBoolArrayOr (replicate16 false) "odonus.skip"
      , ratchet:      liveIntArrayOr    (replicate16 1)   "odonus.ratchet"
      , probability:  liveNumberArrayOr (replicate16 1.0) "odonus.probability"
      -- Slab 6.1: gate / glide / vel / mod1..mod4 all bus-wired so the
      -- forthcoming Twister side-button banks (R-top gate, R-bottom
      -- glide) and knob banks (Vel, Mod1..Mod4) land on already-live
      -- slots.  Defaults match the binding's static values — voice
      -- sounds identical until something writes to the bus.
      , gate:         liveBoolArrayOr (replicate16 true)  "odonus.gate"
      , glide:        liveBoolArrayOr (replicate16 false) "odonus.glide"
      , vel:          liveIntArrayOr  (replicate16 100)   "odonus.vel"
      , mod1:         liveIntArrayOr  (replicate16 0)     "odonus.mod1."
      , mod2:         liveIntArrayOr  (replicate16 0)     "odonus.mod2."
      , mod3:         liveIntArrayOr  (replicate16 0)     "odonus.mod3."
      , mod4:         liveIntArrayOr  (replicate16 0)     "odonus.mod4."
      , transp:       [ pure 0 ]
      , speed:        [ pure 1.0 ]
      , direction:    [ pure 0 ]
      , mute:         [ pure false ]
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
