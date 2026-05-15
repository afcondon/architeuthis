-- | Spike — hand-written `.tiderl` session for the typeful-cues pipeline.
-- |
-- | The real daemon will write sessions like this one based on the
-- | user's .tiderl source.  When this compiles cleanly, the
-- | Calypso.Prelude MVP is validated.
module Calypso.Generated.Session where

import Calypso.Prelude

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

fh2 :: MidiDevice
fh2 = MidiDevice "FH-2" 0

fh2qd :: MidiDevice
fh2qd = MidiDevice "FH-2" 69

iac :: MidiDevice
iac = MidiDevice "IAC Driver Tidal" 30

-- ---------------------------------------------------------------------------
-- Channels
-- ---------------------------------------------------------------------------

qd1 :: Channel
qd1 = Channel fh2qd 14 60 100 50

qd2 :: Channel
qd2 = Channel fh2qd 15 60 100 50

bass1 :: Channel
bass1 = Channel iac 1 36 100 50

-- ---------------------------------------------------------------------------
-- Cues
-- ---------------------------------------------------------------------------

qd1A :: Cue "drums"
qd1A = on qd1 (mini "bd bd ~ ~ bd ~ bd ~")

qd1B :: Cue "drums"
qd1B = on qd1 (every 8 rev (mini "bd ~ bd bd bd ~ ~ bd"))

qd2A :: Cue "drums"
qd2A = on qd2 (mini "~ ~ sn ~ ~ ~ sn ~")

bass1A :: Cue "bass"
bass1A = on bass1 (mini "c2 e2 g2 ~ b2 ~ g2 e2")

bass1B :: Cue "bass"
bass1B = on bass1 (mini "c3 c3 ~ g2 ~ c3 e3 ~")

-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:  [fh2, fh2qd, iac]
  , channels: [qd1, qd2, bass1]
  , cues:     [anyCue qd1A, anyCue qd1B, anyCue qd2A, anyCue bass1A, anyCue bass1B]
  }
