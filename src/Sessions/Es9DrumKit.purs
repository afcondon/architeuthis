-- | Sessions.Es9DrumKit — polyclock + polyeuclid + polylfo on the ES-9
-- | rig, end-to-end through purerl-tidal → cv-router.
-- |
-- | Validates C.4i (Selene polyclock / polyeuclid families on ES-9):
-- |
-- |   - `es9Kick`     polyclock on ES-9 jack 1 (panel CV-as-gate),
-- |                   quarter notes against Link tempo.
-- |   - `es5Pattern`  polyeuclid on ES-5 built-in gates 1 + 2 (via
-- |                   Silent Way), tresillo + cinquillo.
-- |   - `esxMod`      slow polylfo on ESX-8CV slot 1 — confirms the
-- |                   non-clock families still route correctly when
-- |                   the new clock-mode atomics are in play.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs`, fire-typeful in Calypso.
-- | Then check:
-- |   - jack 1 LED pulses on each beat
-- |   - ES-5 gate 1 LED runs the tresillo
-- |   - ES-5 gate 2 LED runs the cinquillo
-- |   - ESX-8CV out 2 swings slowly between ±5V
module Sessions.Es9DrumKit where

import Calypso.Prelude
import Studio (iac)

es9Kick :: Selene "es9Kick"
es9Kick = octoClock es9Main
  [ { base: ClockQuarter, multiplier: 1, pulseWidth: 25, phase: 0 } ]
  (Just Unipolar5V)

es5Pattern :: Selene "es5Pattern"
es5Pattern = octoEuclid (es98Gt 0)
  [ { beats: 3, steps: 8, rate: 2, accentRate: 0 }
  , { beats: 5, steps: 8, rate: 2, accentRate: 0 }
  ]
  Nothing

esxMod :: Selene "esxMod"
esxMod = octoLfo (es98Cv 0)
  [ __, sinLFO 0.25 ]
  (Just Bipolar5V)

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
