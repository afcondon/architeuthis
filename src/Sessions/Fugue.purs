-- | Sessions.Fugue — 4-voice fugue + drum parts.
-- |
-- | Use case: tutorial / demo of the Tidal.Fugue substrate.  Four
-- | playheads share a subject (the `d "1 5 3 5 1 3 5 -1"` line);
-- | fugue1..fugue4 each apply their own Voice transform (transpose,
-- | retrograde, speed) to it.  Plus a couple of drum cells from qd1
-- | / qd2 for groove.
-- |
-- | This is the original demo session that lived in
-- | `src/Calypso/Generated/Session.purs` before the session-library
-- | refactor.  No autonomous machines — every voice is a cell-fired
-- | Part.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), then fire-typeful.
module Sessions.Fugue where

import Calypso.Prelude
import Studio (fh2, fh2qd, iac, qd1, qd2, bass1, bass2, bass3, bass4)
import Tidal.Fugue
  ( Voice, defaultVoice, fugueVoice
  , doubleSpeed, halfSpeed, quarterSpeed
  )

-- ---------------------------------------------------------------------------
-- Drum parts — `drum "..."` produces Pattern DrumHitRef bound to a
-- DrumKit destination.
-- ---------------------------------------------------------------------------

qd1A :: DrumPart
qd1A = on vDrums qd1 (drum "bd bd ~ ~ bd ~ bd ~")

qd1B :: DrumPart
qd1B = on vDrums qd1 (every 8 rev (drum "bd ~ bd bd bd ~ ~ bd"))

qd2A :: DrumPart
qd2A = on vDrums qd2 (drum "~ ~ sn ~ ~ ~ sn ~")

-- ---------------------------------------------------------------------------
-- Pitched parts — `mini` / `d` / `n` produce Pattern PitchedNote12 bound to
-- an Instrument.
-- ---------------------------------------------------------------------------

bass1A :: PitchedPart PitchedNote12
bass1A = on vBass bass1 (pitch "c2 e2 g2 ~ b2 ~ g2 e2")

bass1B :: PitchedPart PitchedNote12
bass1B = on vBass bass1 (pitch "c4 c4 ~ g4 ~ c3 e3 ~")

bass1Deg :: PitchedPart PitchedNote12
bass1Deg = on vBass bass1 (inKey aHarmonicMinor (degree "1 5 3 5 1 3 5 -1"))

bass1Mix :: PitchedPart PitchedNote12
bass1Mix = on vBass bass1 (inKey dDorian (degree "5 5 5 3 3 7 -1"))

-- ---------------------------------------------------------------------------
-- MVP-3 Tintinnabuli demo: M-voice + parallel T-voice on A-minor.
-- ---------------------------------------------------------------------------

mPart = degree "1 2 3 4 5 4 3 2"

melodyM :: PitchedPart PitchedNote12
melodyM = on vBass bass1 mPart

melodyT :: PitchedPart PitchedNote12
melodyT = on vBass bass2 (tintinnabuli aMinor aMinT above1 mPart)

-- ---------------------------------------------------------------------------
-- MVP-4 Fugue Machine demo: 4 playheads on a shared subject.
-- ---------------------------------------------------------------------------

subject = degree "1 5 3 5 1 3 5 -1"

fugue1 :: PitchedPart PitchedNote12
fugue1 = on vFugue bass1 (fugueVoice defaultVoice subject)

fugue2 :: PitchedPart PitchedNote12
fugue2 = on vFugue bass2 (fugueVoice (defaultVoice { transpose = 7 }) subject)

fugue3 :: PitchedPart PitchedNote12
fugue3 = on vFugue bass3 (fugueVoice (defaultVoice { transpose = 7, speed = doubleSpeed }) subject)

fugue4 :: PitchedPart PitchedNote12
fugue4 = on vFugue bass4 (fugueVoice (defaultVoice { transpose = -3, retrograde = true, speed = halfSpeed }) subject)

intro :: Section
intro = slow (r 8) (cat [armPart bass1A, armPart bass1B])


-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:     [fh2, fh2qd, iac]
  , instruments: [bass1, bass2, bass3, bass4]
  , drumKits:    [qd1, qd2]
  , parts: eraseAll [ bass1A, bass1B, bass1Deg, bass1Mix
                    , melodyM, melodyT
                    , fugue1, fugue2, fugue3, fugue4
                    ]
       <+> eraseAll [ qd1A, qd1B, qd2A ]
  }
