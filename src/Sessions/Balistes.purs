-- | Sessions.Balistes — the Balistes virtual module on its own.
-- |
-- | Use case: tutorial / demo of the BEAM-native MI Balistes clone.
-- | studioBalistes is declared inline (rather than in Studio) so this
-- | session is self-contained.  No drum parts in `session.parts` —
-- | Balistes' autonomous emit is the entire voice.
-- |
-- | Twister Bank-Balistes (bank 2 on the controller — see
-- | `Calypso.Frontend.Controller.Bindings.twisterBalistes`) drives the
-- | live-control bus:
-- |
-- |     knob 0 → balistes.x          (drum-map X coordinate, 0..255)
-- |     knob 1 → balistes.y          (drum-map Y coordinate, 0..255)
-- |     knob 2 → balistes.fillBd     (BD density)
-- |     knob 3 → balistes.fillSd     (SD density)
-- |     knob 4 → balistes.fillHh     (HH density)
-- |     knob 5 → balistes.randomness (perturbation, 0..128)
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with the module declaration
-- | rewritten to `Calypso.Generated.Session`), then fire-typeful in
-- | Calypso.
module Sessions.Balistes where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- The Balistes virtual module instance.
-- BD/SD/HH on MIDI channel 12 (IAC Driver Tidal); a 5×5 X/Y density
-- grid with three independent fills.  Each step (1/32 cycle) reads
-- the six Pattern Int slots below — knobs / LFOs / bus writers feed
-- them through `liveIntOr "<name>"`.
-- ---------------------------------------------------------------------------

studioBalistes :: Balistes "studioBalistes"
studioBalistes = balistes iac 12 $ balistesConfig
  { x          = liveIntOr 128 "balistes.x"
  , y          = liveIntOr 128 "balistes.y"
  , fillBd     = liveIntOr 220 "balistes.fillBd"
  , fillSd     = liveIntOr 100 "balistes.fillSd"
  , fillHh     = liveIntOr 200 "balistes.fillHh"
  , randomness = liveIntOr 32  "balistes.randomness"
  }

-- ---------------------------------------------------------------------------
-- The session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
