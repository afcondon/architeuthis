-- | Sessions.Vetula — end-to-end smoke session for V-D, validated
-- | through Ableton on 2026-05-22.
-- |
-- | The McMullen Yellow column in C major, drop-2 voicing strategy,
-- | routed to a long-sustain IAC ch 1 Instrument so each chord rings
-- | through its cycle slot instead of being a 50ms stab.
-- |
-- | Two Vetula-specific conventions surfaced during the smoke test:
-- |
-- |   - **Use `on "name" instr body`, not `(notation >> instr) "name"`.**
-- |     Calypso's cell extractor was built around the `on` shape; it
-- |     recognises the `>>` form's name but can't pull a body out of
-- |     it, leaving cells unfireable.  Until Calypso learns the
-- |     `>>` shape, route via `on` + `toPattern`.
-- |   - **Hold-duration is an Instrument property** (defDurMs field of
-- |     `midiWith`).  The Pattern's whole-arc length is *not* honoured
-- |     by the emit path — every event gets the same MIDI Note-Off
-- |     timer regardless of how long the Pattern says it lasts.
-- |     `Tidal.Combinators noteLength` (task #88) would let us pass
-- |     this per-event via `# legato 0.9`; for now, `midiWith` with a
-- |     long defDurMs is the workaround.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful in Calypso, then
-- | arm chord1 from the Voice Cells pane.
module Sessions.Vetula where

import Calypso.Prelude
import Studio (iac)
import Tidal.Notation (toPattern)
import Tidal.Vetula (cMajorKey, mcmullenYellow)
import Tidal.Vetula.Voicing (drop2)
import Tidal.Vetula.Pattern (vetula)

-- | Long-sustain variant of bass1: ~1.8s defDurMs so each chord
-- | holds through its cycle slot at the default cps.
sustained :: Instrument PitchedNote12
sustained = midiWith iac 1 { defNote: 60, defVel: 100, defDurMs: 1800 }

-- | 18 chords, voice-led from a drop-2 close voicing centred on
-- | octave 4.  One chord per cycle (slowCat).
chord1 :: PitchedPart PitchedNote12
chord1 = on "chord1" sustained
  (toPattern (vetula cMajorKey mcmullenYellow drop2))

session :: Session
session = Session
  { devices:     [iac]
  , instruments: [sustained]
  , drumKits:    []
  , parts:       eraseAll [chord1]
  }
