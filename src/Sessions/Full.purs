-- | Sessions.Full — everything at once.
-- |
-- | Use case: smoke test / "is the whole rig alive?" session.
-- | Combines the four machines (Balistes, René, Repetitor, polysignals)
-- | with the fugue + drum parts from Sessions.Fugue.
-- |
-- | Channel layout (all autonomous emitters are on IAC; the FH-2
-- | polysignals use expander banks via SysEx):
-- |
-- |     ch  1..4  → fugue bass1..bass4
-- |     ch 10     → Repetitor (drums)
-- |     ch 11     → René (drums)
-- |     ch 12     → Balistes (BD/SD/HH)
-- |     ch 14     → qd1 drum kit
-- |     ch 15     → qd2 drum kit
-- |     FH-2 cv1  → C-major scale (V/oct presets)
-- |     FH-2 cv2  → calibration ladder
-- |     FH-2 cv5  → 8 LFOs
-- |     FH-2 gt1  → 8 clocks
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful.
module Sessions.Full where

import Calypso.Prelude
import Studio (fh2, fh2qd, iac, qd1, qd2, bass1, bass2, bass3, bass4)
import Tidal.Fugue
  ( Voice, defaultVoice, fugueVoice
  , doubleSpeed, halfSpeed, quarterSpeed
  )

-- ---------------------------------------------------------------------------
-- Machines
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

studioOdonus :: Odonus "studioOdonus"
studioOdonus = odonusWith
  { device:  iac
  , channel: 11
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 4
  , notes:   odonusDefaultNotes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavCartesian
  , config:
      { stepYNow: liveBoolOr false "odonus.stepY"
      , notes:    liveIntArrayOr odonusDefaultNotes "odonus.note"
      , skip:     liveBoolArrayOr (replicate16 false) "odonus.skip"
      , advance:  pure true
      }
  }
  where
    odonusDefaultNotes =
      [ 36, 37, 38, 39
      , 40, 41, 42, 43
      , 44, 45, 46, 47
      , 48, 49, 50, 51
      ]

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
-- Polysignals — autonomous FH-2 bank configurations
-- ---------------------------------------------------------------------------

studioTestLfo :: PolySignal "studioTestLfo"
studioTestLfo = polyLfo (fh28Cv 5)
  [ { ratio: 1.0,  shape: LfoTri }
  , { ratio: 0.5,  shape: LfoSaw }
  , { ratio: 2.0,  shape: LfoSin }
  , { ratio: 4.0,  shape: LfoSqr }
  , { ratio: 0.25, shape: LfoTri }
  , { ratio: 0.5,  shape: LfoSaw }
  , { ratio: 1.0,  shape: LfoSin }
  , { ratio: 0.5,  shape: LfoSqr }
  ]
  (Just Bipolar5V)

studioTestClock :: PolySignal "studioTestClock"
studioTestClock = polyClock (fh28Gt 0)
  [ { base: ClockSixteenth,  multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockSixteenth,  multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockEighth,     multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockEighth,     multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockQuarter,    multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockQuarter,    multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockHalf,       multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockWhole,      multiplier: 1, pulseWidth: 0, phase: 0 }
  ]
  Nothing

studioCalibLadder :: PolySignal "studioCalibLadder"
studioCalibLadder = polyPreset (fh28Cv 2)
  [ { value: -5.0 }, { value: -3.0 }
  , { value: -1.0 }, { value:  0.0 }
  , { value:  1.0 }, { value:  2.0 }
  , { value:  3.0 }, { value:  5.0 }
  ]
  (Just Bipolar5V)

studioCMajorScale :: PolySignal "studioCMajorScale"
studioCMajorScale = polyPresetNote (fh28Cv 1)
  [ { note: 60 }, { note: 62 }, { note: 64 }, { note: 65 }
  , { note: 67 }, { note: 69 }, { note: 71 }, { note: 72 }
  ]
  (Just Bipolar5V)

-- ---------------------------------------------------------------------------
-- Fugue + drum parts
-- ---------------------------------------------------------------------------

qd1A :: DrumPart
qd1A = on "drums" qd1 (drum "bd bd ~ ~ bd ~ bd ~")

qd1B :: DrumPart
qd1B = on "drums" qd1 (every 8 rev (drum "bd ~ bd bd bd ~ ~ bd"))

qd2A :: DrumPart
qd2A = on "drums" qd2 (drum "~ ~ sn ~ ~ ~ sn ~")

subject :: Pattern PitchedNote12
subject = d "1 5 3 5 1 3 5 -1"

fugue1 :: PitchedPart PitchedNote12
fugue1 = on "fugue" bass1 (fugueVoice defaultVoice subject)

fugue2 :: PitchedPart PitchedNote12
fugue2 = on "fugue" bass2 (fugueVoice (defaultVoice { transpose = 7 }) subject)

fugue3 :: PitchedPart PitchedNote12
fugue3 = on "fugue" bass3 (fugueVoice (defaultVoice { transpose = 7, speed = doubleSpeed }) subject)

fugue4 :: PitchedPart PitchedNote12
fugue4 = on "fugue" bass4 (fugueVoice (defaultVoice { transpose = -3, retrograde = true, speed = halfSpeed }) subject)

-- ---------------------------------------------------------------------------
-- The session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:     [fh2, fh2qd, iac]
  , instruments: [bass1, bass2, bass3, bass4]
  , drumKits:    [qd1, qd2]
  , parts: eraseAll [ fugue1, fugue2, fugue3, fugue4 ]
       <+> eraseAll [ qd1A, qd1B, qd2A ]
  }
