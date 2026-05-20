-- | Sessions.Grids — the Grids virtual module on its own.
-- |
-- | Use case: tutorial / demo of the BEAM-native MI Grids clone.
-- | studioGrids is declared inline (rather than in Studio) so this
-- | session is self-contained.  No drum parts in `session.parts` —
-- | Grids' autonomous emit is the entire voice.
-- |
-- | Twister Bank-Grids (bank 2 on the controller — see
-- | `Calypso.Frontend.Controller.Bindings.twisterGrids`) drives the
-- | live-control bus:
-- |
-- |     knob 0 → grids.x          (drum-map X coordinate, 0..255)
-- |     knob 1 → grids.y          (drum-map Y coordinate, 0..255)
-- |     knob 2 → grids.fillBd     (BD density)
-- |     knob 3 → grids.fillSd     (SD density)
-- |     knob 4 → grids.fillHh     (HH density)
-- |     knob 5 → grids.randomness (perturbation, 0..128)
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with the module declaration
-- | rewritten to `Calypso.Generated.Session`), then fire-typeful in
-- | Calypso.
module Sessions.Grids where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- The Grids virtual module instance.
-- BD/SD/HH on MIDI channel 12 (IAC Driver Tidal); a 5×5 X/Y density
-- grid with three independent fills.  Each step (1/32 cycle) reads
-- the six Pattern Int slots below — knobs / LFOs / bus writers feed
-- them through `liveIntOr "<name>"`.
-- ---------------------------------------------------------------------------

studioGrids :: Grids "studioGrids"
studioGrids = grids iac 12 $ gridsConfig
  { x          = liveIntOr 128 "grids.x"
  , y          = liveIntOr 128 "grids.y"
  , fillBd     = liveIntOr 220 "grids.fillBd"
  , fillSd     = liveIntOr 100 "grids.fillSd"
  , fillHh     = liveIntOr 200 "grids.fillHh"
  , randomness = liveIntOr 32  "grids.randomness"
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
