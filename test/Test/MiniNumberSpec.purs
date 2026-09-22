-- | Numeric literals in mini-notation — specifically the signed ones.
-- |
-- | `Tidal.Parse.Class.stringAtom` offers two paths: a signed-number atom
-- | for anything starting `-`, and a regular atom that must start with an
-- | alphanumeric but may then contain `.`.  A leading `-` commits you to
-- | the first path, and the second cannot rescue you from it.
-- |
-- | So while the signed path took integers only, `-0.5` tokenised as
-- | `["-0", "5"]`: a TWO-step pattern, backwards at 0x then forwards at
-- | 5x.  `speed "-0.5"` — reverse at half speed, one of the most common
-- | idioms there is — silently became something else, and something else
-- | that sounds enough like "the minus was ignored" to get blamed on the
-- | sampler.  Positive fractions were always fine, which is exactly why
-- | it lasted: only the signed half was broken.
-- |
-- | These assert the token STRINGS, not the parsed values, because the
-- | failure was a tokenisation failure — the count is the tell.
module Test.MiniNumberSpec (runMiniNumberTests) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Rational (fromInt)
import Effect (Effect)
import Effect.Console (log)
import Tidal.MiniNotation (miniTyped)
import Tidal.Notation (toPattern)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (eventValue)

tokens :: String -> Array String
tokens src =
  map eventValue (queryArc (toPattern (miniTyped src)) (fromInt 0) (fromInt 1))

runMiniNumberTests :: Effect Unit
runMiniNumberTests = do
  log ""
  log "=========================================="
  log "  Mini-notation numeric literals"
  log "=========================================="
  log ""
  for_
    [ { src: "-0.5",     want: [ "-0.5" ] }        -- the regression
    , { src: "-1.5",     want: [ "-1.5" ] }
    , { src: "-0.75",    want: [ "-0.75" ] }
    , { src: "-3",       want: [ "-3" ] }          -- signed int, never broke
    , { src: "-1",       want: [ "-1" ] }
    , { src: "0.25",     want: [ "0.25" ] }        -- positive frac, never broke
    , { src: "2.5",      want: [ "2.5" ] }
    , { src: "0.5 -0.5", want: [ "0.5", "-0.5" ] } -- both in one pattern
    ] \c -> do
      let got = tokens c.src
      if got == c.want
        then log $ "  ok   " <> show c.src <> " -> " <> show got
        else log $ "  FAIL " <> show c.src <> " -> " <> show got
               <> ", wanted " <> show c.want
