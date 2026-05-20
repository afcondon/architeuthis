-- | Sessions.Rene — the René machine on its own.
-- |
-- | Use case: tutorial / demo of the Make-Noise-René-inspired Cartesian
-- | sequencer.  studioRene is declared inline so this session is
-- | self-contained.  The machine emits MIDI notes autonomously on
-- | IAC ch11; no parts in `session.parts`.
-- |
-- | Twister Bank-Rene (bank 1 — see
-- | `Calypso.Frontend.Controller.Bindings.twisterRene`) maps the 16
-- | knobs to `rene.note0` .. `rene.note15` over the drum-rack range
-- | 36..51, so each knob retunes the cell at its 4×4 position.  The
-- | engine reads a fresh notes array on every step.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with the module declaration
-- | rewritten to `Calypso.Generated.Session`), then fire-typeful.
module Sessions.Rene where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- The René machine instance.
-- Cartesian 4×4 sequencer, 4 steps per cycle (1 X-tick per beat in
-- 4/4).  Notes + skip + gate + glide arrays are 16-long, indexed by
-- the cell at (X,Y).  The `config` slots are live-controllable
-- through the bus; the engine reads them per-step.
-- ---------------------------------------------------------------------------

studioRene :: Rene "studioRene"
studioRene = reneWith
  { device:  iac
  , channel: 11
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 4
  , notes:   reneDefaultNotes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavCartesian
  , config:
      { stepYNow: liveBoolOr false "rene.stepY"
      , notes:    liveIntArrayOr reneDefaultNotes "rene.note"
      , skip:     liveBoolArrayOr (replicate16 false) "rene.skip"
      }
  }
  where
    reneDefaultNotes =
      [ 36, 37, 38, 39
      , 40, 41, 42, 43
      , 44, 45, 46, 47
      , 48, 49, 50, 51
      ]

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
