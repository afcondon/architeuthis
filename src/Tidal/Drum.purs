-- | Tidal.Drum — the drum-pattern parser.
-- |
-- | Delegates to `Tidal.Pitch.Parse.mini` for the actual parsing
-- | (subdivisions `[bd sn]`, repeats `bd*4`, euclidean `bd(3,8)`,
-- | rests `~`, all of mini-notation's surface) and then extracts each
-- | event's `Sample` name as the resulting `Pattern String`.  Tokens
-- | that mini happens to parse as pitched (`c4`, `e5`) drop out as
-- | empty-name placeholders — drum patterns are conventionally
-- | sample-keyed, so writing `c4` in a drum body is a user error and
-- | the dropped event is the closest sensible behaviour.
-- |
-- | PR 2a runtime path: each `Pattern String` event is coerced back
-- | to `Sample s` at the conductor boundary (Conductor.purs) so the
-- | existing dispatcher emit path handles it.  PR 2b will switch to
-- | per-hit-MIDI-binding dispatch using these names.
module Tidal.Drum
  ( drum
  , drumPatternToPitch
  ) where

import Prelude

import Data.Functor (map)
import Tidal.Pattern.Types (Pattern)
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Pitch.Parse (mini)

-- | Parse a drum-pattern string using the full mini-notation
-- | grammar, then project each event's sample-name out.
-- |
-- |     drum "bd ~ sn ~"          -- four-step pattern with bd, rest, sn, rest
-- |     drum "bd(3,8)"            -- euclidean kick
-- |     drum "[bd sn]*2 ~ cp"     -- subdivided + repeated
drum :: String -> Pattern String
drum input = map nameOf (mini input)
  where
  nameOf :: PitchedNote12 -> String
  nameOf (Sample s) = s
  nameOf _          = ""

-- | Coerce a DrumPart's `Pattern String` body to `Pattern PitchedNote12` by
-- | wrapping each hit-name as the `Sample` variant.  Used at the
-- | play-armed boundary on the Erlang side (Handler.erl's
-- | resolve_cue_body) so the voice gen_server's existing
-- | PitchedNote12-event emit path handles drum events transparently.
-- |
-- | PR 2a runtime-compat shim.  PR 2b replaces this with per-hit
-- | binding dispatch: each hit-name flows directly to its
-- | `<kitAlias>.<hitName>` MIDI binding rather than being coerced
-- | back to a kit-level Sample.
drumPatternToPitch :: Pattern String -> Pattern PitchedNote12
drumPatternToPitch = map Sample
