-- | **A loop window driven by a pattern** (docs/kb/plans/the-deck.md, step
-- | 3a). `odonus $ slide "<0 -1 -2 -3>"` walks the Review loop back through
-- | the session a bar at a time; `widen "<0 1>"` breathes its length. The
-- | numbers are bars from where the mark was made, so a pattern that repeats
-- | puts the window back where it was rather than drifting.
-- |
-- | Read as Tidal reads a note pattern (numbers, `~` for a rest, all the
-- | mini-notation), with Littorina, by `window_patterns`, which samples each
-- | pattern every beat and tells the page when the value changes. The page
-- | never reads Tidal.
module Tidal.Window
  ( windowSampler
  , checkWindow
  ) where

import Prelude

import Data.Array (head, mapMaybe)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Haskell.Integer as Integer
import Haskell.Rational (ratio)
import Tidal.Core.Types (Time)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Haskell (TNote(..))
import Tidal.Parse.Parser (parseTPat)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern)

parseWindow :: String -> Either String (Pattern Number)
parseWindow src = case parseTPat src of
  Right tpat -> Right (map (\(TNote v) -> v) (tpatToPattern tpat))
  Left err -> Left ("window \"" <> src <> "\": " <> show err)

-- | The pattern, if it reads: what the rig checks before keeping one.
checkWindow :: String -> Either String String
checkWindow src = map (const src) (parseWindow src)

-- | The number holding at cycle `num / den` (a cycle is a bar), or Nothing
-- | for a rest or text that does not read.
windowSampler :: Int -> Int -> String -> Maybe Number
windowSampler num den src = case parseWindow src of
  Right p -> valueAt p (ratio (Integer.fromInt num) (Integer.fromInt den))
  Left _ -> Nothing

valueAt :: Pattern Number -> Time -> Maybe Number
valueAt p t = head (mapMaybe holding (queryArc p t t))
  where
  holding = case _ of
    Digital { whole: Arc w, value } | w.start <= t && t < w.stop -> Just value
    _ -> Nothing
