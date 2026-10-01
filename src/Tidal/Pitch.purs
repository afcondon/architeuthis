-- | The substrate's pitch carrier.
-- |
-- | A `PitchedNote12` is one of three things:
-- |
-- |   * `Chromatic n` — absolute MIDI note number `n`. What you mean
-- |     when you write `c4`: middle C, independent of any scale.
-- |   * `Degree d` — the `d`-th note of whatever scale is active.
-- |     Stays unresolved as far as possible; the voice renders it to
-- |     MIDI at emit time using the current scale, so a wire-level
-- |     scale change re-renders every running degree pattern on the
-- |     next tick.
-- |   * `Sample s` — a non-pitched token (`"bd"`, `"sn"`, `"cp"`).
-- |     Carries through to the dispatcher's sample-name resolution
-- |     unchanged.
-- |
-- | One carrier across all three intents lets every time-structure
-- | combinator (`every`, `rev`, `fast`, `slow`, `cat`, `stack`, …)
-- | apply identically to drum, pitched, and degree patterns. PitchedNote12-
-- | aware operations dispatch on variant.
-- |
-- | See `Tidal.Scales` for `Scale`, `inKey`, and the diatonic /
-- | chromatic transpose operators that consume this carrier.
module Tidal.Pitch
  ( PitchedNote12(..)
  , pitchToken
  , pitchToNumber
  , patternPitchToNumber
  ) where

import Prelude

import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Tidal.Pattern.Types (Pattern, class TidalEnum, enumRange)

-- ---------------------------------------------------------------------------
-- The variant
-- ---------------------------------------------------------------------------

-- | The pitch carrier. See module header for variant semantics.
data PitchedNote12
  = Degree    Int     -- ^ Scale-relative; resolves at emit time.
  | Chromatic Int     -- ^ Absolute MIDI note number (0..127).
  | Sample    String  -- ^ Non-pitched token name.

derive instance eqPitch :: Eq PitchedNote12
derive instance ordPitch :: Ord PitchedNote12

instance showPitch :: Show PitchedNote12 where
  show = case _ of
    Degree d    -> "Degree " <> show d
    Chromatic n -> "Chromatic " <> show n
    Sample s    -> "Sample " <> show s

-- | Render a PitchedNote12 to its dispatcher-facing token string, *without*
-- | consulting any scale.  `Chromatic 60` → `"60"`, `Sample "bd"` →
-- | `"bd"`.  A `Degree` value has no scale-free rendering, so it
-- | returns `"?<n>"`; callers that hit this with a Degree have
-- | dropped the scale-resolution step somewhere upstream.
-- |
-- | This is the very last step before a token leaves PureScript for
-- | the Erlang dispatcher.  The dispatcher then maps Sample names
-- | through its binding registry and parses Chromatic numerics as
-- | direct MIDI notes.
pitchToken :: PitchedNote12 -> String
pitchToken = case _ of
  Chromatic n -> show n
  Sample s    -> s
  Degree d    -> "?" <> show d

-- | Coerce a single `PitchedNote12` to a Number for continuous-voice dispatch.
-- | `Chromatic n` → `n` as Number (raw MIDI value); `Sample s` →
-- | `Number.fromString s` or `0.0`; `Degree d` → `d` as Number (no
-- | scale context here, so degree-into-continuous is the raw integer).
-- |
-- | Used by `patternPitchToNumber` for the rare case of a typed-cue
-- | body being routed to a continuous voice (e.g. an LFO-shape cue
-- | armed against a `midi-cc-cont` voice).
pitchToNumber :: PitchedNote12 -> Number
pitchToNumber = case _ of
  Chromatic n -> Int.toNumber n
  Sample s    -> case Number.fromString s of
    Just n -> n
    Nothing -> 0.0
  Degree d -> Int.toNumber d

-- | Companion to `Tidal.Pattern.Core.patternStringToNumber` for the
-- | typed-cue path.  Used by `play-armed` when the bound voice is
-- | continuous (`midi-cc-cont` / `cv-cont`) — the cue body is
-- | `Pattern PitchedNote12`, the voice expects `Pattern Number`.
patternPitchToNumber :: Pattern PitchedNote12 -> Pattern Number
patternPitchToNumber = map pitchToNumber

-- ---------------------------------------------------------------------------
-- TidalEnum — for `..` range expansion in mini-notation.
-- ---------------------------------------------------------------------------

-- | Enumeration semantics:
-- |
-- |   * `Chromatic a .. Chromatic b` → chromatic scale between two
-- |     absolute notes.  Mirrors the existing Note enum.
-- |   * `Degree a .. Degree b` → degrees between `a` and `b` inclusive.
-- |     Octave wrap is the scale's problem, not the enum's.
-- |   * Mixed or `Sample`: no meaningful enumeration; falls back to
-- |     the start value.
instance tidalEnumPitch :: TidalEnum PitchedNote12 where
  enumRange (Chromatic from) (Chromatic to)
    | from <= to = map Chromatic (enumRange from to)
    | otherwise  = map Chromatic (enumRange from to)
  enumRange (Degree from) (Degree to)
    | from <= to = map Degree (enumRange from to)
    | otherwise  = map Degree (enumRange from to)
  enumRange from _ = [from]
  -- Chords are not parsed for pitches; a value passes through.
  addSemitones _ x = x
