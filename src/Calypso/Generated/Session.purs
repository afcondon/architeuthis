-- | Spike — hand-written `.tiderl` session for the typeful-cues pipeline.
-- |
-- | This is the equivalent of `Tidal.Generated.Mtest` but written in
-- | the new Level 3 / typeful-cues form. The real daemon will write
-- | sessions like this one to `session/CalypsoSession.purs` based on
-- | the user's .tiderl source.
-- |
-- | When this compiles cleanly, the Calypso.Prelude MVP is validated.
module Calypso.Generated.Session where

import Calypso.Prelude

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

fh2 :: MidiDevice
fh2 = midiDevice "FH-2"

fh2qd :: MidiDevice
fh2qd = midiDevice "FH-2" `withLat` 69

iac :: MidiDevice
iac = midiDevice "IAC Driver Tidal" `withLat` 30

-- ---------------------------------------------------------------------------
-- Bindings
-- ---------------------------------------------------------------------------

qd1 :: MidiNote
qd1 = midiNote fh2qd { ch: 14, note: 60, vel: 100, dur: 50 }

qd2 :: MidiNote
qd2 = midiNote fh2qd { ch: 15, note: 60, vel: 100, dur: 50 }

bass1 :: MidiNote
bass1 = midiNote iac { ch: 1, note: 36, vel: 100, dur: 50 }

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

-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:  [fh2, fh2qd, iac]
  , bindings: [toBinding qd1, toBinding qd2, toBinding bass1]
  , cues:     [anyCue qd1A, anyCue qd1B, anyCue qd2A, anyCue bass1A]
  }
