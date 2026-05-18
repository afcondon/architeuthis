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
