-- | Sessions.Es9SimpleLfo — first end-to-end ES-9 Selene demo.
-- |
-- | Single 0.5 Hz sine LFO on ES-9 panel jack 1 (bank slot 0), driven
-- | by cv-router's audio callback at 48 kHz from a typed Session-level
-- | `Selene` binding.  Same Selene type, same `octoLfo` smart
-- | constructor, same walker — the only difference from a FH-2 demo
-- | is the `es9Main` bank token, which routes the JSON envelope to
-- | cv-router's control socket instead of fh2-daemon's.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (rewriting the module
-- | declaration to `Calypso.Generated.Session`), fire-typeful in
-- | Calypso.  Scope ES-9 panel jack 1 should show a slow ±5V sine.
module Sessions.Es9SimpleLfo where

import Calypso.Prelude
import Studio (iac)

-- | One slot active (sin 0.5 Hz on jack 1), seven flat lines.
es9TestLfo :: Selene "es9TestLfo"
es9TestLfo = octoLfo es9Main
  [ sinLFO 0.5,  __,           __,           __
  , __,          __,           __,           __
  ] (Just Bipolar5V)

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
