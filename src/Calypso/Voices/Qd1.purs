-- | Voice wrapper for tvoice "qd1". The daemon writes this file
-- | each time the qd1 voice is armed; the body is one declaration
-- | re-exporting whichever part is currently armed.
-- |
-- | The BEAM module name `calypso_voices_qd1@ps` is the stable
-- | identity that purerl-tidal's voice gen_server hot-loads from.
-- | The user's chosen part (qd1A / qd1B / etc.) is hidden behind
-- | this wrapper's `armed/0`.
module Calypso.Voices.Qd1 where

import Calypso.Generated.Session (qd1B)
import Calypso.Prelude (PitchedPart)

armed :: PitchedPart
armed = qd1B
