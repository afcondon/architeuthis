-- | Integration shim — bridges the typeful-cues path to the existing
-- | per-cell-compile / play-armed wire infrastructure.
-- |
-- | The existing `play-armed <voice> <hash>` WS verb expects a module
-- | named `Tidal.Generated.M<hash>` exposing `pattern :: Pattern String`.
-- | This module satisfies that contract by extracting the body from
-- | a typeful Cue value (`Calypso.Voices.Bass1.armed`).
-- |
-- | End-to-end test path (manual):
-- |   1. `make run` (or DeepStar)
-- |   2. wscat -c ws://localhost:3012/ws
-- |   3. send: `midi-device iac "IAC Driver Tidal"`
-- |   4. send: `bind bass1 midi-note iac 1 36 100 50`
-- |   5. send: `play-armed bass1 Mcalypsobass1`
-- |   → Ableton (on IAC ch1) plays the bass1A pattern
-- |     "c2 e2 g2 ~ b2 ~ g2 e2"
-- |
-- | When this works end-to-end, the typeful-cues architecture is
-- | proven through real MIDI dispatch.
module Tidal.Generated.Mcalypsobass1 where

import Tidal.Pattern.Types (Pattern)
import Calypso.Prelude (Cue(..))
import Calypso.Voices.Bass1 (armed)

pattern :: Pattern String
pattern = case armed of
  Cue r -> r.body
