-- | Sessions.ZR — the Repetitor / ZR-inspired rhythm-corpus machine.
-- |
-- | Use case: tutorial / demo of the BEAM-native Repetitor.  Loads
-- | one named pattern from the African / Indian / Caribbean corpus
-- | and emits MIDI drums on IAC ch10.  Per-row offsets phase-shift
-- | each row's pattern independently; live-controllable through the
-- | bus.
-- |
-- | Twister Bank-Repetitor (bank 3 — see
-- | `Calypso.Frontend.Controller.Bindings.twisterRepetitor`) maps
-- | knobs 0..3 to `rep.offM`/`rep.offC1`/`rep.offC2`/`rep.offC3` over
-- | 0..11 (one full pattern length for "King 1", a 12-beat pattern).
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful.
module Sessions.ZR where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- The Repetitor machine instance.
-- Library "zr_african", pattern "King 1" — a 12-beat Bembé.  Rows
-- M / C1 / C2 / C3 each play their own line of the pattern; the
-- offset slots phase-shift them.
-- ---------------------------------------------------------------------------

studioRepetitor :: Repetitor "studioRepetitor"
studioRepetitor = repetitorWith
  { device:  iac
  , channel: 10
  , noteM:   36
  , noteC1:  38
  , noteC2:  40
  , noteC3:  41
  , vel:     100
  , durMs:   30
  , stepsPerCycle: 4
  , library: "zr_african"
  , patternSlug: "King 1"
  , config:
      { offsetM:  liveIntOr 0 "rep.offM"
      , offsetC1: liveIntOr 0 "rep.offC1"
      , offsetC2: liveIntOr 0 "rep.offC2"
      , offsetC3: liveIntOr 0 "rep.offC3"
      }
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
