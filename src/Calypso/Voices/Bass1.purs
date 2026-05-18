-- | Voice wrapper for tvoice "bass1". Demo target for typeful-cues
-- | end-to-end integration: bass1A routes through IAC Driver Tidal
-- | channel 1, which lands in Ableton with no rig hardware needed.
module Calypso.Voices.Bass1 where

import Calypso.Generated.Session (bass1A)
import Calypso.Prelude (PitchedPart)
import Tidal.Pitch (PitchedNote12)

armed :: PitchedPart PitchedNote12
armed = bass1A
