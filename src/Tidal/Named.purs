-- | **A machine's saved things, played by name** (docs/kb/plans/the-deck.md).
-- | `balistes $ "<fox-drum owl-drum>"` and `odonus $ "<verse chorus>"` are
-- | Tidal patterns of words; each word is a thing the machine's page saved,
-- | on the stage under the machine's prefix (`balistes/rhythm/<word>`,
-- | `odonus/patch/<word>`; the word is `Reef.Word`'s). Balistes plays a
-- | beat from the top as its word's event begins; Odonus recalls a patch.
-- |
-- | A word may equally be a Grids beat Balistes saved by name, which runs the
-- | Grids engine from that point, carrying on where it left off each time it
-- | comes round (`reef_balistes_voice`).
-- |
-- | Read as Tidal reads `s` (words, `~` for a rest, all the mini-notation),
-- | with Littorina, by `reef_balistes_voice`, which samples it every sixteenth
-- | (a cycle a bar). A word plays its rhythm from the top when its event
-- | begins, as a sample is triggered, so `"<a b>"` gives each one bar and
-- | `"<a@2 b>"` gives `a` two. Reef never reads Tidal: this module hands it a
-- | word and a step.
module Tidal.Named
  ( wordSampler
  , fillSampler
  , wordsIn
  , stageRhythm
  , stageGrids
  , recallPatch
  ) where

import Prelude

import Data.Array (head, mapMaybe, nub, range)
import Data.Either (Either(..), hush)
import Data.Maybe (Maybe(..), maybe)
import Data.Array as Array
import Data.String as Str
import Haskell.Integer as Integer
import Haskell.Rational (fromInt, ratio)
import Haskell.Rational as Rational
import Reef.Balistes.Fixed (FixedPattern)
import Reef.Balistes.Lepidoptera (parsePattern)
import Reef.Balistes.Pattern (toWire)
import Reef.Balistes.Protocol (decodeBalSim)
import Reef.Balistes.Sim (BalSim)
import Reef.Input (Input(..))
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Haskell (Vocable(..))
import Tidal.Parse.Parser (parseTPat)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern)

parseWords :: String -> Either String (Pattern String)
parseWords src = case parseTPat src of
  Right tpat -> Right (map (\(Vocable v) -> v) (tpatToPattern tpat))
  Left err -> Left ("\"" <> src <> "\": " <> show err)

-- | The pattern read once, then asked at each sixteenth `q` (counted from
-- | Link beat 0, a cycle a bar): the word holding there and the sixteenth its
-- | event began on, or Nothing for a rest.
wordSampler :: String -> Either String (Int -> Maybe { word :: String, start :: Int })
wordSampler src = map sampleAt (parseWords src)
  where
  sampleAt p q =
    let t = ratio (Integer.fromInt q) (Integer.fromInt 16)
    in head (mapMaybe (holding t) (queryArc p t t))
  holding t = case _ of
    Digital { whole: Arc w, value } | w.start <= t && t < w.stop ->
      Just { word: value, start: Integer.toInt (Rational.ceiling (w.start * fromInt 16)) }
    _ -> Nothing

-- | `balistes $ fill "<f!7 t>"`: Balistes's FILL as a Tidal pattern of
-- | booleans, read as Tidal reads a `Pattern Bool` (`t`/`f`, or `1`/`0`; a
-- | rest is false), asked at each sixteenth as `wordSampler` is (a cycle a
-- | bar, from Link beat 0). So `"<f!7 t>"` fills every eighth bar and
-- | `"<f f f [f t]>"` the back half of every fourth. Any other word is
-- | refused when the line is read, so a typo never plays as silence.
fillSampler :: String -> Either String (Int -> Boolean)
fillSampler src = do
  at <- wordSampler src
  case Array.filter (not <<< flag) (wordsIn src) of
    [] -> Right (\q -> maybe false (truthy <<< _.word) (at q))
    bad -> Left ("fill is a pattern of t and f (or 1 and 0), not " <> Str.joinWith ", " bad)
  where
  flag w = Array.elem w [ "t", "f", "true", "false", "1", "0" ]
  truthy w = Array.elem w [ "t", "true", "1" ]

-- | The words the pattern plays in its first eight cycles, each once: what
-- | the rig checks against the stage when the line is evaluated, to say which
-- | are silent because Balistes has saved no rhythm by that name.
wordsIn :: String -> Array String
wordsIn src = case wordSampler src of
  Right at -> nub (mapMaybe (map _.word <<< at) (range 0 (8 * 16 - 1)))
  Left _ -> []

-- | A rhythm's stage text, as the shared eval plays it.
stageRhythm :: String -> Maybe FixedPattern
stageRhythm text = map toWire (parsePattern text)

-- | The input that recalls an Odonus patch, as a move's does
-- | (phase-preserving: the playheads carry on).
recallPatch :: String -> Input
recallPatch text = RecallPatch text

-- | A Grids beat's stage text (`grids ` and its engine state, as
-- | `Triggerfish.Balistes.Stage` writes it): the state it plays from.
stageGrids :: String -> Maybe BalSim
stageGrids text = Str.stripPrefix (Str.Pattern "grids ") text >>= (hush <<< decodeBalSim)
