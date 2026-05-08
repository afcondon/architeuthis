-- | Shared dispatch helpers used by both the legacy MIDIScheduler
-- | dispatch path and the per-voice tree's dispatcher. Extracted from
-- | `Tidal.MIDIScheduler` in PR1.4e so the dispatcher doesn't have to
-- | import from the scheduler module that's being dismantled.
-- |
-- | These helpers are pure functions over pattern tokens / numeric
-- | values; nothing here knows about the scheduler tick or any
-- | runtime state.
module Tidal.Dispatch.Helpers
  ( noteNameMidi
  , interpretCV
  , clamp7bit
  , param7bit
  , voctValue
  , samplePatternAt
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.Rational (Rational, fromInt)
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))
import Tidal.Binding as Binding
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Event(..), Pattern)

-- | Convert a MIDI note number to a digital CV value at 1V/octave on
-- | the ES-9's ±10V → digital ±1.0 scale: `value = midiNote / 120.0`.
-- | Examples: MIDI 0 (C-1) → 0.0 (0V), MIDI 60 (C4 / middle C) → 0.5
-- | (5V), MIDI 120 (C9) → 1.0 (10V).
voctValue :: Int -> Number
voctValue midiNote = Int.toNumber midiNote / 120.0

-- | Note name → MIDI number (C-1 = 0, C0 = 12, C4 = 60, etc.).
-- | Covers C0..C8. Tokens outside this range return Nothing — callers
-- | typically fall back to a binding default for unknown tokens.
-- |
-- | Each sharp (`cs`, `ds`, `fs`, `gs`, `as`) is also registered with
-- | the conventional `#` spelling (`c#`, `d#`, `f#`, `g#`, `a#`) so
-- | users who don't know Tidal's `s`-suffix idiom can still get a
-- | sharp. Both spellings resolve to the same MIDI number.
noteNameMidi :: Map String Int
noteNameMidi = Map.fromFoldable (entries <> sharpAliases entries)
  where
    entries :: Array (Tuple String Int)
    entries =
      [ Tuple "c0"  12, Tuple "cs0" 13, Tuple "d0"  14, Tuple "ds0" 15
      , Tuple "e0"  16, Tuple "f0"  17, Tuple "fs0" 18, Tuple "g0"  19
      , Tuple "gs0" 20, Tuple "a0"  21, Tuple "as0" 22, Tuple "b0"  23
      , Tuple "c1"  24, Tuple "cs1" 25, Tuple "d1"  26, Tuple "ds1" 27
      , Tuple "e1"  28, Tuple "f1"  29, Tuple "fs1" 30, Tuple "g1"  31
      , Tuple "gs1" 32, Tuple "a1"  33, Tuple "as1" 34, Tuple "b1"  35
      , Tuple "c2"  36, Tuple "cs2" 37, Tuple "d2"  38, Tuple "ds2" 39
      , Tuple "e2"  40, Tuple "f2"  41, Tuple "fs2" 42, Tuple "g2"  43
      , Tuple "gs2" 44, Tuple "a2"  45, Tuple "as2" 46, Tuple "b2"  47
      , Tuple "c3"  48, Tuple "cs3" 49, Tuple "d3"  50, Tuple "ds3" 51
      , Tuple "e3"  52, Tuple "f3"  53, Tuple "fs3" 54, Tuple "g3"  55
      , Tuple "gs3" 56, Tuple "a3"  57, Tuple "as3" 58, Tuple "b3"  59
      , Tuple "c4"  60, Tuple "cs4" 61, Tuple "d4"  62, Tuple "ds4" 63
      , Tuple "e4"  64, Tuple "f4"  65, Tuple "fs4" 66, Tuple "g4"  67
      , Tuple "gs4" 68, Tuple "a4"  69, Tuple "as4" 70, Tuple "b4"  71
      , Tuple "c5"  72, Tuple "cs5" 73, Tuple "d5"  74, Tuple "ds5" 75
      , Tuple "e5"  76, Tuple "f5"  77, Tuple "fs5" 78, Tuple "g5"  79
      , Tuple "gs5" 80, Tuple "a5"  81, Tuple "as5" 82, Tuple "b5"  83
      , Tuple "c6"  84, Tuple "cs6" 85, Tuple "d6"  86, Tuple "ds6" 87
      , Tuple "e6"  88, Tuple "f6"  89, Tuple "fs6" 90, Tuple "g6"  91
      , Tuple "gs6" 92, Tuple "a6"  93, Tuple "as6" 94, Tuple "b6"  95
      , Tuple "c7"  96, Tuple "cs7" 97, Tuple "d7"  98, Tuple "ds7" 99
      , Tuple "e7" 100, Tuple "f7" 101, Tuple "fs7" 102, Tuple "g7" 103
      , Tuple "gs7" 104, Tuple "a7" 105, Tuple "as7" 106, Tuple "b7" 107
      , Tuple "c8" 108
      ]

    -- | For each `<letter>s<octave>` entry, also expose `<letter>#<octave>`
    -- | so `f#2` and `fs2` both resolve to MIDI 30.
    sharpAliases :: Array (Tuple String Int) -> Array (Tuple String Int)
    sharpAliases = Array.mapMaybe \(Tuple name n) ->
      case SCU.toCharArray name of
        [ letter, 's', oct ] -> Just (Tuple (SCU.fromCharArray [letter, '#', oct]) n)
        _ -> Nothing

-- | Interpret a pattern token according to a CV mapping mode.
-- |   LiteralValue   → parse as Number
-- |   NoteNameVoct   → parse as note name → 1V/oct on ±10V→±1.0 scale
-- |   SampleNameMap  → lookup
-- |   LiteralOrNote  → try Number first, fall back to V/oct lookup;
-- |                    used by the legacy `cv <bus> <pat>` verb's
-- |                    synthetic bindings (per-token permissive).
interpretCV :: Binding.CVMapping -> String -> Maybe Number
interpretCV = case _ of
  Binding.LiteralValue -> Number.fromString
  Binding.NoteNameVoct -> \tok ->
    case Map.lookup tok noteNameMidi of
      Just midi -> Just (voctValue midi)
      Nothing -> Nothing
  Binding.SampleNameMap m -> \tok -> Map.lookup tok m
  Binding.LiteralOrNote -> \tok ->
    case Number.fromString tok of
      Just n -> Just n
      Nothing -> case Map.lookup tok noteNameMidi of
        Just midi -> Just (voctValue midi)
        Nothing -> Nothing

-- | Clamp a Number to MIDI's 7-bit range [0..127] and floor it.
clamp7bit :: Number -> Int
clamp7bit n
  | n < 0.0   = 0
  | n > 127.0 = 127
  | otherwise = Int.floor n

-- | Parse a parameter token as a 7-bit integer in [0..127].  Used for
-- | the `# vel ...` and (future) `# cc... ...` overrides where the
-- | wire byte is bounded.  Out-of-range values fall back to Nothing
-- | so the dispatcher uses the binding default rather than wrap.
param7bit :: String -> Maybe Int
param7bit tok = case Number.fromString tok of
  Just n | n >= 0.0 && n <= 127.0 -> Just (Int.floor n)
  _ -> Nothing

-- | Sample a pattern at a single cycle time. Used both for `#`
-- | parameter joins (voice samples each param pattern at the
-- | structure event's cycle position) and for continuous-voice
-- | dispatch (MIDIScheduler samples a Pattern Number once per tick).
-- |
-- | The query uses a thin `[t, t+ε)` window so digital half-open arc
-- | semantics return the event whose value is current at the start.
-- | Epsilon must be positive — a zero-width query at the arc start
-- | would return [] for digital events.
samplePatternAt :: forall a. Rational -> Pattern a -> Maybe a
samplePatternAt cycleAt pat =
  let
    epsilon = fromInt 1 / fromInt 1000000
    events = queryArc pat cycleAt (cycleAt + epsilon)
  in case Array.head events of
    Just (Digital ev) -> Just ev.value
    Just (Analog ev) -> Just ev.value
    Nothing -> Nothing
