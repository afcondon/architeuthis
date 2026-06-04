-- | Sessions.Vetula — expressivity experiments on the V-D substrate.
-- |
-- | Currently running **Experiment 1: bass-out** — split the McMullen
-- | Yellow progression into a bass stream and an upper-voices stream,
-- | routed to separate MIDI channels.  Voice-leading happens once on
-- | the full voicing; the Selector picks subsets *after* voice-leading
-- | so the two streams stay consistent.
-- |
-- | Conventions surfaced during the V-D smoke test still apply:
-- |
-- |   - Use `on vName instr body`, not `(notation >> instr) "name"`.
-- |     Calypso's cell extractor was built around the `on` shape; the
-- |     `>>` form isn't yet recognised.  Voice names are declared in
-- |     `Tidal.Voices` and reach here via the Calypso.Prelude re-export.
-- |   - Hold-duration is an Instrument property (defDurMs).  Pattern's
-- |     whole-arc length is not honoured by emit — use `midiWith` with
-- |     a long defDurMs as a workaround.  Task #88 (`noteLength` /
-- |     `legato`) would fix this properly.
module Sessions.Vetula where

import Calypso.Prelude
import Studio (iac)
import Tidal.Vetula (cMajorKey, mcmullenYellow)
import Tidal.Vetula.Voicing (Selector(..), drop2)
import Tidal.Vetula.Pattern (VetulaPart, vetula, vetulaSplit)

bassChan :: Instrument
bassChan = midiChannelWith iac 1 { defNote: 36, defVel: 100, defDurMs: 1800 }

upperChan :: Instrument
upperChan = midiChannelWith iac 2 { defNote: 60, defVel: 100, defDurMs: 1800 }

prog :: VetulaPart
prog = vetula cMajorKey mcmullenYellow drop2

bass :: PitchedPart
bass = on vBass bassChan (vetulaSplit (TakeLow 1) prog)

upper :: PitchedPart
upper = on vUpper upperChan (vetulaSplit (DropS (TakeLow 1)) prog)

session :: Session
session = Session
  { devices:     [iac]
  , instruments: [bassChan, upperChan]
  , drumKits:    []
  , parts:       eraseAll [bass, upper]
  }
