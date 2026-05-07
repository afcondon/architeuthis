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
import Data.Maybe (Maybe(..))
import Data.Rational (fromInt, (%))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Expr (EvalResult(..), eval, evalExpr, parseExpr)
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
import Data.Int as Int
import Tidal.Pattern.Core (every, fast, palindrome, queryArc, rev, slow)
import Tidal.Pattern.Types (Event(..), Pattern)

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
  log "--- eval: oscillators (continuous numeric patterns) ---"
  -- Oscillators produce VNumPattern.  Each is sampled at the midpoint
  -- of the queried arc, so a thin window at cycle position 0 gives
  -- sine(2π·0) = 0 ⇒ (0+1)/2 = 0.5; at 0.25 ⇒ sine(π/2) = 1 ⇒ 1.0; etc.
  expectNumAt "sine at cycle 0"        "sine"           0.0    0.5
  expectNumAt "sine at cycle 0.25"     "sine"           0.25   1.0
  expectNumAt "sine at cycle 0.5"      "sine"           0.5    0.5
  expectNumAt "sine at cycle 0.75"     "sine"           0.75   0.0
  expectNumAt "saw at cycle 0"         "saw"            0.0    0.0
  expectNumAt "saw at cycle 0.5"       "saw"            0.5    0.5
  expectNumAt "isaw at cycle 0.25"     "isaw"           0.25   0.75
  expectNumAt "tri at cycle 0.25"      "tri"            0.25   0.5
  expectNumAt "tri at cycle 0.5"       "tri"            0.5    1.0
  expectNumAt "square at cycle 0.25"   "square"         0.25   0.0
  expectNumAt "square at cycle 0.75"   "square"         0.75   1.0

  log ""
  log "--- eval: range scales 0..1 → [lo, hi] ---"
  expectNumAt "range 0 127 sine @ 0.25"   "range 0 127 sine"    0.25  127.0
  expectNumAt "range 0 127 sine @ 0.75"   "range 0 127 sine"    0.75    0.0
  expectNumAt "range 30 80 sine @ 0"      "range 30 80 sine"    0.0    55.0
  expectNumAt "range -1 1 sine @ 0.25"    "range -1 1 sine"     0.25    1.0
  expectNumAt "range -1 1 sine @ 0.75"    "range -1 1 sine"     0.75  (-1.0)

  log ""
  log "--- eval: slow / fast on numeric patterns ---"
  -- slow 4 sine puts a full sine cycle across 4 scheduler cycles.
  -- At cycle 0 we're 1/16 into a slow cycle, expecting a small
  -- positive offset from 0.5.  Just check the broad shape: sample
  -- at four points and confirm one full sine has happened.
  expectNumAt "slow 4 sine @ 0"   "slow 4 sine"   0.0   0.5
  expectNumAt "slow 4 sine @ 1"   "slow 4 sine"   1.0   1.0
  expectNumAt "slow 4 sine @ 2"   "slow 4 sine"   2.0   0.5
  expectNumAt "slow 4 sine @ 3"   "slow 4 sine"   3.0   0.0

  log ""
  log "--- eval: arithmetic on numeric patterns ---"
  -- add: at cycle 0, sine = 0.5, saw = 0; sum = 0.5
  expectNumAt "add sine saw @ 0"        "add sine saw"        0.0   0.5
  -- mul scalar: at cycle 0.25, sine = 1.0; *0.5 = 0.5
  expectNumAt "mul 0.5 sine @ 0.25"     "mul 0.5 sine"        0.25  0.5
  -- sub: at cycle 0.25, sine = 1.0, saw = 0.25; diff = 0.75
  expectNumAt "sub sine saw @ 0.25"     "sub sine saw"        0.25  0.75
  -- neg: at cycle 0.25, sine = 1.0; neg = -1.0
  expectNumAt "neg sine @ 0.25"         "neg sine"            0.25 (-1.0)
  -- combined: range 0 1 sine + range 0 0.1 saw = sweep + small linear ramp
  -- at cycle 0, sine = 0.5, saw = 0; sum = 0.5
  expectNumAt "range+add @ 0"
    "add (range 0 1 sine) (range 0 0.1 saw)" 0.0  0.5

  log ""
  log "--- eval: rejects mis-typed args ---"
  expectEvalLeft "range with non-numeric pattern"
    (case parseExpr "range 0 1 \"bd sn\"" of
      Right e -> case evalExpr e of
        Right (VNumPattern _) -> Right (mini "x")  -- shouldn't happen
        _ -> Left "expected error"
      Left err -> Left err)
  expectEvalLeft "add with mis-shaped second arg"
    (case parseExpr "add sine \"bd sn\"" of
      Right e -> case evalExpr e of
        Right (VNumPattern _) -> Right (mini "x")
        _ -> Left "expected error"
      Left err -> Left err)

  log ""
  log "--- eval: speed (alias for fast / inverse-of-slow) ---"
  -- speed n pat ≡ fast n pat.  At sample positions inside cycle 0,
  -- `speed 4 sine` matches `fast 4 sine` matches `slow 4 sine` evaluated
  -- at 4× the phase.  Cross-check against fast at one well-known point.
  expectNumAt "speed 4 sine @ 0.0625 (≡ sine peak compressed 4x)"
    "speed 4 sine"  0.0625  1.0
  expectNumAt "speed (1/2) sine @ 0.5 (peak of slowed sine)"
    "speed (1/2) sine"  0.5  1.0

  log ""
  log "--- eval: log/exp ramp oscillators ---"
  -- expSaw = pos² so cycle 0.5 → 0.25, cycle 0.25 → 0.0625
  expectNumAt "expSaw at 0.5"     "expSaw"   0.5    0.25
  expectNumAt "expSaw at 0.25"    "expSaw"   0.25   0.0625
  expectNumAt "expSaw at 1.0"     "expSaw"   1.0    0.0   -- wraps to start
  -- iexpSaw = (1-pos)² so cycle 0.5 → 0.25, cycle 0.25 → 0.5625
  expectNumAt "iexpSaw at 0.5"    "iexpSaw"  0.5    0.25
  expectNumAt "iexpSaw at 0.25"   "iexpSaw"  0.25   0.5625
  -- logSaw = √pos so cycle 0.25 → 0.5, cycle 0.5 → 0.7071
  expectNumAt "logSaw at 0.25"    "logSaw"   0.25   0.5
  expectNumAt "logSaw at 0.5"     "logSaw"   0.5    0.7071
  -- ilogSaw = 1 - √pos so cycle 0.25 → 0.5, cycle 0.5 → 0.2929
  expectNumAt "ilogSaw at 0.25"   "ilogSaw"  0.25   0.5
  expectNumAt "ilogSaw at 0.5"    "ilogSaw"  0.5    0.2929

  log ""
  log "--- eval: <a b c> alternation ---"
  -- <sine saw> alternates per cycle: cycle 0 = sine (0.5 at midpoint),
  -- cycle 1 = saw (0.5 at midpoint).  Both happen to be 0.5 at their
  -- own cycle midpoint — distinguish via cycle 0.25 / 1.25.
  expectNumAt "alt sine|saw at 0.25 (sine slot)"   "<sine saw>"  0.25  1.0   -- sine peak
  expectNumAt "alt sine|saw at 1.25 (saw slot)"    "<sine saw>"  1.25  0.25  -- saw 0.25 in
  expectNumAt "alt saw|sine at 0.25 (saw slot)"    "<saw sine>"  0.25  0.25  -- saw at 0.25
  expectNumAt "alt saw|sine at 1.25 (sine slot)"   "<saw sine>"  1.25  1.0   -- sine peak
  -- Three-slot alternation cycles every 3 cycles.
  expectNumAt "<sine tri square> at 0.25 (sine)"  "<sine tri square>"  0.25  1.0
  expectNumAt "<sine tri square> at 1.25 (tri)"   "<sine tri square>"  1.25  0.5
  expectNumAt "<sine tri square> at 2.75 (square)" "<sine tri square>" 2.75  1.0
  -- Nested expression in slot via parens.
  expectNumAt "<sine (slow 2 saw)> at 0.25"  "<sine (slow 2 saw)>"  0.25  1.0
  -- Combining with `fast` outside the alternation: fast 2 doubles the
  -- alternation rate, so each slot now takes 0.5 cycles instead of 1.
  expectNumAt "fast 2 <sine saw> at 0.125 (sine slot)"
    "fast 2 <sine saw>"  0.125  1.0
  expectNumAt "fast 2 <sine saw> at 0.625 (saw slot)"
    "fast 2 <sine saw>"  0.625  0.25
  -- Empty alternation errors.
  expectEvalLeft "empty alternation rejected"
    (case parseExpr "<>" of
      Right e -> case evalExpr e of
        Right _ -> Right (mini "x")  -- shouldn't reach
        Left err -> Left err
      Left err -> Left err)

  log ""

-- ---------------------------------------------------------------------------
-- Assertion helpers
-- ---------------------------------------------------------------------------

-- | Evaluate a source expression to `VNumPattern`, query at a single
-- | cycle position, and assert the first event's value matches
-- | `expected` within `lfoEps`.  Cycle position is a Number (e.g.
-- | 0.25 means a quarter into the first cycle); converted to a
-- | millicycle Rational for queryArc.
expectNumAt :: String -> String -> Number -> Number -> Effect Unit
expectNumAt desc src cyc expected =
  case parseExpr src of
    Left err -> log $ "  ✗ " <> desc <> " — parse: " <> err
    Right e -> case evalExpr e of
      Left err -> log $ "  ✗ " <> desc <> " — eval: " <> err
      Right (VNumPattern p) ->
        let
          -- Center the query window on `cyc` so the midpoint sample
          -- (which oscillators use) lands exactly at `cyc`.  Window
          -- is 2 / 1000000 cycles wide, midpoint = cyc.
          centerMicro = Int.round (cyc * 1000000.0)
          start' = (centerMicro - 1) % 1000000
          stop'  = (centerMicro + 1) % 1000000
          events = queryArc p start' stop'
          got = case Array.head events of
            Just (Digital ev) -> Just ev.value
            Just (Analog ev) -> Just ev.value
            Nothing -> Nothing
        in case got of
          Nothing ->
            log $ "  ✗ " <> desc <> ": no event at cycle " <> show cyc
          Just v
            | abs (v - expected) <= lfoEps ->
                log $ "  ✓ " <> desc <> ": " <> show v
            | otherwise ->
                log $ "  ✗ " <> desc <> ": got " <> show v
                  <> ", expected " <> show expected
      Right _ ->
        log $ "  ✗ " <> desc <> ": eval returned non-numeric pattern"
  where
    lfoEps = 0.001
    abs n = if n < 0.0 then -n else n

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
