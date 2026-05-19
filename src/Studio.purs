-- | Studio — Andrew's rig as a typed module.
-- |
-- | The stable declaration of *what's plugged in*: MIDI devices,
-- | pitched instruments, drum kits.  Sessions import these names;
-- | they don't redeclare.  When the rig changes, edit Studio.purs
-- | once.
-- |
-- | After PR 2a (2026-05-17): pitched instruments use the smart
-- | constructor `midi` which hides system note/vel/dur defaults;
-- | drum destinations declare their hit table via `midiDrumKit` +
-- | `hit`.
module Studio where

import Calypso.Prelude

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

-- | The FH-2 module's main MIDI input.  Latency 0 (no software path).
fh2 :: MidiDevice
fh2 = MidiDevice "FH-2" 0

-- | The FH-2 module's USB host port for Quad Drum (QD) trigger
-- | mappings.  Latency 69ms — calibrated against the rig's tap.
fh2qd :: MidiDevice
fh2qd = MidiDevice "FH-2" 69

-- | The Mac's IAC Driver "Tidal" port — virtual MIDI in to Ableton
-- | Live for software instrument routing.  Latency 30ms.
iac :: MidiDevice
iac = MidiDevice "IAC Driver Tidal" 30

-- ---------------------------------------------------------------------------
-- CV/Gate routers
-- ---------------------------------------------------------------------------

-- | The local cv-router instance — drives ES-9 buses via CoreAudio.
-- | Host:port matches the default cv-router boot config.  Today
-- | informational only (the runtime routes all OSC through a
-- | singleton client on these coordinates); PR 2c.2 wires up the
-- | per-alias OSCClient map for multi-router setups (shared jams,
-- | multi-ES-9 rigs).
cvRouter :: CvRouter
cvRouter = CvRouter "127.0.0.1" 57120

-- ---------------------------------------------------------------------------
-- Pitched instruments — routing only.  Per-event vel/dur arrives in
-- PR 2b; for now the smart constructor `midi` fills in system
-- defaults (note 60, vel 100, dur 50).
-- ---------------------------------------------------------------------------

bass1 :: Instrument PitchedNote12
bass1 = midi iac 1

-- | Second IAC bass instrument — companion to `bass1`.  Used in
-- | tintinnabuli-style two-voice demos where M-voice and T-voice need
-- | separate destinations.
bass2 :: Instrument PitchedNote12
bass2 = midi iac 2

-- | Third + fourth IAC bass instruments — for 4-voice fugue / canon
-- | textures where each playhead lands on its own MIDI channel.
bass3 :: Instrument PitchedNote12
bass3 = midi iac 3

bass4 :: Instrument PitchedNote12
bass4 = midi iac 4

-- ---------------------------------------------------------------------------
-- V/oct instruments — routed through cv-router to modular VCOs.
-- Each is one gate channel (the trigger) + one CV bus (V/oct CV).
-- Compound bindings of the form `gate G + cv V voct` are installed
-- automatically by the session walker; per-event emit fires both the
-- gate pulse and the V/oct pre-set.
-- ---------------------------------------------------------------------------

-- | Plaits voice — gate channel 6, V/oct CV on bus 15.  Matches the
-- | legacy hard-coded `plaitsBinding` in Tidal.Binding (preserved as
-- | a default registry entry for back-compat); declaring it here in
-- | Studio makes the typed surface the source of truth.
plaits :: Instrument PitchedNote12
plaits = vPerOct cvRouter { gateChannel: 6, voctBus: 15 }

-- ---------------------------------------------------------------------------
-- Drum kits — the Quad Drum / sample-bank destinations.  Each hit
-- declares its MIDI note + vel + duration; the session walker
-- registers the kit as a single `MidiDrumKit` binding carrying a
-- hits map keyed by hit name.  At dispatch, each event's token
-- ("bd", "sn", …) looks up its (note, vel, durMs) triple — classic
-- Tidal/SuperDirt per-orbit `s`-keyed lookup, ported to typed MIDI.
-- ---------------------------------------------------------------------------

-- | QD channel 14 — the primary drum kit.  Standard GM mapping.
-- |
-- | NOTE 2026-05-18 evening: also shared with studioGrids for the
-- | vmod demo.  Both register a (fh2qd, ch14) claim; the framework
-- | logs a duplicate-claim warning but both bindings stay live —
-- | qd1's `bd`/`sn`/`hh`/`cp` patterns and Grids' autonomous output
-- | both emit on the same channel.  Interleaved firing on the FH-2
-- | is the musician's responsibility (no software arbitration).
qd1 :: DrumKit
qd1 = midiDrumKit fh2qd 14
  [ hit "bd" 36 100 50
  , hit "sn" 38 100 50
  , hit "hh" 42  80 30
  , hit "cp" 39 100 30
  ]

-- | QD channel 15 — secondary kit.  Same hit table as `qd1` so
-- | patterns are portable between them.
qd2 :: DrumKit
qd2 = midiDrumKit fh2qd 15
  [ hit "bd" 36 100 50
  , hit "sn" 38 100 50
  , hit "hh" 42  80 30
  , hit "cp" 39 100 30
  ]

-- ---------------------------------------------------------------------------
-- Gate drum kits — drum dispatch via cv-router gate triggers instead of
-- MIDI.  Each hit maps a token to a cv-router gate channel + pulse
-- duration.  Walker installs a single `GateDrumKit` PrimAction per
-- kit; per-event dispatch fires the matching gate.
-- ---------------------------------------------------------------------------

-- | A four-voice gate drum kit on cv-router gate channels 0..3 → ES-9
-- | panel jacks 1..4.  Useful smoke-test target for the GateDrumKit
-- | dispatch path; can drive any modular trigger destination (Plonk,
-- | Maths cycle, an envelope, an ESX-8GT bit on the same panel).
gateKit :: DrumKit
gateKit = gateDrumKit cvRouter
  [ gateHit "bd" 0 30
  , gateHit "sn" 1 30
  , gateHit "hh" 2 20
  , gateHit "cp" 3 30
  ]

-- ---------------------------------------------------------------------------
-- Polysignals (Slab C step 1, 2026-05-18) — autonomous FH-2 bank
-- configurations declared as typed Session-level bindings.  The
-- walker classifies each by constructor tag, projects to the JSON
-- envelope the daemon already understands, and ships it to
-- fh2-daemon at baseline load.  Port claims happen on the daemon
-- side via the unified ClaimRig.
-- ---------------------------------------------------------------------------

-- | Smoke-test polysignal: eight LFOs on a free FHX-8CV expander bank
-- | (cv5) at mixed waveforms and ratios, output range ±5V.  Walker
-- | emits a `RegisterPolySignal` event with this value's JSON
-- | envelope; the daemon installs the LFO bank and records the claim
-- | under alias `studioTestLfo`.  Using `cv5` rather than `main`
-- | because main is currently held by the drumkit + chord claims from
-- | earlier port-claims work — see ~/.fh2/claims.json.
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

-- | Eight clock pulses on an FHX-8GT expander bank (gt1) — straight
-- | 16th/8th/quarter/half divisions, paired ascending.  GateOnly bank,
-- | unipolar 0..5V triggers.  Walker test for the polyclock family.
studioTestClock :: PolySignal "studioTestClock"
studioTestClock = polyClock (BankGt 1)
  [ { base: ClockSixteenth,  multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockSixteenth,  multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockEighth,     multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockEighth,     multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockQuarter,    multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockQuarter,    multiplier: 2, pulseWidth: 0, phase: 0 }
  , { base: ClockHalf,       multiplier: 1, pulseWidth: 0, phase: 0 }
  , { base: ClockWhole,      multiplier: 1, pulseWidth: 0, phase: 0 }
  ]
  Nothing  -- envelope-level default (Unipolar5V from familyDefaultRange)

-- | A calibration voltage ladder on cv2: -5V / -3V / -1V / 0V / 1V /
-- | 2V / 3V / 5V across the eight jacks of the bank.  Constant
-- | voltages, no LFO or clock — the simplest polysignal: the daemon
-- | encodes each Number as a 14-bit offset-binary directLevel using
-- | the bank's output range.  Useful as a reference for measuring
-- | per-jack scaling or as a static counterweight to other
-- | polysignals on the same expander.
studioCalibLadder :: PolySignal "studioCalibLadder"
studioCalibLadder = polyPreset (BankCv 2)
  [ { value: -5.0 }, { value: -3.0 }
  , { value: -1.0 }, { value:  0.0 }
  , { value:  1.0 }, { value:  2.0 }
  , { value:  3.0 }, { value:  5.0 }
  ]
  (Just Bipolar5V)

-- | The C-major scale across the eight jacks of cv1, encoded as
-- | V/oct.  Each jack holds a constant pitch — wire each to a VCO's
-- | 1V/oct input to get eight tuned voices on tap.  The daemon
-- | converts MIDI 60..72 to volts via `(note - 12) / 12.0` (note 60 =
-- | middle C at +4V).
studioCMajorScale :: PolySignal "studioCMajorScale"
studioCMajorScale = polyPresetNote (BankCv 1)
  [ { note: 60 }, { note: 62 }, { note: 64 }, { note: 65 }
  , { note: 67 }, { note: 69 }, { note: 71 }, { note: 72 }
  ]
  (Just Bipolar5V)

-- ---------------------------------------------------------------------------
-- Grids virtual module (BEAM-native MI Grids clone) — first vmod
-- instance per the parameter-as-Pattern lift.  Three drums (BD/SD/HH)
-- emitted as MIDI notes on the FH-2 QD channel.  Refire the cell
-- with new X/Y/fill values mid-flight; the next 16th-note picks up
-- the new patterns.
-- ---------------------------------------------------------------------------

-- 2026-05-19 testing: switched from (fh2qd ch14) to (iac ch12) so
-- all three machines (Grids + Repetitor + René) route via Ableton
-- IAC for the first end-to-end joint test.  Avoids rig-routing
-- complications per `feedback_test_simplest_path_first`.  Revert
-- to (fh2qd 14) once the engine behaviour is confirmed.
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
-- Repetitor virtual module (ZR-inspired, BEAM-native rhythm corpus) —
-- second vmod instance (2026-05-19).  14 named African / Indian /
-- Caribbean patterns; per-row offsets phase-shift the row's own
-- pattern.  Routed to Ableton via IAC ch10 (standard drum channel)
-- so it can coexist with studioGrids on the FH-2 path.  Default 4
-- steps per cycle = one step per beat in 4/4.  Pattern lengths
-- that aren't 4n produce natural polyrhythms against the bar.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- René machine (Make-Noise-René-inspired Cartesian sequencer) — third
-- machine instance (2026-05-19).  User-supplied 16 notes + modal
-- arrays; engine supplies traversal.  Routed to Ableton via IAC ch11
-- so it sits alongside studioRepetitor (ch10) on the same device.
-- Default 4 steps per cycle = one X-tick per beat in 4/4.  Y-clock
-- driven by `mini "1 0 0 0"` so the cursor walks down a row each bar.
-- ---------------------------------------------------------------------------

studioRene :: Rene "studioRene"
studioRene = reneWith
  { device:  iac
  , channel: 11
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 4
  , notes:   reneDefaultNotes
              -- Engine init defaults; the config's `notes` patterns
              -- override on every step, so these only matter for the
              -- ~50ms window between voice start and the first
              -- snapshot.  Keep them in drum-rack range to match the
              -- live-controlled defaults below.
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavCartesian
  , config:
      { stepYNow: liveBoolOr false "rene.stepY"
      , notes:    liveIntArrayOr reneDefaultNotes "rene.note"
                 -- Twister knobs 1..16 → `rene.note0`..`rene.note15`
                 -- via the Calypso controller pump.  Cell-text and
                 -- controller writes both land here; the engine reads
                 -- a fresh array on every step.
      , skip:     liveBoolArrayOr (replicate16 false) "rene.skip"
                 -- Reserved for Twister push-button toggles (queued
                 -- — pump currently parses presses but doesn't dispatch
                 -- them as set-control writes).  Today the array is
                 -- all-false unless a cell explicitly sets `rene.skipN`.
      }
  }
  where
    -- 2026-05-19 testing: drum-rack range so the same Ableton
    -- drum-rack on IAC ch11 hears every cell.  Restore to chord-based
    -- notes ([60..86]) once we're routing René to a melodic synth.
    reneDefaultNotes =
      [ 36, 37, 38, 39   -- row 0
      , 40, 41, 42, 43   -- row 1
      , 44, 45, 46, 47   -- row 2
      , 48, 49, 50, 51   -- row 3
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