-- | Phase 5 multi-voice timing test.
-- |
-- | Two identically-configured Balistes voices on iac ch10 and ch11 so we
-- | can measure inter-voice timing offset directly: every step both
-- | voices fire the same BD/SD/HH triggers at the same nominal WallUs.
-- | If the BEAM's parallel-scheduler + link-spike + CoreMIDI chain
-- | handles same-tick coincidence correctly, the two audio recordings
-- | should show coincident onsets (sub-ms inter-voice offset).
-- |
-- | Higher fill values stress the chain — at 200/200/200 most steps
-- | fire all three drums, so each step = 6 simultaneous MIDI events
-- | across the two voices.
module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (iac)
import Control.Applicative (pure)

balistesA :: Balistes "balistesA"
balistesA = balistes iac 10
  ( balistesConfig
      { fillBd = pure 200, fillSd = pure 160, fillHh = pure 180 }
  )

balistesB :: Balistes "balistesB"
balistesB = balistes iac 11
  ( balistesConfig
      { fillBd = pure 200, fillSd = pure 160, fillHh = pure 180 }
  )

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
