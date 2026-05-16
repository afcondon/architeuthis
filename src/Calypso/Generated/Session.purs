-- | The current session — what's playing right now.
-- |
-- | Devices + channels are factored out into Studio (the rig
-- | declaration).  Edit Studio.purs when the rig changes; edit
-- | this file every time you change which notes go where.
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
bass1B = on bass1 (mini "c4 c4 ~ g4 ~ c3 e3 ~")

bass1Deg :: Cue "bass"
bass1Deg = on bass1 (inKey aHarmonicMinor (d "1 5 3 5 1 3 5 -1"))

bass1Mix :: Cue "bass"
bass1Mix = on bass1 (inKey dDorian (d "5 2 5 3 3 7 -1"))

-- ---------------------------------------------------------------------------
-- Sections (MVP-2: Pattern of cues, fired by the conductor)
-- ---------------------------------------------------------------------------

-- A two-event section that arms bass1A in the first half of every
-- cycle and bass1B in the second half.  Wrap with `slow N` to spread
-- the swap over more cycles:  intro = slow 8 (cat [...]) gives 4
-- cycles of each.  Fire with the `play-piece intro` WS verb.
intro :: Section
intro = slow (r 8) (cat [armCue bass1A, armCue bass1B])

-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:  [fh2, fh2qd, iac]
  , channels: [qd1, qd2, bass1]
  , cues:     [ anyCue qd1A, anyCue qd1B, anyCue qd2A
              , anyCue bass1A, anyCue bass1B
              , anyCue bass1Deg, anyCue bass1Mix
              ]
  }
