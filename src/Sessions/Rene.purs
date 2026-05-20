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
import Data.Functor (map)
import Tidal.Pattern.Core (fastCat)

-- ---------------------------------------------------------------------------
-- The René machine instance.
-- Linear 16-step sequencer walking the 4×4 grid in row-major order
-- (forward navigation: cells 0..15 then wrap).  16 micro-ticks per
-- cycle.  Default melody is "C C C C  C C C C  C C C C  C C C D"
-- so the loop is unambiguously audible: fifteen middle Cs and a
-- final D before the cycle restarts.
--
-- The advance gate is a 3-against-8 euclidean pattern:
--   true false false  true false  true false false
-- This advances the engine three times per cycle instead of sixteen,
-- so we step through the 16 cells in 16/3 ≈ 5.33 cycles — irregular
-- clave-feel pulse, eventually hitting the D every five-and-a-third
-- cycles.  Set `advance: pure true` for the previous (every-tick)
-- behaviour.  Run at slow tempo (60 BPM) so the irregular step
-- intervals are clearly audible and the foundational timing-jitter
-- issue ([[project_timing_jitter_investigation_queued]]) doesn't
-- interfere with assessing the gate logic.
--
-- The `config` slots are live-controllable through the bus; the
-- engine reads them per-step.  Cartesian / stepYNow stays defined
-- for future tests but isn't used in NavForward mode.
-- ---------------------------------------------------------------------------

studioRene :: Rene "studioRene"
studioRene = reneWith
  { device:  iac
  , channel: 11
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 16
  , notes:   reneDefaultNotes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavForward
  , config:
      { stepYNow: liveBoolOr false "rene.stepY"
      , notes:    liveIntArrayOr reneDefaultNotes "rene.note"
      , skip:     liveBoolArrayOr (replicate16 false) "rene.skip"
      , advance:  fastCat (map pure
          [ true, false, false
          , true, false, true
          , false, false
          ])
      }
  }
  where
    -- 15× C4 (MIDI 60) + 1× D4 (MIDI 62) at the last step.
    reneDefaultNotes =
      [ 60, 60, 60, 60
      , 60, 60, 60, 60
      , 60, 60, 60, 60
      , 60, 60, 60, 62
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
