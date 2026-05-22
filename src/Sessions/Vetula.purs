-- | Sessions.Vetula — smoke-test session for the V-D integration.
-- |
-- | One Vetula declaration: the McMullen Yellow column in C major,
-- | drop-2 voicing strategy, routed to bass1 (IAC channel 1, plays
-- | through Ableton or any soft-synth listening on that channel).
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful in Calypso, then
-- | `arm chord1` from a cell to start playing.
-- |
-- | Validates V-A → V-D end-to-end: VetulaPart values are recognised
-- | by the walker, the Notation/RoutedTo instances type-check
-- | together, the resulting PitchedPart drops into a Session's
-- | parts list.  Audible verification requires Ableton or similar
-- | listening on IAC ch 1.
module Sessions.Vetula where

import Calypso.Prelude
import Studio (iac, bass1)
import Tidal.Vetula (cMajorKey, mcmullenYellow)
import Tidal.Vetula.Voicing (drop2)
import Tidal.Vetula.Pattern (vetula)

-- ---------------------------------------------------------------------------
-- The Vetula declaration — McMullen Yellow in C major
-- ---------------------------------------------------------------------------

-- | 18 chords sequenced one per cycle, voice-led from a drop-2 close
-- | voicing centred on octave 4.  At the default cps (0.5 cycles/sec
-- | = 30 bpm cycle rate, so ~120 bpm at 4 chords / bar), the whole
-- | progression plays in ~36 seconds.
chord1 :: PitchedPart PitchedNote12
chord1 = (vetula cMajorKey mcmullenYellow drop2 >> bass1) "chord1"

-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:     [iac]
  , instruments: [bass1]
  , drumKits:    []
  , parts:       eraseAll [chord1]
  }
