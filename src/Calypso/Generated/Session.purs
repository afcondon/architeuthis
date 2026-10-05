module Calypso.Generated.Session where

import Calypso.Prelude
import Studio (iac, bass1, bass2, bass3, bass4)

-- Genre: house (seed 64)
-- house | e mixolydian | density 0.47

drumsKit :: DrumKit
drumsKit = midiDrumKit iac 10
  [ hit "bd" 36 100 50
  , hit "sn" 38 100 50
  , hit "rim" 37 90 30
  , hit "cp" 39 100 30
  , hit "hh" 42 80 30
  , hit "oh" 46 80 60
  , hit "shaker" 82 70 25
  , hit "perc" 64 90 40
  , hit "ride" 51 80 50
  , hit "crash" 49 90 80
  , hit "lt" 45 100 40
  , hit "mt" 47 100 40
  , hit "ht" 50 100 40
  , hit "cr" 49 90 80
  , hit "rd" 51 80 60
  , hit "maracas" 48 90 25
  , hit "timbale" 47 100 40
  , hit "cowbell" 50 100 40
  , hit "congahi" 43 100 40
  , hit "congalo" 40 100 40
  , hit "clave" 51 100 30
  , hit "shekere" 48 90 25
  , hit "block" 37 100 30
  , hit "agogo" 50 100 30
  ]

part0 :: PitchedPart
part0 = on vBass bass1 (swingByR 16 96 4 (rev (inKey cMixolydian (degree "0 ~ 0 ~ 4 ~ 2 ~ 0 ~ 0 ~ 4 ~ 2 ~"))))

part1 :: PitchedPart
part1 = on vFugue bass2 (swingByR 16 96 4 (rev (inKey cMixolydian (degree "~ ~ [0,2,4] ~ ~ ~ [0,2,4] ~ ~ ~ [0,2,4] ~ ~ ~ [0,2,4] ~"))))

partDrums :: DrumPart
partDrums = on vDrums drumsKit (swingByR 16 96 4 (stack [ (toPattern (drum "bd ~ ~ ~ bd ~ ~ ~ bd ~ ~ ~ bd ~ ~ ~") # gain "1.0 ~ ~ ~ 1.0 ~ ~ ~ 1.0 ~ ~ ~ 1.0 ~ ~ ~"), (toPattern (drum "~ ~ ~ ~ cp ~ ~ ~ ~ ~ ~ ~ cp ~ ~ ~") # gain "~ ~ ~ ~ 1.0 ~ ~ ~ ~ ~ ~ ~ 1.0 ~ ~ ~"), (toPattern (drum "~ ~ hh ~ ~ ~ hh ~ ~ ~ hh ~ ~ ~ hh ~") # gain "~ ~ 1.0 ~ ~ ~ 1.0 ~ ~ ~ 1.0 ~ ~ ~ 1.0 ~") ]))

piece :: Section
piece = stack [ armPart part0, armPart part1, armPart partDrums ]

session :: Session
session = Session
  { devices:     [iac]
  , instruments: [bass1, bass2, bass3, bass4]
  , drumKits:    [drumsKit]
  , parts:       eraseAll [ part0, part1 ] <+> eraseAll [ partDrums ]
  }
