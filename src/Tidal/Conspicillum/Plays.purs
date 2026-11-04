-- | **Conspicillum's `n "…"`, evaluated.** Reef carries the sampler's pattern as
-- | text and never reads it, because reef stays outside the GPL; so does the
-- | page. This module is where it meets Littorina: `playsOf` gives the voice one
-- | cycle's plays for `Reef.Conspicillum.Cloud.cycleOfPlays`, and `answer` gives
-- | the page the same plays to draw, so what it shows is what sounds.
module Tidal.Conspicillum.Plays
  ( playsOf
  , problem
  , answer
  ) where

import Prelude

import Data.Array (mapMaybe, range, sortBy)
import Data.Either (Either(..))
import Data.Int (fromString)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toNullable)
import Data.String (drop, indexOf, take, trim)
import Data.String as String
import Haskell.Rational as Rat
import Reef.Conspicillum.Cloud (Play)
import Simple.JSON (writeJSON)
import Tidal.Pattern.Mini (parseMiniPattern)
import Tidal.Pattern.Types (Arc(..), Event, Pattern, eventPart, eventValue, eventWhole, mkArc, mkState, query)

-- | The plays in cycle `c`, in order. Only events that begin in the cycle play,
-- | so a sample held across cycles by `slow` is struck once. A value that names
-- | no sample is a rest.
playsOf :: String -> Int -> Array Play
playsOf text c = case parseMiniPattern text of
  Left _ -> []
  Right pat -> inCycle pat c

inCycle :: Pattern String -> Int -> Array Play
inCycle pat c =
  sortBy (comparing _.at)
    (mapMaybe play (query pat (mkState (mkArc (Rat.fromInt c) (Rat.fromInt (c + 1))))))
  where
  play :: Event String -> Maybe Play
  play ev = do
    Arc w <- eventWhole ev
    let Arc p = eventPart ev
    index <- fromString (trim (eventValue ev))
    if w.start == p.start then Just { at: Rat.toNumber (w.start - Rat.fromInt c), index } else Nothing

-- | What is wrong with the pattern, if anything. Empty is no pattern: a cloud.
problem :: String -> Maybe String
problem text
  | trim text == "" = Nothing
  | otherwise = case parseMiniPattern text of
      Left e -> Just e
      Right _ -> Nothing

-- | The reply to `conspicillum-plays <from> <count> <pattern>`: that many
-- | cycles of plays, keyed by the pattern so the page can drop a stale answer.
answer :: String -> String
answer request =
  let
    from = word request
    afterFrom = rest request
    count = word afterFrom
    text = rest afterFrom
    first = fromMaybe 0 (fromString from)
    cycles = if problem text == Nothing then map (playsOf text) (range first (first + clampCount count - 1)) else []
  in
    "conspicillum-plays " <> writeJSON { pattern: text, from: first, cycles, problem: toNullable (problem text) }
  where
  word s = case indexOf (String.Pattern " ") s of
    Just i -> take i s
    Nothing -> s
  rest s = case indexOf (String.Pattern " ") s of
    Just i -> trim (drop (i + 1) s)
    Nothing -> ""
  clampCount s = max 1 (min 64 (fromMaybe 1 (fromString s)))
