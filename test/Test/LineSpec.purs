-- | The line language against Haskell Tidal.
-- |
-- | Each `plays` case is a line as typed in Limulus; its events, over the
-- | arc given, were rendered by GHCi running Tidal 1.10.1 with
-- | `test/ghci/render.hs` (`render (<expression>) from to`), in the same form
-- | `Test.ControlSpec` renders ours. The event lists must be equal,
-- | fragments and all; their order is not compared.
-- |
-- | `refusals` are lines the language must refuse, by name, rather than play
-- | something else.
module Test.LineSpec (runLineTests) where

import Prelude

import Data.Array (filter, length, sort)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Rational (fromInt)
import Data.String (Pattern(..), contains)
import Data.Traversable (for)
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Test.ControlSpec (render)
import Tidal.Line (Command(..), parseLine)
import Tidal.Pattern.Core (queryArc)

plays :: Array { line :: String, stream :: Int, from :: Int, to :: Int, want :: Array String }
plays =
  [
    { line: "d1 $ s \"bd*4\" # n \"0 2\"", stream: 1, from: 0, to: 1
      , want: [ "0-1/4|0-1/4|n=n0.000,s=\"bd\"", "1/4-1/2|1/4-1/2|n=n0.000,s=\"bd\"", "1/2-3/4|1/2-3/4|n=n2.000,s=\"bd\"", "3/4-1|3/4-1|n=n2.000,s=\"bd\"" ] },
    { line: "d1 $ fast 2 $ s \"bd sn\" # n \"0 1\"", stream: 1, from: 0, to: 1
      , want: [ "0-1/4|0-1/4|n=n0.000,s=\"bd\"", "1/2-3/4|1/2-3/4|n=n0.000,s=\"bd\"", "1/4-1/2|1/4-1/2|n=n1.000,s=\"sn\"", "3/4-1|3/4-1|n=n1.000,s=\"sn\"" ] },
    { line: "d1 $ rev $ s \"bd sn hh\"", stream: 1, from: 0, to: 1
      , want: [ "2/3-1|2/3-1|s=\"bd\"", "1/3-2/3|1/3-2/3|s=\"sn\"", "0-1/3|0-1/3|s=\"hh\"" ] },
    { line: "d1 $ slow 2 $ s \"bd sn\"", stream: 1, from: 0, to: 2
      , want: [ "0-1|0-1|s=\"bd\"", "1-2|1-2|s=\"sn\"" ] },
    { line: "d1 $ fast 1.5 $ s \"bd sn\"", stream: 1, from: 0, to: 2
      , want: [ "0-1/3|0-1/3|s=\"bd\"", "2/3-1|2/3-1|s=\"bd\"", "4/3-5/3|4/3-5/3|s=\"bd\"", "1/3-2/3|1/3-2/3|s=\"sn\"", "1-4/3|1-4/3|s=\"sn\"", "5/3-2|5/3-2|s=\"sn\"" ] },
    { line: "d1 $ (fast 2 . rev) $ s \"bd sn\"", stream: 1, from: 0, to: 1
      , want: [ "1/4-1/2|1/4-1/2|s=\"bd\"", "0-1/4|0-1/4|s=\"sn\"", "3/4-1|3/4-1|s=\"bd\"", "1/2-3/4|1/2-3/4|s=\"sn\"" ] },
    { line: "d1 $ s \"bd\" # gain 0.9 # speed (-1)", stream: 1, from: 0, to: 1
      , want: [ "0-1|0-1|gain=f0.900,s=\"bd\",speed=f-1.000" ] },
    { line: "d1 $ fast \"2\" $ s \"bd\"", stream: 1, from: 0, to: 1
      , want: [ "0-1/2|0-1/2|s=\"bd\"", "1/2-1|1/2-1|s=\"bd\"" ] },
    { line: "d1 (s \"bd sn\" # lpf 2000)", stream: 1, from: 0, to: 1
      , want: [ "0-1/2|0-1/2|cutoff=f2000.000,s=\"bd\"", "1/2-1|1/2-1|cutoff=f2000.000,s=\"sn\"" ] },
    { line: "d2 $ n \"0 .. 3\" # s \"arpy\"", stream: 2, from: 0, to: 1
      , want: [ "0-1/4|0-1/4|n=n0.000,s=\"arpy\"", "1/4-1/2|1/4-1/2|n=n1.000,s=\"arpy\"", "1/2-3/4|1/2-3/4|n=n2.000,s=\"arpy\"", "3/4-1|3/4-1|n=n3.000,s=\"arpy\"" ] },
    { line: "d1 $ s \"bd\" |< s \"sn\" # orbit 1", stream: 1, from: 0, to: 1
      , want: [ "0-1|0-1|orbit=1,s=\"bd\"" ] },
    { line: "d1 $ fast (3/2) $ s \"bd\"", stream: 1, from: 0, to: 2
      , want: [ "0-2/3|0-2/3|s=\"bd\"", "2/3-4/3|2/3-1|s=\"bd\"", "2/3-4/3|1-4/3|s=\"bd\"", "4/3-2|4/3-2|s=\"bd\"" ] },
    { line: "d16 $ s \"bd:3 hh:1\" # n 2", stream: 16, from: 0, to: 1
      , want: [ "0-1/2|0-1/2|n=n2.000,s=\"bd\"", "1/2-1|1/2-1|n=n2.000,s=\"hh\"" ] }
  , { line: "d1 $ fast \"<1 2>\" $ s \"bd sn\"", stream: 1, from: 0, to: 2
      , want: [ "0-1/2|0-1/2|s=\"bd\"", "1/2-1|1/2-1|s=\"sn\"", "1-5/4|1-5/4|s=\"bd\"", "3/2-7/4|3/2-7/4|s=\"bd\"", "5/4-3/2|5/4-3/2|s=\"sn\"", "7/4-2|7/4-2|s=\"sn\"" ] }
  , { line: "d1 $ fast (1+0.5) $ s \"bd\"", stream: 1, from: 0, to: 2
      , want: [ "0-2/3|0-2/3|s=\"bd\"", "2/3-4/3|2/3-1|s=\"bd\"", "2/3-4/3|1-4/3|s=\"bd\"", "4/3-2|4/3-2|s=\"bd\"" ] }
  , { line: "d1 $ slow \"1 2\" $ s \"bd*4\"", stream: 1, from: 0, to: 2
      , want: [ "0-1/4|0-1/4|s=\"bd\"", "1/4-1/2|1/4-1/2|s=\"bd\"", "1-5/4|1-5/4|s=\"bd\"", "5/4-3/2|5/4-3/2|s=\"bd\"", "1/2-1|1/2-1|s=\"bd\"", "3/2-2|3/2-2|s=\"bd\"" ] }
  ]

refusals :: Array { line :: String, says :: String }
refusals =
  [ { line: "d1 $ s \"bd\" # foo \"1\"", says: "unknown name foo" }
  , { line: "d1 $ n \"0 zz\"", says: "mini-notation" }
  , { line: "d17 $ s \"bd\"", says: "starts with d1..d16" }
  , { line: "d1 $ s \"bd\" # n \"1\" . rev", says: "cannot mix" }
  , { line: "d1 $ \"bd\"", says: "did you mean s" }
  , { line: "d1 $ s \"bd", says: "not closed" }
  ]

runLineTests :: Effect Unit
runLineTests = do
  log ""
  log "=========================================="
  log "  The line language (against Tidal 1.10.1)"
  log "=========================================="
  log ""
  played <- for plays \c -> check c.line case parseLine c.line of
    Right (Play n p) | n == c.stream ->
      let
        got = sort (map render (queryArc p (fromInt c.from) (fromInt c.to)))
        want = sort c.want
      in
        if got == want then Nothing else Just ("got " <> show got <> "\n       want " <> show want)
    Right _ -> Just "not a Play on that stream"
    Left err -> Just ("refused: " <> err)
  refused <- for refusals \c -> check c.line case parseLine c.line of
    Left err | contains (Pattern c.says) err -> Nothing
    Left err -> Just ("refused, but said: " <> err)
    Right _ -> Just "accepted"
  commands <- for
    [ { line: "hush", ok: case parseLine "hush" of
          Right Hush -> true
          _ -> false }
    , { line: "setcps 0.5", ok: case parseLine "setcps 0.5" of
          Right (SetCps x) -> x == 0.5
          _ -> false }
    , { line: "setcps (130/60/4)", ok: case parseLine "setcps (130/60/4)" of
          Right (SetCps x) -> x > 0.5416 && x < 0.5417
          _ -> false }
    ] \c -> check c.line (if c.ok then Nothing else Just "wrong command")
  let failed = length (filter not (played <> refused <> commands))
  when (failed > 0) $ throw (show failed <> " line language test(s) failed")
  where
  check line = case _ of
    Nothing -> log ("  ok   " <> line) $> true
    Just why -> do
      log ("  FAIL " <> line)
      log ("       " <> why)
      pure false
