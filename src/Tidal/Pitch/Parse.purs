-- | PitchedNote12-typed parsers — the user-facing entry points for cell and
-- | cue bodies.
-- |
-- | Two parsers (`pitch`, `degree`) produce `Pattern PitchedNote12`.  The
-- | drum-pattern parser lives in `Tidal.Drum` and produces a separate
-- | `Pattern String`.
-- |
-- |   * `pitch` — Tidal mini-notation parsed strictly as chromatic
-- |     pitch.  Tokens that parse as a note name (`c4`, `fs3`, `bb2`) or
-- |     numeric value (`60`, `60.5`) resolve to `Chromatic`; anything
-- |     else silences (the parser produces a `Sample` value that the
-- |     dispatcher does not render on pitched destinations).  Use this
-- |     when the body is a melodic line, not a drum part.
-- |
-- |   * `degree` — scale degrees.  Each integer token becomes a
-- |     `Degree`; non-integer tokens silence.  Degrees stay unresolved
-- |     through the substrate; the voice renders them at emit time
-- |     using the active scale.  Wire-level `set-scale c-mixolydian`
-- |     re-renders every running degree pattern on the next tick.
-- |
-- | The parser itself produces `Pattern String` (mini-notation doesn't
-- | know about pitches).  Each entry point fmaps a token-classification
-- | step over the result; that's where the `String → PitchedNote12`
-- | decision lives.  Failures from the parser become `silence` — a typo
-- | in a cell goes quiet rather than killing the rig.
module Tidal.Pitch.Parse
  ( pitch
  , degree
  , pitchTok
  , degreeTok
  ) where

import Prelude

import Data.Array as Array
import Data.Functor (map)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String.CodeUnits as SCU
import Tidal.Dispatch.Helpers (noteNameMidi)
import Tidal.MiniNotation (MiniNotation, miniTyped)
import Tidal.Pitch (PitchedNote12(..))

-- | Parse mini-notation into a `Pattern PitchedNote12` with strict
-- | chromatic semantics: each token must resolve to a `Chromatic` value
-- | (note name or MIDI integer), otherwise it silences.
-- |
-- |   * Note name (`c4`, `fs3`, `bb2`) → `Chromatic <midi>`
-- |   * Integer (`60`)                 → `Chromatic 60`
-- |   * Decimal numeric (`60.5`)       → `Chromatic 60` (floored)
-- |   * Anything else                  → silenced
-- |
-- | A typo like `e44` produces no audible event; the strict contract
-- | means a misspelling fails loud-by-silence rather than misrouting as
-- | a Sample.  To mix pitched and sample tokens in one body, compose
-- | two parsers (e.g. `fastCat [pitch "c4 e4", drum "bd"]`) rather than
-- | relying on auto-classification.
-- |
-- | Examples:
-- |
-- | ```
-- | pitch "c4 e4 g4"     -- three Chromatic events per cycle
-- | pitch "c4 60 e4"     -- mixing note-names and MIDI numbers is fine
-- | pitch "c4*4"         -- four chromatic c4s per cycle
-- | pitch "[c4 e4] g4*2" -- grouped sequencing of Chromatics
-- | pitch "<c4 e4>"      -- alternation
-- | pitch "c4(3,8)"      -- Euclidean Chromatics
-- | ```
pitch :: String -> MiniNotation PitchedNote12
pitch = map pitchTok <<< miniTyped

-- | Parse mini-notation as scale degrees.  Each integer token becomes
-- | a `Degree`; non-integer tokens silence.
-- |
-- | Degrees stay unresolved through the substrate; the voice renders
-- | them at emit time using the active scale.  Wire-level
-- | `set-scale c-mixolydian` re-renders every running degree pattern
-- | on the next tick.
degree :: String -> MiniNotation PitchedNote12
degree = map degreeTok <<< miniTyped

-- ---------------------------------------------------------------------------
-- Token → PitchedNote12 classifiers
-- ---------------------------------------------------------------------------

-- | `pitch`'s per-token rule.  Non-chromatic tokens fall through to
-- | `Sample`, which the dispatcher silences on pitched destinations.
-- | (Conceptually "silence"; encoded as Sample because PitchedNote12
-- | doesn't currently have a dedicated silence variant — adding one is
-- | a substrate change for another day.)
-- |
-- | Named with the `Tok` suffix (not `Token`) to avoid colliding with
-- | `Tidal.Pitch.pitchToken :: PitchedNote12 -> String` (the inverse:
-- | render a pitch as a token string).
pitchTok :: String -> PitchedNote12
pitchTok tok = case noteFromName tok of
  Just m  -> Chromatic m
  Nothing -> case Number.fromString tok of
    Just num -> Chromatic (Int.floor num)
    Nothing -> Sample tok

-- | `degree`'s per-token rule.
degreeTok :: String -> PitchedNote12
degreeTok tok = case Int.fromString tok of
  Just i  -> Degree i
  Nothing -> Sample tok

-- ---------------------------------------------------------------------------
-- Note-name resolution
-- ---------------------------------------------------------------------------
-- The mini parser parses chord-suffixed tokens like `c4'maj7` as
-- single atoms; for the chromatic-pitch surface we look at the
-- bare-note prefix and treat the chord suffix as "this is a note,
-- ignore the suffix for now" (chord expansion is a later MVP).

-- | Resolve a token to a chromatic MIDI note number if its prefix
-- | matches `noteNameMidi`.  Strips a trailing apostrophe-chord
-- | suffix (`c4'maj7` → `c4`).
noteFromName :: String -> Maybe Int
noteFromName tok =
  let bare = stripApostropheChord tok
  in Map.lookup bare noteNameMidi

stripApostropheChord :: String -> String
stripApostropheChord tok =
  SCU.fromCharArray (Array.takeWhile (\c -> c /= '\'') (SCU.toCharArray tok))
