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
-- | Usage:
-- |
-- |     import Tidal.Fugue (Voice, defaultVoice, fugueVoice,
-- |                        doubleSpeed, halfSpeed)
-- |
-- |     subject :: Pattern Pitch
-- |     subject = mini "c4 e4 g4 c5 b4 g4 e4 c4"
-- |
-- |     voice1 :: Cue "fugue"
-- |     voice1 = on bass1 (fugueVoice defaultVoice subject)
-- |
-- |     voice2 :: Cue "fugue"
-- |     voice2 = on bass2 (fugueVoice (defaultVoice { transpose = 7 }) subject)
-- |
-- |     voice3 :: Cue "fugue"
-- |     voice3 = on bass3 (fugueVoice
-- |       (defaultVoice { speed = doubleSpeed, transpose = 12 }) subject)
-- |
-- |     voice4 :: Cue "fugue"
-- |     voice4 = on bass4 (fugueVoice
-- |       (defaultVoice { retrograde = true, transpose = -5 }) subject)
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
import Tidal.Scales (transposeChromatic)

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
-- | `transpose` is in semitones — chromatic, not diatonic.  For
-- | diatonic transposition over an active scale, post-compose with
-- | `transposeDiatonic` from `Tidal.Scales` at the cue site rather
-- | than adding a second transpose field here.
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
      else transposeChromatic v.transpose withDir
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
