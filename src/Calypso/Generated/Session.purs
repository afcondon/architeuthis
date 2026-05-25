module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (iac)

defaultNotes :: Array Int
defaultNotes =
  [ 60, 62, 64, 65, 67, 69, 71, 72
  , 74, 76, 77, 79, 81, 83, 84, 86
  ]

twisterOdonus :: Odonus "twisterOdonus"
twisterOdonus = odonusWith
  { device:  iac
  , channel: 1
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 16
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
      , gate:         liveBoolArrayOr (replicate16 true)  "odonus.gate"
      , glide:        liveBoolArrayOr (replicate16 false) "odonus.glide"
      , vel:          liveIntArrayOr  (replicate16 100)   "odonus.vel"
      , mod1:         liveIntArrayOr  (replicate16 0)     "odonus.mod1."
      , mod2:         liveIntArrayOr  (replicate16 0)     "odonus.mod2."
      , mod3:         liveIntArrayOr  (replicate16 0)     "odonus.mod3."
      , mod4:         liveIntArrayOr  (replicate16 0)     "odonus.mod4."
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
