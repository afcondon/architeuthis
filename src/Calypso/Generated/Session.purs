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

-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:  [fh2, fh2qd, iac]
  , channels: [qd1, qd2, bass1]
  , cues:     [anyCue qd1A, anyCue qd1B, anyCue qd2A, anyCue bass1A, anyCue bass1B]
  }
