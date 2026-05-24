-- | Sessions.Es9Rotating — SelenePattern rotation on ES-9.
-- |
-- | Mirror of `SelenesRotating` but targeting ES-9 panel jacks instead
-- | of FH-2's main bank.  Same Pattern (Selene s) construction (cat of
-- | four snapshots, slowed 4x); only `es9Main` differs from `fh2Main`.
-- |
-- | Because ES-9 has no SysEx round-trip, the install rate ceiling is
-- | structurally higher than FH-2's 4.2/sec — the audio callback just
-- | writes new generator parameters and keeps streaming.  Worth a
-- | measurement at higher BPM (see C.4g notes).
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs`, fire-typeful in Calypso.
-- | Scope ES-9 jacks 1-4 — should rotate one moving LFO at a time.
module Sessions.Es9Rotating where

import Calypso.Prelude
import Studio (iac)

es9Rotation :: SelenePattern "es9Rotation"
es9Rotation = selenePattern $ slow (fromInt 4) $ cat
  [ pure $ octoLfo es9Main
      [ sinLFO 0.5,  __,           __,           __
      , __,          __,           __,           __
      ] (Just Bipolar5V)
  , pure $ octoLfo es9Main
      [ __,          sinLFO 1.0,   __,           __
      , __,          __,           __,           __
      ] (Just Bipolar5V)
  , pure $ octoLfo es9Main
      [ __,          __,           triLFO 2.0,   __
      , __,          __,           __,           __
      ] (Just Bipolar5V)
  , pure $ octoLfo es9Main
      [ __,          fixed 0.2,    __,           sinLFO 4.0
      , __,          __,           __,           __
      ] (Just Bipolar5V)
  ]

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
