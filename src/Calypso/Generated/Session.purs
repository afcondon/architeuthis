-- | The current session — what's playing right now.
-- |
-- | Devices, instruments, and drum kits are factored out into Studio
-- | (the rig declaration).  Edit Studio.purs when the rig changes;
-- | edit this file every time you change which notes go where.
module Calypso.Generated.Session where

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
qd1A = on "drums" qd1 (drum "bd bd ~ ~ bd ~ bd ~")

qd1B :: DrumPart
qd1B = on "drums" qd1 (every 8 rev (drum "bd ~ bd bd bd ~ ~ bd"))

qd2A :: DrumPart
qd2A = on "drums" qd2 (drum "~ ~ sn ~ ~ ~ sn ~")

-- ---------------------------------------------------------------------------
-- Pitched parts — `mini` / `d` / `n` produce Pattern PitchedNote12 bound to
-- an Instrument.
-- ---------------------------------------------------------------------------

bass1A :: PitchedPart PitchedNote12
bass1A = on "bass" bass1 (mini "c2 e2 g2 ~ b2 ~ g2 e2")

bass1B :: PitchedPart PitchedNote12
bass1B = on "bass" bass1 (mini "c4 c4 ~ g4 ~ c3 e3 ~")

bass1Deg :: PitchedPart PitchedNote12
bass1Deg = on "bass" bass1 (inKey aHarmonicMinor (d "1 5 3 5 1 3 5 -1"))

bass1Mix :: PitchedPart PitchedNote12
bass1Mix = on "bass" bass1 (inKey dDorian (d "5 5 5 3 3 7 -1"))

-- ---------------------------------------------------------------------------
-- MVP-3 Tintinnabuli demo: M-voice + parallel T-voice on A-minor.
-- Now degree-based: `set-scale aMinor` / `set-scale dDorian` retune the
-- M-voice live (via the Voice emit path's degree resolution).  The
-- T-voice eagerly bakes the scale Pärt declared his piece in — re-arm
-- to refresh against the active scale.
-- ---------------------------------------------------------------------------

mPart :: Pattern PitchedNote12
mPart = d "1 2 3 4 5 4 3 2"

melodyM :: PitchedPart PitchedNote12
melodyM = on "bass" bass1 mPart

melodyT :: PitchedPart PitchedNote12
melodyT = on "bass" bass2 (tintinnabuli aMinor aMinT above1 mPart)

-- ---------------------------------------------------------------------------
-- MVP-4 Fugue Machine demo: 4 playheads on a shared subject.
-- ---------------------------------------------------------------------------

subject :: Pattern PitchedNote12
subject = d "1 5 3 5 1 3 5 -1"

fugue1 :: PitchedPart PitchedNote12
fugue1 = on "fugue" bass1 (fugueVoice defaultVoice subject)

fugue2 :: PitchedPart PitchedNote12
fugue2 = on "fugue" bass2 (fugueVoice (defaultVoice { transpose = 7 }) subject)

fugue3 :: PitchedPart PitchedNote12
fugue3 = on "fugue" bass3 (fugueVoice (defaultVoice { transpose = 7, speed = doubleSpeed }) subject)

fugue4 :: PitchedPart PitchedNote12
fugue4 = on "fugue" bass4 (fugueVoice (defaultVoice { transpose = -3, retrograde = true, speed = halfSpeed }) subject)

intro :: Section
intro = slow (r 8) (cat [armPart bass1A, armPart bass1B])


-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------
--
-- One `eraseAll` per Part-kind, joined with `<>`.  The split mirrors
-- the destination split — pitched parts go to Instruments, drum parts
-- go to DrumKits.
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
