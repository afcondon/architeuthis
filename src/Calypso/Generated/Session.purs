-- | The current session — what's playing right now.
-- |
-- | Devices + channels are factored out into [[Studio]] (the rig
-- | declaration).  This module is mostly cues — what notes go where.
-- | Rewritten by the Calypso server on every ▶ run; edited by hand
-- | only when the user takes the pen.
module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (fh2, fh2qd, iac, qd1, qd2, bass1)

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

-- Degree-pattern cue — follows the active scale.  Arm against tvoice
-- `bass`, then at the wire: `set-scale c-mixolydian` (root C4 →
-- bass plays C4 G4 E4 G4 …) or `set-scale a-harmonic-minor` (root
-- A4 → bass plays A4 E5 C5 …) and hear the mode change next tick.
bass1Deg :: Cue "bass"
bass1Deg = on bass1 (d "1 5 3 5 1 3 5 -1")

-- Mode-pinned cue — eagerly rendered, so `set-scale` does NOT affect
-- it.  Use this for sections that must stay in a specific mode
-- regardless of the live key state (verse/chorus modulation).
bass1Mix :: Cue "bass"
bass1Mix = on bass1 (inKey cMixolydian (d "1 5 3 5 1 3 5 -1"))

-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:  [fh2, fh2qd, iac]
  , channels: [qd1, qd2, bass1]
  , cues:
      [ anyCue qd1A, anyCue qd1B, anyCue qd2A
      , anyCue bass1A, anyCue bass1B
      , anyCue bass1Deg, anyCue bass1Mix
      ]
  }
