module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (iac)

studioTestLfo :: Selene "studioTestLfo"
studioTestLfo = octoLfo fh2Main
  [ silent { rate = 2.0, sin = 0.3, sqr = 0.8 }
  , sawLFO 0.5
  , sinLFO 4.0
  , sqrLFO 4.0
  , triLFO 0.25
  , sawLFO 0.5
  , sinLFO 1.0
  , sqrLFO 0.5
  ]
  (Just Bipolar5V)

studioTestClock :: Selene "studioTestClock"
studioTestClock = octoClock (fh28Gt 0)
  [ { base: ClockSixteenth,  multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockSixteenth,  multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockEighth,     multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockEighth,     multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockQuarter,    multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockQuarter,    multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockHalf,       multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockWhole,      multiplier: 1, pulseWidth: 0, phase: 0 }
  ]
  Nothing

studioCalibLadder :: Selene "studioCalibLadder"
studioCalibLadder = octoLfo (fh28Cv 2)
  [ fixed (-1.0)  -- -5V at Bipolar5V
  , fixed (-0.6)  -- -3V
  , fixed (-0.2)  -- -1V
  , fixed 0.0     --  0V
  , fixed 0.2     -- +1V
  , fixed 0.4     -- +2V
  , fixed 0.6     -- +3V
  , fixed 1.0     -- +5V
  ]
  (Just Bipolar5V)

studioCMajorScale :: Selene "studioCMajorScale"
studioCMajorScale = octoPresetNote (fh28Cv 1)
  [ { note: 60 }, { note: 62 }, { note: 64 }, { note: 65 }
  , { note: 67 }, { note: 69 }, { note: 71 }, { note: 72 }
  ]
  (Just Bipolar5V)

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
