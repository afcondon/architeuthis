-- | Tidal.MidiDevice — the MidiDevice ADT.
-- |
-- | Extracted out of Calypso.Prelude so modules like Tidal.Grids can
-- | reach it without cycling through Calypso.Prelude (which re-exports
-- | them in turn).  Calypso.Prelude re-exports this module so end-user
-- | Session sources continue to write `MidiDevice "FH-2" 30` exactly
-- | as before.
module Tidal.MidiDevice
  ( MidiDevice(..)
  ) where

-- | A MIDI destination: the CoreMIDI port name + its measured
-- | round-trip latency in ms.  The latency is used at scheduling
-- | time to nudge MIDI events forward so they hit the wire on the
-- | beat after the path-specific delay.
-- |
-- | Examples:
-- |
-- |     fh2  = MidiDevice "FH-2" 0
-- |     iac  = MidiDevice "IAC Driver Tidal" 30
data MidiDevice = MidiDevice String Int
