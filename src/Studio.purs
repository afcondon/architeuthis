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
-- Pitched instruments — routing only.  Per-event vel/dur arrives in
-- PR 2b; for now the smart constructor `midi` fills in system
-- defaults (note 60, vel 100, dur 50).
-- ---------------------------------------------------------------------------

bass1 :: Instrument
bass1 = midi iac 1

-- | Second IAC bass instrument — companion to `bass1`.  Used in
-- | tintinnabuli-style two-voice demos where M-voice and T-voice need
-- | separate destinations.
bass2 :: Instrument
bass2 = midi iac 2

-- | Third + fourth IAC bass instruments — for 4-voice fugue / canon
-- | textures where each playhead lands on its own MIDI channel.
bass3 :: Instrument
bass3 = midi iac 3

bass4 :: Instrument
bass4 = midi iac 4

-- ---------------------------------------------------------------------------
-- Drum kits — the Quad Drum / sample-bank destinations.  Each hit
-- declares its MIDI note + vel + duration; PR 2b will dispatch each
-- hit to its own MIDI binding (`<kitAlias>.<hitName>`).  For PR 2a
-- the kit registers as a single binding (using the first hit's
-- defaults) — runtime behaviour matches today's `Channel fh2qd 14 60
-- 100 50` shape until per-hit dispatch lands.
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
