-- | The current session — what's playing right now.
-- |
-- | Devices + channels are factored out into Studio (the rig
-- | declaration).  Edit Studio.purs when the rig changes; edit
-- | this file every time you change which notes go where.
module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (fh2, fh2qd, iac, qd1, qd2, bass1, bass2)

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

-- | Stepwise melody fragment in A natural minor.  Up to E5, back down
-- | through the home tone.  Arm `melodyM` and `melodyT` together to
-- | hear Pärt's 1→1 rule: each M-voice note paired with the nearest
-- | A-minor triad pitch above it.
mPart :: Pattern Pitch
mPart = mini "a4 b4 c5 d5 e5 d5 c5 b4"

-- | The M-voice — the melody, sent to `bass1`.
melodyM :: Cue "bass"
melodyM = on bass1 mPart

-- | The T-voice — `tintinnabuli` over `aMinT` (the A-minor triad) at
-- | Position 1 Superior, sent to `bass2` so Live can route it to a
-- | second instrument.  Pure `map` over the melody — no scheduling,
-- | no shared state.  Time structure (`every`, `rev`, `fast`, …)
-- | applied to `mPart` would carry through to `melodyT` automatically.
melodyT :: Cue "bass"
melodyT = on bass2 (tintinnabuli aMinT above1 mPart)

intro :: Section
intro = slow (r 8) (cat [armCue bass1A, armCue bass1B])


-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:  [fh2, fh2qd, iac]
  , channels: [qd1, qd2, bass1, bass2]
  , cues:     [ anyCue qd1A, anyCue qd1B, anyCue qd2A
              , anyCue bass1A, anyCue bass1B
              , anyCue bass1Deg, anyCue bass1Mix
              , anyCue melodyM, anyCue melodyT
              ]
  }
