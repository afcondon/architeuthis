-- | Sessions.Dail — Thread 1 smoke test (Tidal.Scales multi-octave +
-- | Distribution modes, inspired by Instruō Dail's quantiser engine).
-- |
-- | Tests the new Scale + Distribution machinery through the existing
-- | Voice path: bass1 → IAC Driver Tidal → Ableton ch1.  The eDSL has
-- | not yet been wired into Odonus (that's Thread 2); these cells
-- | exercise the substrate by way of `inKey` / `quantiseInKey` on a
-- | per-cell scale.
-- |
-- | Each cell hits bass1 (ch 1) so you can A/B them through a single
-- | simple synth in Live without re-patching.  Recommended setup: an
-- | Analog/Operator/Wavetable on ch 1, polyphonic, generous release —
-- | the multi-octave cells produce wide pitch ranges and you want to
-- | hear them clearly.
-- |
-- | Single-line cell bodies — Calypso's typeful projector picks up the
-- | first line of each definition into the Voice Cells pane, so the
-- | whole RHS needs to live on one line for the cards to differentiate.
module Sessions.Dail where

import Calypso.Prelude
import Studio (iac, bass1)

baselineMajor :: PitchedPart PitchedNote12
baselineMajor = on vBass bass1 (inKey cMajor (degree "1 2 3 4 5 6 7 8 9 10 11 12 13 14"))

phrygianDomLT :: PitchedPart PitchedNote12
phrygianDomLT = on vBass bass1 (inKey cPhrygianDomLT (degree "1 2 3 4 5 6 7 8 9 10 11 12 13 14"))

triad3oct :: PitchedPart PitchedNote12
triad3oct = on vBass bass1 (inKey cMajorTriad3oct (degree "1 2 3 4 5 6 7 8 9"))

chromaticQuantised :: PitchedPart PitchedNote12
chromaticQuantised = on vBass bass1 (quantiseInKey cMajor (pitch "c4 c#4 d4 d#4 e4 f4 f#4 g4"))

chromaticQuantisedMultiOct :: PitchedPart PitchedNote12
chromaticQuantisedMultiOct = on vBass bass1 (quantiseInKey cPhrygianDomLT (pitch "c4 c#4 d4 d#4 e4 c5 c#5 d5"))

session :: Session
session = Session
  { devices:     [iac]
  , instruments: [bass1]
  , drumKits:    []
  , parts: eraseAll [ baselineMajor
                    , phrygianDomLT
                    , triad3oct
                    , chromaticQuantised
                    , chromaticQuantisedMultiOct
                    ]
  }
