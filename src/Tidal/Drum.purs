-- | Tidal.Drum — the drum-pattern parser.
-- |
-- | Parses mini-notation directly (subdivisions `[bd sn]`, repeats
-- | `bd*4`, euclidean `bd(3,8)`, rests `~`, alternation `<bd sn>`) and
-- | treats every token as a drum-hit name.  Unlike `Tidal.Pitch.Parse.pitch`,
-- | `drum` does no token classification — every event is a sample-name
-- | string, even tokens that look pitched (`c4` in a drum body becomes a
-- | drum hit named "c4", which the dispatcher silences if the kit has
-- | no such hit).
-- |
-- | PR 2a runtime path: each `Pattern String` event is coerced back
-- | to `Sample s` at the conductor boundary (Conductor.purs) so the
-- | existing dispatcher emit path handles it.  PR 2b switched to
-- | per-hit-MIDI-binding dispatch using these names.
module Tidal.Drum
  ( drum
  , drumPatternToPitch
  ) where

import Prelude

import Data.Functor (map)
import Tidal.MiniNotation (MiniNotation, miniTyped)
import Tidal.Pattern.Types (Pattern)
import Tidal.Pitch (PitchedNote12(..))

-- | Parse a drum-pattern string using the full mini-notation
-- | grammar.  Every non-rest token becomes the drum-hit name.
-- |
-- |     drum "bd ~ sn ~"          -- four-step pattern with bd, rest, sn, rest
-- |     drum "bd(3,8)"            -- euclidean kick
-- |     drum "[bd sn]*2 ~ cp"     -- subdivided + repeated
drum :: String -> MiniNotation String
drum = miniTyped

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
