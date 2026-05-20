-- | Sessions.Polysignals — autonomous FH-2 bank configurations.
-- |
-- | Use case: tutorial / demo of the polysignals notation — a typed
-- | declaration of what a whole FH-2 expander bank should be doing,
-- | installed via the fh2-config daemon at baseline load.  Four
-- | polysignals on four different banks: LFOs, clocks, a calibration
-- | voltage ladder, and a C-major scale presets-as-V/oct bank.
-- |
-- | Each polysignal claims one bank.  The daemon enforces non-
-- | overlapping claims; conflicts surface as `ReportClaimError`
-- | registration events visible in Calypso's claim-errors panel.
-- |
-- | Hardware dependency: requires the FH-2 to be connected and
-- | recognised by `fh2-daemon` (Unix socket at `~/.fh2/control.sock`).
-- | Without the FH-2, the daemon writes silently fail and the
-- | polysignals don't produce any output — but the session still
-- | compiles and the walker still processes them.
-- |
-- | Bank addressing: BankCv N is the Nth FHX-8CV expander (0-based,
-- | so the rig's 4 CV expanders are cv0..cv3 if all are connected).
-- | BankGt N is the Nth FHX-8GT expander, independent index — `gt0`
-- | is the FIRST gate expander regardless of how many 8CVs are
-- | between it and the FH-2.  Andrew's rig has 1 GT expander → `gt0`.
-- |
-- | The cv1/cv2/cv5 banks below require the corresponding 8CV
-- | expanders to be physically present in the chain; without them,
-- | the SysEx applies cleanly to the FH-2's config cache but no
-- | voltage shows up at any jack.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful.
module Sessions.Polysignals where

import Calypso.Prelude
import Studio (iac)

-- ---------------------------------------------------------------------------
-- LFO bank on cv5 — eight LFOs at mixed waveforms and ratios.
-- Bipolar5V envelope.  Wire any of cv5's eight jacks to a modulation
-- destination (filter cutoff, VCA, etc) — each gets its own LFO at
-- the declared ratio relative to Link tempo.
-- ---------------------------------------------------------------------------

studioTestLfo :: PolySignal "studioTestLfo"
studioTestLfo = polyLfo (BankCv 5)
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

-- ---------------------------------------------------------------------------
-- Clock bank on gt1 — eight clock divisions/multiples of Link, gate
-- outputs paired ascending.  Useful for driving multiple sequencers
-- at related-but-different tempos for polyrhythm.
-- ---------------------------------------------------------------------------

-- gt0 = first (and only) FHX-8GT expander on Andrew's rig.  The
-- BankGt index is 0-based per FHX-8GT position in the chain; cv1..N
-- numbering doesn't shift it.  Previous Studio.purs had this on gt1
-- (a phantom second expander) and silently did nothing.
studioTestClock :: PolySignal "studioTestClock"
studioTestClock = polyClock (BankGt 0)
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

-- ---------------------------------------------------------------------------
-- Calibration voltage ladder on cv2 — eight constant voltages from
-- -5V to +5V.  Use as a reference for measuring jack scaling or as
-- a static counterweight to other polysignals.
-- ---------------------------------------------------------------------------

studioCalibLadder :: PolySignal "studioCalibLadder"
studioCalibLadder = polyPreset (BankCv 2)
  [ { value: -5.0 }, { value: -3.0 }
  , { value: -1.0 }, { value:  0.0 }
  , { value:  1.0 }, { value:  2.0 }
  , { value:  3.0 }, { value:  5.0 }
  ]
  (Just Bipolar5V)

-- ---------------------------------------------------------------------------
-- C-major scale on cv1 — eight V/oct pitches (MIDI 60..72) on a
-- bipolar 5V range.  Wire each jack to a VCO's 1V/oct input for
-- eight tuned voices on tap.
-- ---------------------------------------------------------------------------

studioCMajorScale :: PolySignal "studioCMajorScale"
studioCMajorScale = polyPresetNote (BankCv 1)
  [ { note: 60 }, { note: 62 }, { note: 64 }, { note: 65 }
  , { note: 67 }, { note: 69 }, { note: 71 }, { note: 72 }
  ]
  (Just Bipolar5V)

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
