-- | PitchedNote12-typed parsers — the user-facing entry points for cell and
-- | cue bodies.
-- |
-- | Three parsers, three semantic intents, all producing
-- | `Pattern PitchedNote12`:
-- |
-- |   * `mini` — Tidal's mini-notation.  Per-token shape decides the
-- |     `PitchedNote12` variant: note-shaped (`c4`, `fs3`) → `Chromatic`;
-- |     integer-shaped (`60`) → `Chromatic`; anything else (`bd`,
-- |     `sn`) → `Sample`.  Same back-compat surface as the legacy
-- |     `mini :: String -> Pattern String` it replaces, but the
-- |     downstream substrate now sees typed pitches.
-- |
-- |   * `n` — chromatic notes only.  Tokens that don't resolve to a
-- |     note fall through as `Sample` (preserves the token text for
-- |     downstream diagnostic surfacing).  Use `n "c4 e4 g4"` when
-- |     you mean absolute pitches.
-- |
-- |   * `d` — scale degrees.  Each token parsed as an `Int`;
-- |     unparseable tokens fall through as `Sample`.  Use
-- |     `d "1 3 5 7"` when you want pitches resolved at emit time
-- |     against the active scale.
-- |
-- | The parser itself produces `Pattern String` (Tidal's mini-notation
-- | doesn't know about pitches).  Each entry point fmaps a
-- | token-classification step over the result; that's where the
-- | `String → PitchedNote12` decision lives.  Failures from the parser become
-- | `silence` — a typo in a cell goes quiet rather than killing the
-- | rig.
module Tidal.Pitch.Parse
  ( mini
  , n
  , d
  , miniToken
  , noteToken
  , degreeToken
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String.CodeUnits as SCU
import Tidal.Dispatch.Helpers (noteNameMidi)
import Tidal.Pattern.Mini (parseMiniPattern)
import Tidal.Pattern.Types (Pattern, silence)
import Tidal.Pitch (PitchedNote12(..))

-- | Parse mini-notation into a `Pattern PitchedNote12`.  Token-shape decides
-- | the `PitchedNote12` variant per event:
-- |
-- |   * Note name (`c4`, `fs3`, `bb2`) → `Chromatic <midi>`
-- |   * Integer (`60`)                 → `Chromatic 60`
-- |   * Decimal numeric (`60.5`)       → `Chromatic 60` (floored)
-- |   * Anything else (`bd`, `sn`)     → `Sample <tok>`
-- |
-- | Examples:
-- |
-- | ```
-- | mini "bd sn cp"     -- three Sample events per cycle
-- | mini "c4 e4 g4"     -- three Chromatic events per cycle
-- | mini "bd*4"         -- four Sample kicks per cycle
-- | mini "[c4 e4] g4*2" -- grouped sequencing of Chromatics
-- | mini "<bd sn>"      -- alternation
-- | mini "c4(3,8)"      -- Euclidean Chromatics
-- | ```
mini :: String -> Pattern PitchedNote12
mini src = case parseMiniPattern src of
  Right p -> map miniToken p
  Left _  -> silence

-- | Parse mini-notation as chromatic notes.  Note-shaped tokens
-- | resolve to `Chromatic` via the `noteNameMidi` table; integer
-- | tokens are taken as literal MIDI numbers; everything else falls
-- | through as `Sample` (preserving the source token, which surfaces
-- | through to the dispatcher's binding-default lookup — useful for
-- | mixing drum tokens into otherwise-pitched patterns).
-- |
-- | The mnemonic: `n` = "notes". Mirrors Tidal's existing `n`-as-note
-- | operator, but produces typed pitches.
n :: String -> Pattern PitchedNote12
n src = case parseMiniPattern src of
  Right p -> map noteToken p
  Left _  -> silence

-- | Parse mini-notation as scale degrees.  Each integer token becomes
-- | a `Degree`; non-integer tokens fall through as `Sample` (which
-- | typically silences in degree contexts, since binding defaults
-- | won't match).
-- |
-- | Degrees stay unresolved through the substrate; the voice renders
-- | them at emit time using the active scale.  Wire-level
-- | `set-scale c-mixolydian` re-renders every running degree pattern
-- | on the next tick.
-- |
-- | The mnemonic: `d` = "degrees". `dc` (Nashville chord notation)
-- | is a planned sibling; not in this MVP.
d :: String -> Pattern PitchedNote12
d src = case parseMiniPattern src of
  Right p -> map degreeToken p
  Left _  -> silence

-- ---------------------------------------------------------------------------
-- Token → PitchedNote12 classifiers
-- ---------------------------------------------------------------------------

-- | mini's per-token rule.  See module header.
miniToken :: String -> PitchedNote12
miniToken tok = case noteFromName tok of
  Just midi -> Chromatic midi
  Nothing -> case Number.fromString tok of
    Just num -> Chromatic (Int.floor num)
    Nothing -> Sample tok

-- | n's per-token rule.  See module header.
noteToken :: String -> PitchedNote12
noteToken tok = case noteFromName tok of
  Just midi -> Chromatic midi
  Nothing -> case Int.fromString tok of
    Just i -> Chromatic i
    Nothing -> case Number.fromString tok of
      Just num -> Chromatic (Int.floor num)
      Nothing -> Sample tok

-- | d's per-token rule.  See module header.
degreeToken :: String -> PitchedNote12
degreeToken tok = case Int.fromString tok of
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
