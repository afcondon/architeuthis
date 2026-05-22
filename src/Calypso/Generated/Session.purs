  -- | Vetula smoke session — McMullen Yellow on bass1 (long durations).
  module Calypso.Generated.Session where

  import Calypso.Prelude
  import Studio (iac)
  import Tidal.Notation (toPattern)
  import Tidal.Vetula (cMajorKey, mcmullenYellow)
  import Tidal.Vetula.Voicing (drop2)
  import Tidal.Vetula.Pattern (vetula)

  -- Long-held variant of bass1: ~1.8s sustain so chords ring out.
  sustained :: Instrument PitchedNote12
  sustained = midiWith iac 1 { defNote: 60, defVel: 100, defDurMs: 1800 }

  chord1 :: PitchedPart PitchedNote12
  chord1 = on "chord1" sustained (toPattern (vetula cMajorKey mcmullenYellow drop2))

  session :: Session
  session = Session
    { devices:     [iac]
    , instruments: [sustained]
    , drumKits:    []
    , parts:       eraseAll [chord1]
    }