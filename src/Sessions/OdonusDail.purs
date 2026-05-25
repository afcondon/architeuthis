-- | Sessions.OdonusDail — Thread 2 + Thread 3 smoke test.
-- |
-- | Six parallel Odonus voices on IAC channels 1..6, each demonstrating
-- | one feature combination introduced by Threads 2 and 3:
-- |
-- |   ch1 — Natural / cChromatic     identity (today's behaviour)
-- |   ch2 — Natural / cMinor         chromatic-input quantised to C minor
-- |   ch3 — Equal   / cMajor         input integers as 1-based C-major degrees
-- |   ch4 — Natural / cPhrygianDomLT chromatic-input quantised to a
-- |                                  multi-octave non-repeating scale
-- |   ch5 — chromatic + per-cell ratchet  cells 0..7 retrigger 1,1,2,2,3,3,4,4
-- |   ch6 — chromatic + per-cell probability  cells 0..7 fire with chance
-- |                                            1.0, 1.0, 0.6, 0.6, 0.3, 0.3, 0.1, 0.1
-- |
-- | Each voice uses the same 8-cell note source: `60 61 62 63 64 65 66 67`
-- | — chromatic ascending from middle C.  That makes the four
-- | distribution lenses immediately audible against the same input:
-- |
-- |   ch1 plays the chromatic ladder verbatim.
-- |   ch2 collapses neighbouring half-steps onto C-major neighbours.
-- |   ch3 reads the integers as scale-degrees and unfolds across
-- |        two octaves of C major (each integer one degree higher).
-- |   ch4 quantises across a 24-semitone non-repeating scale —
-- |        Phrygian-dominant below, chromatic leading-tones above.
-- |   ch5 plays the same chromatic ladder but each note retriggers
-- |        N times within its slot, N rising 1→4 across the figure.
-- |   ch6 plays the same chromatic ladder but later notes are
-- |        progressively less likely to fire on any given pass.
-- |
-- | Mute/solo in Live to A/B the lenses against the chromatic baseline
-- | on ch1.  The next steps are:
-- |   - Thread 2.5: a Vetula-published "currently-held-chord" scale,
-- |     so the per-instance scale becomes live-mutable from a chord
-- |     pad rather than session text.
-- |   - Thread 6: Twister 16-virtual-bank surface — knob-pushes flip
-- |     between scale presets and the same way they flip between banks.
module Sessions.OdonusDail where

import Calypso.Prelude
import Studio (iac)
import Data.Functor (map)

-- ---------------------------------------------------------------------------
-- Shared shape — eight cells of chromatic ascent from middle C.  Every
-- ninth slot (indices 8..15) holds 0 / false so the engine has 16-cell
-- arrays in all the spots it expects, but the active first half plays
-- only the ascent.  stepsPerCycle = 8 sweeps the active half once per
-- cycle; at 120 BPM the figure is two notes per beat.
-- ---------------------------------------------------------------------------

chromaticAscentNotes :: Array Int
chromaticAscentNotes =
  [ 60, 61, 62, 63, 64, 65, 66, 67
  , 0,  0,  0,  0,  0,  0,  0,  0
  ]

-- | Gate pattern: cells 0..7 fire, cells 8..15 are rests.  Distinct
-- | from `skip` — skipped cells don't exist in the sequence at all
-- | (cursor hops over), gate-off cells exist in the sequence as
-- | silent steps (cursor lands, no note fires, step takes the same
-- | time as any audible step).  We want rests here so the figure is
-- | a 16-step phrase of `8 notes + 8 rests`, not a continuously
-- | repeating 8-cell loop.
firstHalfActive :: Array Boolean
firstHalfActive =
  [ true,  true,  true,  true,  true,  true,  true,  true
  , false, false, false, false, false, false, false, false
  ]

baseOdonus :: forall s. Int -> Scale -> Distribution -> Odonus s
baseOdonus ch scale dist = odonusOn ch scale dist
  (replicate16 1) (replicate16 1.0)

-- | The Odonus constructor used by every voice in this session.
-- | `ratchet` and `probability` arrays are 16-element; cells 8..15
-- | are inactive (notes are 0) but the arrays still need 16 entries
-- | because the engine indexes by Idx = Y*4 + X.
odonusOn
  :: forall s
   . Int               -- channel
  -> Scale
  -> Distribution
  -> Array Int         -- per-cell ratchet (16 entries)
  -> Array Number      -- per-cell probability (16 entries)
  -> Odonus s
odonusOn ch scale dist ratchetArr probArr = odonusWith
  { device:  iac
  , channel: ch
  , vel:     100
  , durMs:   200
  , stepsPerCycle: 8
  , notes:   chromaticAscentNotes
  , skip:    replicate16 false
  , gate:    firstHalfActive
  , glide:   replicate16 false
  , navMode: NavForward
  , config:
      { stepYNow:     pure false
      , notes:        map pure chromaticAscentNotes
      , skip:         map pure (replicate16 false)
      , ratchet:      map pure ratchetArr
      , probability:  map pure probArr
      , gate:         map pure firstHalfActive
      , glide:        replicate16 (pure false)
      , vel:          replicate16 (pure 100)
      , mod1:         replicate16 (pure 0)
      , mod2:         replicate16 (pure 0)
      , mod3:         replicate16 (pure 0)
      , mod4:         replicate16 (pure 0)
      , scale:        scale
      , distribution: dist
      , advance:      pure true
      }
  }

-- ---------------------------------------------------------------------------
-- The four voices.
-- ---------------------------------------------------------------------------

odonusNaturalChromatic :: Odonus "odonusNaturalChromatic"
odonusNaturalChromatic = baseOdonus 1 cChromatic Natural

odonusNaturalMinor :: Odonus "odonusNaturalMinor"
odonusNaturalMinor = baseOdonus 2 cMinor Natural

odonusEqualMajor :: Odonus "odonusEqualMajor"
odonusEqualMajor = baseOdonus 3 cMajor Equal

odonusNaturalDailLT :: Odonus "odonusNaturalDailLT"
odonusNaturalDailLT = baseOdonus 4 cPhrygianDomLT Natural

-- Per-cell ratchet escalating 1,1,2,2,3,3,4,4 across the active half.
odonusRatchet :: Odonus "odonusRatchet"
odonusRatchet = odonusOn 5 cChromatic Natural
  ratchetArr (replicate16 1.0)
  where
    ratchetArr =
      [ 1, 1, 2, 2, 3, 3, 4, 4
      , 1, 1, 1, 1, 1, 1, 1, 1
      ]

-- Per-cell probability decaying 1.0, 1.0, 0.6, 0.6, 0.3, 0.3, 0.1, 0.1.
odonusProbability :: Odonus "odonusProbability"
odonusProbability = odonusOn 6 cChromatic Natural
  (replicate16 1) probArr
  where
    probArr =
      [ 1.0, 1.0, 0.6, 0.6, 0.3, 0.3, 0.1, 0.1
      , 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0
      ]

-- ---------------------------------------------------------------------------
-- The session value.  All four voices are autonomous, so `parts` is
-- empty.  Devices: just IAC; instruments/drumKits empty since the
-- Odonuses bind their own channels.
-- ---------------------------------------------------------------------------

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
