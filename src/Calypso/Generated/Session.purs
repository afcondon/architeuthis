module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (iac)
import Data.Functor (map)

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
      , transp:       liveIntArrayOr    [  0,  7, 12, -5  ] "odonus.transp"
      , speed:        liveNumberArrayOr [ 1.0, 2.0, 0.5, 1.5 ] "odonus.speed"
      , direction:    liveIntArrayOr    [ 0, 0, 0, 0 ] "odonus.direction"
      , mute:         liveBoolArrayOr   [ false, false, false, false ]
                                        "odonus.mute"
      , scale:        cMajor
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
