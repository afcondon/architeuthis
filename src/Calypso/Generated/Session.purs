-- | The current session — what's playing right now.
-- |
-- | Devices + instruments are factored out into Studio (the rig
-- | declaration).  Edit Studio.purs when the rig changes; edit
-- | this file every time you change which notes go where.
module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (fh2, fh2qd, iac, qd1, qd2, bass1, bass2, bass3, bass4)
import Tidal.Fugue
  ( Voice, defaultVoice, fugueVoice
  , doubleSpeed, halfSpeed, quarterSpeed
  )

-- ---------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------

qd1A :: PitchedPart
qd1A = on "drums" qd1 (mini "bd bd ~ ~ bd ~ bd ~")

qd1B :: PitchedPart
qd1B = on "drums" qd1 (every 8 rev (mini "bd ~ bd bd bd ~ ~ bd"))

qd2A :: PitchedPart
qd2A = on "drums" qd2 (mini "~ ~ sn ~ ~ ~ sn ~")

bass1A :: PitchedPart
bass1A = on "bass" bass1 (mini "c2 e2 g2 ~ b2 ~ g2 e2")

bass1B :: PitchedPart
bass1B = on "bass" bass1 (mini "c4 c4 ~ g4 ~ c3 e3 ~")

bass1Deg :: PitchedPart
bass1Deg = on "bass" bass1 (inKey aHarmonicMinor (d "1 5 3 5 1 3 5 -1"))

bass1Mix :: PitchedPart
bass1Mix = on "bass" bass1 (inKey dDorian (d "5 5 5 3 3 7 -1"))

-- ---------------------------------------------------------------------------
-- MVP-3 Tintinnabuli demo: M-voice + parallel T-voice on A-minor.
-- ---------------------------------------------------------------------------

mPart :: Pattern Pitch
mPart = mini "a4 b4 c5 d5 e5 d5 c5 b4"

melodyM :: PitchedPart
melodyM = on "bass" bass1 mPart

melodyT :: PitchedPart
melodyT = on "bass" bass2 (tintinnabuli aMinT above1 mPart)

-- ---------------------------------------------------------------------------
-- MVP-4 Fugue Machine demo: 4 playheads on a shared subject.
-- ---------------------------------------------------------------------------

-- Subject in RAW DEGREES (no `inKey` wrap) so the global scale bus
-- governs rendering and diatonic transpose can operate.  Fire
-- `set-scale aHarmonicMinor` once at boot; `set-scale dDorian` etc.
-- to modulate the whole fugue live.
subject :: Pattern Pitch
subject = d "1 5 3 5 1 3 5 -1"

fugue1 :: PitchedPart
fugue1 = on "fugue" bass1 (fugueVoice defaultVoice subject)

fugue2 :: PitchedPart
fugue2 = on "fugue" bass2 (fugueVoice (defaultVoice { transpose = 7 }) subject)

fugue3 :: PitchedPart
fugue3 = on "fugue" bass3 (fugueVoice (defaultVoice { transpose = 7, speed = doubleSpeed }) subject)

fugue4 :: PitchedPart
fugue4 = on "fugue" bass4 (fugueVoice (defaultVoice { transpose = -3, retrograde = true, speed = halfSpeed }) subject)

intro :: Section
intro = slow (r 8) (cat [armPart bass1A, armPart bass1B])


-- ---------------------------------------------------------------------------
-- The Session value
-- ---------------------------------------------------------------------------
--
-- After PR 1: a single `map erase` over a homogeneous Part array.
-- The phantom-mvoice per-element `anyCue` wrapping is gone.
session :: Session
session = Session
  { devices:     [fh2, fh2qd, iac]
  , instruments: [qd1, qd2, bass1, bass2, bass3, bass4]
  , parts: eraseAll
      [ qd1A, qd1B, qd2A
      , bass1A, bass1B
      , bass1Deg, bass1Mix
      , melodyM, melodyT
      , fugue1, fugue2, fugue3, fugue4
      ]
  }
