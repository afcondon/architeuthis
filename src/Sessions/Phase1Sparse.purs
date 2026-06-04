-- | Sessions.Phase1Sparse — single-note-per-cycle Tidal pattern on
-- | bass1 (IAC ch1) for the timing investigation's Phase 1.
-- |
-- | Used to measure the sparse-Tidal floor with our code in the loop.
-- | Cell text is intentionally minimal: `mini "c4"` emits one MIDI
-- | note per Tidal cycle on channel 1, nothing else.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten),
-- | fire-typeful, then ▶ the `bass1Sparse` cell.
module Sessions.Phase1Sparse where

import Calypso.Prelude
import Studio (iac, bass1)

bass1Sparse :: PitchedPart
bass1Sparse = on vBass bass1 (pitch "c4")

session :: Session
session = Session
  { devices:     [iac]
  , instruments: [bass1]
  , drumKits:    []
  , parts:       eraseAll [ bass1Sparse ]
  }
