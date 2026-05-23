-- | Sessions.SelenesRotating — Andrew's four-cycle "one LFO at a
-- | time" walk.  Demo for Slab C step 2 (Pattern Selene).
-- |
-- | Each cycle the bank's snapshot rotates: at cycle 0 only slot 0
-- | moves, at cycle 1 only slot 1, etc.  Inactive slots are `silent`
-- | (zero level, zero amps) so the FH-2 holds them at the
-- | range-centred direct level (0V on Bipolar5V).
-- |
-- | The pattern is `cat [bank0, bank1, bank2, bank3]` which divides
-- | one Tidal cycle into four equal slices — at default cps that's
-- | four installs per cycle (every quarter of the Link cycle).  In
-- | practice you'd want this slowed down with `slow N` so each
-- | snapshot holds for N cycles before advancing, otherwise the
-- | FH-2 churns SysEx writes at sub-second intervals.  At default
-- | cps with the four-slice `cat`, the daemon receives an install
-- | every ~250ms — borderline acceptable per the FH-2 timing budget
-- | (memory: `reference_es9_sysex_pacing` — ES-9 needs 50ms gap
-- | between SysEx; FH-2 likely similar).
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful in Calypso.
-- |
-- | Scope-verification target: jack 1 shows a slow sine in cycle 0,
-- | silence in cycles 1-3.  Jack 2 shows silence in cycle 0, a sine
-- | (at different rate) in cycle 1, silence in 2-3.  Etc.
module Sessions.SelenesRotating where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- Rotation: one moving slot per cycle, three silent, walked across
-- four cycles.  All four snapshots target fh2Main, so the daemon
-- installs into the same bank each cycle.
-- ---------------------------------------------------------------------------

studioRotation :: SelenePattern "rotation"
studioRotation = selenePattern $ slow (fromInt 4) $ cat
  [ pure $ octoLfo fh2Main
      [ sinLFO 0.5,  silent,       silent,       silent
      , silent,      silent,       silent,       silent
      ] (Just Bipolar5V)
  , pure $ octoLfo fh2Main
      [ silent,      sinLFO 1.0,   silent,       silent
      , silent,      silent,       silent,       silent
      ] (Just Bipolar5V)
  , pure $ octoLfo fh2Main
      [ silent,      silent,       triLFO 2.0,   silent
      , silent,      silent,       silent,       silent
      ] (Just Bipolar5V)
  , pure $ octoLfo fh2Main
      [ silent,      fixed 0.2,    silent,       sinLFO 4.0
      , silent,      silent,       silent,       silent
      ] (Just Bipolar5V)
  ]

-- ---------------------------------------------------------------------------
-- The session value — no instruments / drum kits / parts.  The
-- SelenePattern binding is auto-discovered by the walker via
-- `enumerateExports`; the session record only carries the rig
-- device declarations.
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
