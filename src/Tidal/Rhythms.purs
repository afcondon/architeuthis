-- | **Balistes's rhythms, played by name** (docs/kb/plans/the-deck.md, the
-- | Balistes line). `balistes $ "<fox-drum owl-drum>"` is a Tidal pattern of
-- | words; each word is a rhythm Balistes saved, on the stage as
-- | `balistes/rhythm/<word>` (the word is the name's slug,
-- | `Reef.Balistes.Lepidoptera.rhythmSlug`).
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
module Tidal.Rhythms
  ( rhythmSampler
  , rhythmWords
  , stageRhythm
  , stageGrids
  ) where

import Prelude

import Data.Array (head, mapMaybe, nub, range)
import Data.Either (Either(..), hush)
import Data.Maybe (Maybe(..))
import Data.String as Str
import Haskell.Integer as Integer
import Haskell.Rational (fromInt, ratio)
import Haskell.Rational as Rational
import Reef.Balistes.Fixed (FixedPattern)
import Reef.Balistes.Lepidoptera (parsePattern)
import Reef.Balistes.Pattern (toWire)
import Reef.Balistes.Protocol (decodeBalSim)
import Reef.Balistes.Sim (BalSim)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Haskell (Vocable(..))
import Tidal.Parse.Parser (parseTPat)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern)

parseRhythms :: String -> Either String (Pattern String)
parseRhythms src = case parseTPat src of
  Right tpat -> Right (map (\(Vocable v) -> v) (tpatToPattern tpat))
  Left err -> Left ("balistes \"" <> src <> "\": " <> show err)

-- | The pattern read once, then asked at each sixteenth `q` (counted from
-- | Link beat 0, a cycle a bar): the word holding there and the sixteenth its
-- | event began on, or Nothing for a rest.
rhythmSampler :: String -> Either String (Int -> Maybe { word :: String, start :: Int })
rhythmSampler src = map sampleAt (parseRhythms src)
  where
  sampleAt p q =
    let t = ratio (Integer.fromInt q) (Integer.fromInt 16)
    in head (mapMaybe (holding t) (queryArc p t t))
  holding t = case _ of
    Digital { whole: Arc w, value } | w.start <= t && t < w.stop ->
      Just { word: value, start: Integer.toInt (Rational.ceiling (w.start * fromInt 16)) }
    _ -> Nothing

-- | The words the pattern plays in its first eight cycles, each once: what
-- | the rig checks against the stage when the line is evaluated, to say which
-- | are silent because Balistes has saved no rhythm by that name.
rhythmWords :: String -> Array String
rhythmWords src = case rhythmSampler src of
  Right at -> nub (mapMaybe (map _.word <<< at) (range 0 (8 * 16 - 1)))
  Left _ -> []

-- | A rhythm's stage text, as the shared eval plays it.
stageRhythm :: String -> Maybe FixedPattern
stageRhythm text = map toWire (parsePattern text)

-- | A Grids beat's stage text (`grids ` and its engine state, as
-- | `Triggerfish.Balistes.Stage` writes it): the state it plays from.
stageGrids :: String -> Maybe BalSim
stageGrids text = Str.stripPrefix (Str.Pattern "grids ") text >>= (hush <<< decodeBalSim)
