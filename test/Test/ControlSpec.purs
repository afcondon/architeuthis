-- | Control patterns against Haskell Tidal.
-- |
-- | Every expectation here was read from GHCi running Tidal 1.10.1
-- | (`queryArc (…) (Arc 0 1)`), not worked out by hand: the point of the
-- | module is to mean what Tidal means. The renderer writes each event as
-- | `whole|part|key=value…`, values tagged by kind (`f` float, `n` note,
-- | quoted string), so a failure shows the whole difference at once.
-- |
-- | Unlike the older specs, a failure here fails the run.
module Test.ControlSpec (runControlTests, render) where

import Prelude

import Data.Ord (abs)

import Data.Array (length, filter)
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, denominator, numerator, fromInt)
import Data.Int as Int
import Data.String (joinWith)
import Data.String as String
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Tidal.Controls (control, lookupControl, (#), (|<))
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Mini (parseMiniPattern)
import Tidal.Pattern.Types (Arc(..), ControlPattern, Event(..), Value(..), silence)

-- | A control applied to a mini-notation string, as the line language does.
ctl :: String -> String -> ControlPattern
ctl name src = case parseMiniPattern src, lookupControl name of
  Right p, Just k -> control k p
  _, _ -> silence

render :: Event (Map.Map String Value) -> String
render = case _ of
  Digital e -> arc e.whole <> "|" <> arc e.part <> "|" <> values e.value
  Analog e -> "~|" <> arc e.part <> "|" <> values e.value
  where
  arc (Arc a) = rat a.start <> "-" <> rat a.stop
  rat :: Rational -> String
  rat r = if denominator r == 1 then show (numerator r) else show (numerator r) <> "/" <> show (denominator r)
  -- purerl shows Numbers in exponent form; three decimals is enough here.
  num x =
    let
      i = Int.round (x * 1000.0)
      frac = show (abs (i `mod` 1000) + 1000)
    in
      show (i / 1000) <> "." <> String.drop 1 frac
  values m = joinWith "," (map kv (Map.toUnfoldable m :: Array (Tuple String Value)))
  kv (Tuple k v) = k <> "=" <> case v of
    VNumber x -> "f" <> num x
    VNote x -> "n" <> num x
    VString x -> show x
    VInt i -> show i
    VBool b -> show b
    VRational r -> rat r

cases :: Array { name :: String, pat :: ControlPattern, want :: Array String }
cases =
  [ { name: "s \"bd:3 sn\" splits bd:3 into s and n"
    , pat: ctl "s" "bd:3 sn"
    , want: [ "0-1/2|0-1/2|n=f3.000,s=\"bd\"", "1/2-1|1/2-1|s=\"sn\"" ] }
  , { name: "s \"bd:x\" drops a suffix that is not a number"
    , pat: ctl "s" "bd:x"
    , want: [ "0-1|0-1|s=\"bd\"" ] }
  , { name: "s \"bd\" # n \"0 2\": structure from the left, divided by the right"
    , pat: ctl "s" "bd" # ctl "n" "0 2"
    , want: [ "0-1|0-1/2|n=n0.000,s=\"bd\"", "0-1|1/2-1|n=n2.000,s=\"bd\"" ] }
  , { name: "s \"bd*2\" # n \"1 2 3\""
    , pat: ctl "s" "bd*2" # ctl "n" "1 2 3"
    , want:
        [ "0-1/2|0-1/3|n=n1.000,s=\"bd\"", "0-1/2|1/3-1/2|n=n2.000,s=\"bd\""
        , "1/2-1|1/2-2/3|n=n2.000,s=\"bd\"", "1/2-1|2/3-1|n=n3.000,s=\"bd\"" ] }
  , { name: "n \"1 2 3\" # s \"bd*2\""
    , pat: ctl "n" "1 2 3" # ctl "s" "bd*2"
    , want:
        [ "0-1/3|0-1/3|n=n1.000,s=\"bd\"", "1/3-2/3|1/3-1/2|n=n2.000,s=\"bd\""
        , "1/3-2/3|1/2-2/3|n=n2.000,s=\"bd\"", "2/3-1|2/3-1|n=n3.000,s=\"bd\"" ] }
  , { name: "# takes the right's value for a shared key"
    , pat: ctl "s" "bd" # ctl "s" "sn"
    , want: [ "0-1|0-1|s=\"sn\"" ] }
  , { name: "|< keeps the left's value"
    , pat: ctl "s" "bd" |< ctl "s" "sn"
    , want: [ "0-1|0-1|s=\"bd\"" ] }
  , { name: "aliases write their target's key, at its type"
    , pat: ctl "s" "bd" # ctl "lpf" "100" # ctl "hpq" "0.2" # ctl "orbit" "1" # ctl "vowel" "a"
    , want: [ "0-1|0-1|cutoff=f100.000,hresonance=f0.200,orbit=1,s=\"bd\",vowel=\"a\"" ] }
  , { name: "floats read duration letters, then note names"
    , pat: ctl "gain" "e cs6 ef4 1.5"
    , want: [ "0-1/4|0-1/4|gain=f0.125", "1/4-1/2|1/4-1/2|gain=f13.000", "1/2-3/4|1/2-3/4|gain=f-9.000", "3/4-1|3/4-1|gain=f1.500" ] }
  , { name: "notes read note names"
    , pat: ctl "n" "e cs6 ef4 -2 a5"
    , want: [ "0-1/5|0-1/5|n=n4.000", "1/5-2/5|1/5-2/5|n=n13.000", "2/5-3/5|2/5-3/5|n=n-9.000", "3/5-4/5|3/5-4/5|n=n-2.000", "4/5-1|4/5-1|n=n9.000" ] }
  , { name: "ints read note names"
    , pat: ctl "orbit" "1 e"
    , want: [ "0-1/2|0-1/2|orbit=1", "1/2-1|1/2-1|orbit=4" ] }
  ]

runControlTests :: Effect Unit
runControlTests = do
  log ""
  log "=========================================="
  log "  Control patterns (against Tidal 1.10.1)"
  log "=========================================="
  log ""
  results <- for cases \c -> do
    let got = map render (queryArc c.pat (fromInt 0) (fromInt 1))
    if got == c.want then log ("  ok   " <> c.name) *> pure true
    else do
      log ("  FAIL " <> c.name)
      log ("       got  " <> show got)
      log ("       want " <> show c.want)
      pure false
  let failed = length (filter not results)
  when (failed > 0) $ throw (show failed <> " control pattern test(s) failed")
