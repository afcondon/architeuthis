-- | The current session — what's playing right now.
-- |
-- | Devices + channels are factored out into Studio (the rig
-- | declaration).  Edit Studio.purs when the rig changes; edit
-- | this file every time you change which notes go where.
module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (fh2, fh2qd, iac, qd1, qd2, bass1, bass2, bass3, bass4)
import Tidal.Fugue
  ( Voice, defaultVoice, fugueVoice
  , doubleSpeed, halfSpeed, quarterSpeed
  )

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
bass1B = on bass1 (mini "c4 c4 ~ g4 ~ c3 e3 ~")

bass1Deg :: Cue "bass"
bass1Deg = on bass1 (inKey aHarmonicMinor (d "1 5 3 5 1 3 5 -1"))

bass1Mix :: Cue "bass"
bass1Mix = on bass1 (inKey dDorian (d "5 5 5 3 3 7 -1"))

-- ---------------------------------------------------------------------------
-- MVP-3 Tintinnabuli demo: M-voice + parallel T-voice on A-minor.
-- ---------------------------------------------------------------------------

mPart :: Pattern Pitch
mPart = mini "a4 b4 c5 d5 e5 d5 c5 b4"

melodyM :: Cue "bass"
melodyM = on bass1 mPart

melodyT :: Cue "bass"
melodyT = on bass2 (tintinnabuli aMinT above1 mPart)

-- ---------------------------------------------------------------------------
-- MVP-4 Fugue Machine demo: 4 playheads on a shared subject.
-- ---------------------------------------------------------------------------

-- Subject in RAW DEGREES (no `inKey` wrap) so the global scale bus
-- governs rendering and diatonic transpose can operate.  Fire
-- `set-scale aHarmonicMinor` once at boot; `set-scale dDorian` etc.
-- to modulate the whole fugue live.
subject :: Pattern Pitch
subject = d "1 5 3 5 1 3 5 -1"

fugue1 :: Cue "fugue"
fugue1 = on bass1 (fugueVoice defaultVoice subject)

fugue2 :: Cue "fugue"
fugue2 = on bass2 (fugueVoice (defaultVoice { transpose = 7 }) subject)

fugue3 :: Cue "fugue"
fugue3 = on bass3 (fugueVoice (defaultVoice { transpose = 7, speed = doubleSpeed }) subject)

fugue4 :: Cue "fugue"
fugue4 = on bass4 (fugueVoice (defaultVoice { transpose = -3, retrograde = true, speed = halfSpeed }) subject)

intro :: Section
intro = slow (r 8) (cat [armCue bass1A, armCue bass1B])


-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:  [fh2, fh2qd, iac]
  , channels: [qd1, qd2, bass1, bass2, bass3, bass4]
  , cues:     [ anyCue qd1A, anyCue qd1B, anyCue qd2A
              , anyCue bass1A, anyCue bass1B
              , anyCue bass1Deg, anyCue bass1Mix
              , anyCue melodyM, anyCue melodyT
              , anyCue fugue1, anyCue fugue2, anyCue fugue3, anyCue fugue4
              ]
  }
