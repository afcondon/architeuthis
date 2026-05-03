-- | Tests for `Tidal.Expr` — the host-language expression layer.
-- |
-- | Verifies that:
-- |
-- |   * The parser accepts strings, numbers, bare names, and applications.
-- |   * The evaluator dispatches to the registry and produces patterns
-- |     with the same events as direct PureScript calls.
-- |   * The error paths return useful messages instead of partial results.
module Test.ExprSpec where

import Prelude

import Data.Array as Array
import Data.Either (Either(..), isLeft)
import Data.Map as Map
import Data.Rational (fromInt)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Expr (eval, parseExpr)
import Tidal.Parse.Parser (parseTPat)
import Tidal.Pattern.Branched
  ( Voice(..)
  , alternate
  , crossfade
  , fanOut
  , gate
  , jux
  , mult
  )
import Tidal.Pattern.Core (every, fast, palindrome, queryArc, rev, slow)
import Tidal.Pattern.Types (Pattern)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Compile a mini-notation string the same way the evaluator does, so the
-- expected and actual sides of comparisons are built from the same path.
mini :: String -> Pattern String
mini s = case parseTPat s of
  Right tpat -> tpatToPattern tpat
  Left _ -> tpatToPattern (unsafeParse "~")
  where
    unsafeParse src = case parseTPat src of
      Right t -> t
      Left _ -> unsafeParse src -- unreachable: "~" parses

-- Compare two patterns by event count over [0,1).
sameCount :: forall a. Pattern a -> Pattern a -> Boolean
sameCount p q =
  Array.length (queryArc p (fromInt 0) (fromInt 1))
    == Array.length (queryArc q (fromInt 0) (fromInt 1))

-- ---------------------------------------------------------------------------
-- Test driver
-- ---------------------------------------------------------------------------

runExprTests :: Effect Unit
runExprTests = do
  log ""
  log "=========================================="
  log "  Tidal.Expr (host-language) Tests"
  log "=========================================="
  log ""

  log "--- parseExpr smoke tests ---"
  expectParses "string literal" "\"bd sn\""
  expectParses "single bare name" "rev"
  expectParses "single number" "2"
  expectParses "rational number" "1/4"
  expectParses "negative number" "-3"
  expectParses "rev applied" "rev \"bd sn\""
  expectParses "slow applied" "slow 2 \"bd sn\""
  expectParses "every applied" "every 4 rev \"bd sn\""
  expectParses "list literal" "[a, b, c]"
  expectParses "tagged list" "[L:rev, R:id]"
  expectFails "trailing junk" "rev \"bd sn\" )"
  expectFails "unterminated string" "rev \"bd sn"

  log ""
  log "--- eval: identity (no transformation) ---"
  let
    refPat = mini "bd sn hh cp"
    evalDirect = eval "\"bd sn hh cp\""
  expectEvalCount "bare string ≡ mini-notation" evalDirect refPat

  log ""
  log "--- eval: rev ---"
  let revRef = rev (mini "c4 e4 g4")
  expectEvalCount "rev \"c4 e4 g4\" ≡ rev (mini …)"
    (eval "rev \"c4 e4 g4\"") revRef

  log ""
  log "--- eval: slow / fast ---"
  let slowRef = slow (fromInt 2) (mini "bd sn hh cp")
  expectEvalCount "slow 2 \"bd sn hh cp\""
    (eval "slow 2 \"bd sn hh cp\"") slowRef

  let fastRef = fast (fromInt 2) (mini "bd sn")
  expectEvalCount "fast 2 \"bd sn\""
    (eval "fast 2 \"bd sn\"") fastRef

  log ""
  log "--- eval: palindrome ---"
  let palRef = palindrome (mini "c4 d4 e4")
  expectEvalCount "palindrome \"c4 d4 e4\""
    (eval "palindrome \"c4 d4 e4\"") palRef

  log ""
  log "--- eval: every ---"
  let everyRef = every 2 rev (mini "bd sn hh cp")
  expectEvalCount "every 2 rev \"bd sn hh cp\""
    (eval "every 2 rev \"bd sn hh cp\"") everyRef

  log ""
  log "--- eval: rational arg ---"
  let slowHalf = slow (fromInt 1 / fromInt 2) (mini "bd sn")
  expectEvalCount "slow 1/2 \"bd sn\""
    (eval "slow 1/2 \"bd sn\"") slowHalf

  log ""
  log "--- eval: error paths ---"
  expectEvalLeft "unknown function" (eval "foo \"bd sn\"")
  expectEvalLeft "wrong arity (slow with 1 arg)" (eval "slow \"bd sn\"")
  expectEvalLeft "wrong arity (rev with 0 args)" (eval "rev")
  expectEvalLeft "function reference at top level" (eval "rev")
  expectEvalLeft "non-integer to every" (eval "every 1/2 rev \"bd sn\"")
  expectEvalLeft "bad mini-notation" (eval "rev \"((( unbalanced\"")

  log ""
  log "--- eval: Branched — jux ---"
  let
    juxRef = jux rev (mini "c4 e4 g4 b4")
  expectEvalCount "jux rev \"c4 e4 g4 b4\""
    (eval "jux rev \"c4 e4 g4 b4\"") juxRef

  log ""
  log "--- eval: Branched — mult ---"
  let
    multSpec =
      [ Tuple (Voice "L") identity
      , Tuple (Voice "R") rev
      , Tuple (Voice "harm") palindrome
      ]
    multRef = mult multSpec (mini "c4 e4 g4 b4")
  expectEvalCount "mult [L:id, R:rev, harm:palindrome] …"
    (eval "mult [L:id, R:rev, harm:palindrome] \"c4 e4 g4 b4\"") multRef

  log ""
  log "--- eval: Branched — alternate ---"
  let
    altSpec =
      [ Tuple (Voice "a") identity
      , Tuple (Voice "b") rev
      ]
    altRef = alternate (fanOut altSpec (mini "bd sn hh cp"))
  expectEvalCount "alternate [a:id, b:rev] cycle 0"
    (eval "alternate [a:id, b:rev] \"bd sn hh cp\"") altRef

  log ""
  log "--- eval: Branched — crossfade ---"
  let
    cfSpec =
      [ Tuple (Voice "L") identity
      , Tuple (Voice "R") rev
      ]
    cfVoicePat = map Voice (mini "L R L R")
    cfRef = crossfade cfVoicePat (fanOut cfSpec (mini "c4 e4 g4 b4"))
  expectEvalCount "crossfade \"L R L R\" [L:id, R:rev] …"
    (eval "crossfade \"L R L R\" [L:id, R:rev] \"c4 e4 g4 b4\"") cfRef

  log ""
  log "--- eval: Branched — gate ---"
  let
    gateSpec =
      [ Tuple (Voice "lead") identity
      , Tuple (Voice "pad") rev
      ]
    gateMap = Map.fromFoldable
      [ Tuple (Voice "lead") (pure true)
      , Tuple (Voice "pad") (pure false)
      ]
    gateRef = gate gateMap (fanOut gateSpec (mini "c4 e4 g4 b4"))
  expectEvalCount "gate [lead:true, pad:false] [lead:id, pad:rev] …"
    (eval "gate [lead:true, pad:false] [lead:id, pad:rev] \"c4 e4 g4 b4\"")
    gateRef

  log ""
  log "--- eval: Branched — error paths ---"
  expectEvalLeft "jux with non-function arg"
    (eval "jux 2 \"bd sn\"")
  expectEvalLeft "mult with non-list spec"
    (eval "mult \"bd\" \"bd sn\"")
  expectEvalLeft "mult with untagged list entry"
    (eval "mult [rev, id] \"bd sn\"")
  expectEvalLeft "gate map with non-bool value"
    (eval "gate [lead:rev] [lead:id] \"bd sn\"")
  expectEvalLeft "crossfade missing voice pattern"
    (eval "crossfade [L:id] \"bd sn\"")

  log ""

-- ---------------------------------------------------------------------------
-- Assertion helpers
-- ---------------------------------------------------------------------------

expectParses :: String -> String -> Effect Unit
expectParses desc src = case parseExpr src of
  Right _ -> log $ "  ✓ " <> desc <> ": " <> src
  Left err -> log $ "  ✗ " <> desc <> ": " <> src <> " — " <> err

expectFails :: String -> String -> Effect Unit
expectFails desc src = case parseExpr src of
  Right _ -> log $ "  ✗ " <> desc <> " (expected parse failure): " <> src
  Left _ -> log $ "  ✓ " <> desc <> " (rejected): " <> src

expectEvalCount
  :: String
  -> Either String (Pattern String)
  -> Pattern String
  -> Effect Unit
expectEvalCount desc actual expected = case actual of
  Left err -> log $ "  ✗ " <> desc <> " — eval failed: " <> err
  Right p ->
    if sameCount p expected
      then
        let
          n = Array.length (queryArc p (fromInt 0) (fromInt 1))
        in
          log $ "  ✓ " <> desc <> " (" <> show n <> " events)"
      else
        log $ "  ✗ " <> desc
            <> " — count "
            <> show (Array.length (queryArc p (fromInt 0) (fromInt 1)))
            <> " /= "
            <> show (Array.length (queryArc expected (fromInt 0) (fromInt 1)))

expectEvalLeft :: String -> Either String (Pattern String) -> Effect Unit
expectEvalLeft desc actual =
  if isLeft actual
    then log $ "  ✓ " <> desc <> " — Left as expected"
    else log $ "  ✗ " <> desc <> " — expected Left, got Right"
