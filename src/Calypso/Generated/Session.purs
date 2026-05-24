module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (iac)

es9Kick :: Selene "es9Kick"
es9Kick = octoClock es9Main
  [ { base: ClockQuarter, multiplier: 1, pulseWidth: 25, phase: 0 } ]
  (Just Unipolar5V)

es5Pattern :: Selene "es5Pattern"
es5Pattern = octoEuclid (es98Gt 0)
  [ { beats: 3, steps: 8, rate: 2, accentRate: 0 }
  , { beats: 5, steps: 8, rate: 2, accentRate: 0 }
  ]
  Nothing

esxMod :: Selene "esxMod"
esxMod = octoLfo (es98Cv 0)
  [ __, sinLFO 0.25 ]
  (Just Bipolar5V)

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
