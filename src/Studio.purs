-- | Studio — Andrew's rig as a typed module.
-- |
-- | This is the stable declaration of *what's plugged in*: which
-- | MIDI devices exist, which channels route to what hardware, what
-- | latency each device has.  Sessions import these names; they don't
-- | redeclare them.  When you patch a new module into the rig, add
-- | its Channel here once and every Session can reference it.
-- |
-- | A `Studio` companion to `Calypso.Generated.Session` — Session is
-- | "what should play right now"; Studio is "what exists to play on".
-- | Both live on disk; only Session gets rewritten by Calypso, while
-- | Studio is edited by hand when the rig changes.
module Studio where

import Calypso.Prelude

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

-- | The FH-2 module's main MIDI input.  Drives gates + envelopes
-- | declared via its SysEx config.  Latency 0 (no software path).
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
-- Channels
-- ---------------------------------------------------------------------------
-- | Channel constructor args: device, channel-num, default-note,
-- | default-velocity, default-duration-ms.

qd1 :: Channel
qd1 = Channel fh2qd 14 60 100 50

qd2 :: Channel
qd2 = Channel fh2qd 15 60 100 50

bass1 :: Channel
bass1 = Channel iac 1 36 100 50
