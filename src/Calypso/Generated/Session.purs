  module Calypso.Generated.Session where

  import Calypso.Prelude
  import Studio (iac)
  import Tidal.Vetula (cMajorKey, mcmullenYellow)
  import Tidal.Vetula.Voicing (drop2)
  import Tidal.Vetula.Pattern (VetulaPart, vetula, vetulaHeld)

  ringy :: Instrument PitchedNote12
  ringy = midiChannelWith iac 5 { defNote: 60, defVel: 90, defDurMs: 12000 }

  prog :: VetulaPart
  prog = vetula cMajorKey mcmullenYellow drop2

  held1 :: PitchedPart PitchedNote12
  held1 = on vHeld1 ringy (vetulaHeld prog)

  session :: Session
  session = Session
    { devices:     [iac]
    , instruments: [ringy]
    , drumKits:    []
    , parts:       eraseAll [held1]
    }