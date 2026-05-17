-- | Tidal.Fugue — multi-voice fan-out from a shared source.
-- |
-- | Inspired by the iPad app **Fugue Machine** (Alexandernaut): one
-- | sequence, N playheads, each playhead with its own transpose,
-- | speed, and direction.  All playheads share the same musical
-- | clock — the voices lock together; only their *projections* of the
-- | source differ.
-- |
-- | Two surfaces:
-- |
-- |   * `Voice` — a record bundling the per-playhead transforms.  The
-- |     fields are independent and compose; `defaultVoice` is the
-- |     identity, and you build a fugue voice by updating one or two
-- |     fields:
-- |
-- |         defaultVoice { transpose = 7 }              -- up a fifth
-- |         defaultVoice { speed = doubleSpeed }        -- twice as fast
-- |         defaultVoice { retrograde = true, transpose = 12 }
-- |
-- |   * `fugueVoice` — apply a `Voice` to a `Pattern Pitch`.  Pure
-- |     function composition: the time-structure and pitch-substrate
-- |     combinators already in scope (`fast`, `slow`, `rev`,
-- |     `transposeChromatic`) do all the work.  This module adds no
-- |     new pattern semantics; it just bundles common parameter sets
-- |     so a Session can declare four playheads on a shared subject
-- |     in four short lines.
-- |
-- | Usage (degree-based subject + live scale):
-- |
-- |     import Tidal.Fugue (Voice, defaultVoice, fugueVoice,
-- |                        doubleSpeed, halfSpeed)
-- |
-- |     -- Raw scale degrees; the active scale (set live via
-- |     -- `set-scale aHarmonicMinor` etc.) governs rendering.
-- |     subject :: Pattern Pitch
-- |     subject = d "1 3 5 8 7 5 3 1"
-- |
-- |     voice1 :: PitchedPart
-- |     voice1 = on "fugue" bass1 (fugueVoice defaultVoice subject)
-- |
-- |     voice2 :: PitchedPart
-- |     voice2 = on "fugue" bass2 (fugueVoice (defaultVoice { transpose = 4 }) subject)
-- |
-- |     voice3 :: PitchedPart
-- |     voice3 = on "fugue" bass3 (fugueVoice
-- |       (defaultVoice { speed = doubleSpeed, transpose = 7 }) subject)
-- |
-- |     voice4 :: PitchedPart
-- |     voice4 = on "fugue" bass4 (fugueVoice
-- |       (defaultVoice { retrograde = true, transpose = -3 }) subject)
-- |
-- | Then `set-scale aHarmonicMinor` and the whole fugue plays in
-- | A harmonic minor; `set-scale dDorian` shifts it (almost) anywhere
-- | else with one wire verb — no re-arming.
-- |
-- | Limits today:
-- |
-- |   * No canon offset (`delay`).  All voices start together at the
-- |     current cycle boundary.  A "voice 2 enters 4 cycles later"
-- |     pattern would need a section-style scheduling primitive on
-- |     top of the conductor — that's a candidate for a future
-- |     `canon :: Rational -> Pattern a -> Pattern a` once we know
-- |     what shape feels natural in play.
-- |   * Loop range (start/end positions on the underlying sequence)
-- |     not modelled.  Use `fastGap` / explicit slicing of the
-- |     subject pattern at call site if you need it.
module Tidal.Fugue
  ( Voice
  , defaultVoice
  , fugueVoice
  -- Speed presets — `Rational` values for the `speed` field.
  , normalSpeed
  , doubleSpeed
  , halfSpeed
  , quadSpeed
  , quarterSpeed
  , eighthSpeed
  ) where

import Prelude

import Data.Rational (Rational, fromInt, (%))

import Tidal.Pattern.Core (fast, rev)
import Tidal.Pattern.Types (Pattern)
import Tidal.Pitch (Pitch)
import Tidal.Scales (transposeDiatonic)

-- ---------------------------------------------------------------------------
-- The Voice record
-- ---------------------------------------------------------------------------

-- | Per-playhead transforms.  All fields are independent and compose
-- | via `fugueVoice` in the order: speed → retrograde → transpose.
-- |
-- | `speed` is a `Rational` because Tidal's `fast`/`slow` semantics
-- | are rational: `fast 2 pat` plays the pattern twice per cycle,
-- | `fast (1/2) pat` is the half-speed form.  Use the named presets
-- | (`doubleSpeed`, `halfSpeed`, …) for readability, or any
-- | `Rational` literal via `r` / `(% )`.
-- |
-- | `transpose` is in **scale degrees** (diatonic), not semitones.
-- | This keeps the fugue holding together under live `set-scale`
-- | changes: each voice stays the same degree-shift away from the
-- | subject, so modulating the whole rig with one wire verb shifts
-- | the entire fugue coherently.  Feed the subject as raw degrees
-- | (`d "1 3 5 8 7 5 3 1"`, no `inKey` wrapper) so the global scale
-- | bus governs rendering at emit time.  For chromatic alterations
-- | inside the subject itself, write the chromatic notes there;
-- | `Chromatic` events pass through `transposeDiatonic` untouched.
-- | +1 = up one scale degree, +4 ≈ a fifth, +7 ≈ an octave (in a
-- | heptatonic scale).
-- |
-- | `retrograde` plays the underlying pattern backwards — voice 4 of
-- | a canon-by-retrograde, for example.
type Voice =
  { transpose  :: Int
  , speed      :: Rational
  , retrograde :: Boolean
  }

-- | The identity voice: no transpose, normal speed, forward.  Build
-- | other voices by record-update from this:
-- |
-- |     defaultVoice { transpose = 7, speed = halfSpeed }
defaultVoice :: Voice
defaultVoice =
  { transpose: 0
  , speed: normalSpeed
  , retrograde: false
  }

-- ---------------------------------------------------------------------------
-- The transform
-- ---------------------------------------------------------------------------

-- | Apply one Voice's transforms to a source pattern.  The fields
-- | are stacked left-to-right: speed first (rescales the time axis),
-- | then retrograde (mirrors the rescaled stream), then transpose
-- | (chromatic semitone shift).
-- |
-- | Identity short-cuts when fields are at their defaults avoid
-- | wrapping the source in no-op functors — useful when the
-- | `Voice` is `defaultVoice` itself (voice 1 of a fugue: the
-- | unprocessed subject).
fugueVoice :: Voice -> Pattern Pitch -> Pattern Pitch
fugueVoice v src =
  let
    withSpeed =
      if v.speed == normalSpeed then src else fast v.speed src
    withDir =
      if v.retrograde then rev withSpeed else withSpeed
    withTrans =
      if v.transpose == 0 then withDir
      else transposeDiatonic v.transpose withDir
  in
    withTrans

-- ---------------------------------------------------------------------------
-- Speed presets
-- ---------------------------------------------------------------------------

-- | `r 1` — one cycle of the source per cycle of the clock.
normalSpeed :: Rational
normalSpeed = fromInt 1

-- | `r 2` — the source plays twice as fast as the clock.
doubleSpeed :: Rational
doubleSpeed = fromInt 2

-- | `1/2` — the source plays at half clock speed (one half of the
-- | source per clock cycle; full source takes two cycles).
halfSpeed :: Rational
halfSpeed = 1 % 2

-- | `r 4` — quadruple time.
quadSpeed :: Rational
quadSpeed = fromInt 4

-- | `1/4` — quarter speed.
quarterSpeed :: Rational
quarterSpeed = 1 % 4

-- | `1/8` — eighth speed.  Fugue Machine's slowest preset.
eighthSpeed :: Rational
eighthSpeed = 1 % 8
