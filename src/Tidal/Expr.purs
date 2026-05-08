-- | Host-language expression layer for purerl-tidal cells.
-- |
-- | Cells today only accept mini-notation. This module adds a thin
-- | expression layer on top so cells can write things like
-- |
-- | ```
-- | rev "bd sn"
-- | slow 2 "bd sn"
-- | every 4 rev "bd sn"
-- | ```
-- |
-- | Step 1 covers basic transformations (`id`, `rev`, `slow`, `fast`,
-- | `palindrome`, `every`) over mini-notation `String` literals.
-- |
-- | Step 2 adds the Branched fork/merge combinators:
-- |
-- | ```
-- | jux rev "c4 e4 g4 b4"
-- | mult [L:id, R:rev] "c4 e4 g4 b4"
-- | alternate [a:id, b:rev] "bd sn hh cp"
-- | crossfade "<L R L R>" [L:id, R:rev] "c4 e4 g4"
-- | gate [pad:false, lead:true] [pad:id, lead:rev] "c4 e4 g4"
-- | ```
-- |
-- | Per the MVP scope, fan-out specs only accept *bare names* for the
-- | per-voice transform — `[L:id, R:rev]` is fine, `[harm:slow 2]` is
-- | not yet (no partial application). Gate-map values are the bare names
-- | `true` / `false`, which desugar to `pure true` / `pure false` in
-- | `Pattern Boolean`.
module Tidal.Expr
  ( -- * AST
    Expr(..)
    -- * Parsing
  , parseExpr
    -- * Evaluation
  , EvalResult(..)
  , evalExpr
  , asPattern
  , eval
  , evalMulti
  , parseEvalPattern
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Lazy (defer)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Identity (Identity)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, (%))
import Data.Rational as Rational
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))
import Text.Parsing.Parser (ParserT, fail, runParser)
import Text.Parsing.Parser as P
import Text.Parsing.Parser.Combinators as PC
import Text.Parsing.Parser.String (char, satisfy)
import Text.Parsing.Parser.Token (alphaNum, digit, letter)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Parser (parseTPat)
import Tidal.Pattern.Branched (Voice(..))
import Tidal.Pattern.Branched as Branched
import Tidal.Pattern.Core
  ( brak
  , compress
  , cosine
  , every
  , expSaw
  , fast
  , iexpSaw
  , ilogSaw
  , isaw
  , iter
  , linger
  , logSaw
  , off
  , palindrome
  , rand
  , range
  , rev
  , rotL
  , rotR
  , saw
  , sine
  , slow
  , slowCat
  , square
  , stutter
  , tri
  , trunc
  , zoom
  )
import Tidal.Pattern.Types
  ( Arc(..), Event(..), Pattern, State(..), emptyContext, pattern, silence )
import Control.Apply (lift2)
import Data.Rational (toNumber) as RT

-- ---------------------------------------------------------------------------
-- AST
-- ---------------------------------------------------------------------------

-- | Host-language expression.
-- |
-- | * `EVar` — bare identifier (function or value reference).
-- | * `ENum` — numeric literal (`2`, `1/4`).
-- | * `EStr` — mini-notation string literal (`"bd sn"`).
-- | * `EApp` — function application (head, args).
-- | * `EList` — bracketed list (fan-out spec, future use).
-- | * `ETag` — `name:expr` (Voice-tagged entry inside an `EList`).
data Expr
  = EVar String
  | ENum Rational
  | EStr String
  | EApp Expr (Array Expr)
  | EList (Array Expr)
  | ETag String Expr

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

type Parser a = ParserT String Identity a

-- | Parse a host-language expression.
parseExpr :: String -> Either String Expr
parseExpr input = case runParser input (skipWS *> exprTop <* eofP) of
  Right e -> Right e
  Left err -> Left (P.parseErrorMessage err)

eofP :: Parser Unit
eofP = PC.notFollowedBy (satisfy (const true)) PC.<?> "end of input"

-- A top-level expression is either a function application (head + args)
-- or a single atom on its own.
exprTop :: Parser Expr
exprTop = defer \_ -> do
  h <- atom
  args <- many atom
  pure case args of
    [] -> h
    _ -> EApp h args

-- An "atom" is something that could appear as a head or as an argument.
atom :: Parser Expr
atom = defer \_ -> do
  e <- pStringLit <|> pListLit <|> pAlt <|> pParens <|> pNumberE <|> pTagOrVar
  skipWS
  pure e

-- | Angle-bracket alternation: `<a b c>` desugars to `alt [a, b, c]`,
-- | which evaluates to `slowCat [pat_a, pat_b, pat_c]` — each slot
-- | takes one cycle, the alternation cycles through them.
-- |
-- | Each slot is a single atom; use parens for multi-token expressions:
-- | `<sine (slow 2 tri) saw>` has three slots.  Polymorphic over
-- | Pattern String / Pattern Number: the first slot's evaluated kind
-- | decides which one applies to all.
pAlt :: Parser Expr
pAlt = defer \_ -> do
  _ <- char '<'
  skipWS
  items <- many atom
  _ <- char '>'
  pure (EApp (EVar "alt") items)

-- Parenthesised expression — grouping for nested function application.
-- `palindrome (fast 4 "bd sn")` parses as `palindrome` applied to one
-- argument (the `fast 4 "bd sn"` sub-application). Without parens
-- the same source would parse as `palindrome` applied to three
-- arguments, which is an arity error.
pParens :: Parser Expr
pParens = defer \_ -> do
  _ <- char '('
  skipWS
  e <- exprTop
  _ <- char ')'
  pure e

pTagOrVar :: Parser Expr
pTagOrVar = defer \_ -> do
  n <- name
  -- Look for a `:` for a tag (`name:expr`), otherwise it's a bare var.
  PC.optionMaybe (char ':') >>= case _ of
    Just _ -> do
      skipWS
      e <- atom
      pure (ETag n e)
    Nothing -> pure (EVar n)

pListLit :: Parser Expr
pListLit = defer \_ -> do
  _ <- char '['
  skipWS
  items <- PC.sepBy atom (char ',' *> skipWS)
  _ <- char ']'
  pure (EList (Array.fromFoldable items))

pStringLit :: Parser Expr
pStringLit = do
  _ <- char '"'
  cs <- many (satisfy (\c -> c /= '"'))
  _ <- char '"'
  pure (EStr (SCU.fromCharArray cs))

pNumberE :: Parser Expr
pNumberE = do
  sign <- PC.option 1 (char '-' $> -1)
  num <- pInt
  let signed = sign * num
  mTail <- PC.optionMaybe
    ( PC.try (do
        _ <- char '/'
        d <- pInt
        pure (signed % d))
    <|>
      (do
        _ <- char '.'
        digits <- many1 digit
        let
          fracInt = case Int.fromString (SCU.fromCharArray digits) of
            Just k -> k
            Nothing -> 0
          den = pow10 (Array.length digits)
        -- Use the original `sign` (-1 or +1), not `signed`, because
        -- `signed = sign * num` loses sign info when num is 0 — so
        -- `-0.5` would parse as +0.5 if we derived the sign from
        -- `signed < 0`.  This is what was breaking
        -- `range -0.5 0.5 (slow 4 sine)`: lo and hi both became 0.5,
        -- producing a constant 0.5 LFO output instead of a swing.
        pure ((sign * (num * den + fracInt)) % den))
    )
  pure (ENum (case mTail of
    Just r -> r
    Nothing -> Rational.fromInt signed))

pow10 :: Int -> Int
pow10 n = if n <= 0 then 1 else 10 * pow10 (n - 1)

pInt :: Parser Int
pInt = do
  ds <- many1 digit
  case Int.fromString (SCU.fromCharArray ds) of
    Just n -> pure n
    Nothing -> fail "bad integer literal"

name :: Parser String
name = do
  c <- letter
  cs <- many (alphaNum <|> satisfy (_ == '_'))
  pure (SCU.fromCharArray (Array.cons c cs))

skipWS :: Parser Unit
skipWS = void (many (satisfy isSpace))

isSpace :: Char -> Boolean
isSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

many :: forall a. Parser a -> Parser (Array a)
many = Array.many

many1 :: forall a. Parser a -> Parser (Array a)
many1 p = do
  x <- p
  xs <- many p
  pure (Array.cons x xs)

-- ---------------------------------------------------------------------------
-- Evaluator
-- ---------------------------------------------------------------------------

-- | The runtime value an expression evaluates to. Tagged because the
-- | evaluator carries pattern-valued, function-valued, list-valued, and
-- | scalar results through the same dispatch path.
data EvalResult
  = VPattern (Pattern String)
  -- ^ A discrete sample-name / mini-notation pattern.
  | VNumPattern (Pattern Number)
  -- ^ A continuous numeric pattern — oscillators (`sine`, `saw`, …),
  --   results of `range`/`add`/`mul`/`sub`/`neg`, and any time-warp
  --   (`slow`/`fast`/`rev`/…) applied to one. Routed to a continuous
  --   voice (MIDI CC or CV bus) by the scheduler.
  | VFunc (Pattern String -> Pattern String)
  | VInt Int
  | VRat Rational
  | VBool Boolean
  | VList (Array EvalResult)
  | VTagged String EvalResult

-- | Evaluate an expression to an `EvalResult`.
evalExpr :: Expr -> Either String EvalResult
evalExpr = case _ of
  ENum r -> Right (VRat r)
  EStr s -> case parseTPat s of
    Right tpat -> Right (VPattern (tpatToPattern tpat))
    Left _ -> Left ("bad mini-notation: " <> s)
  EVar n -> resolveVar n
  EApp h args -> do
    rArgs <- traverseArgs args
    applyExpr h rArgs
  EList xs -> VList <$> traverseArgs xs
  ETag n e -> VTagged n <$> evalExpr e

-- | Top-level evaluator: parse + evaluate, expecting a `Pattern String`.
eval :: String -> Either String (Pattern String)
eval src = do
  e <- parseExpr src
  r <- evalExpr e
  asPattern r

-- | Multi-destination evaluator for the bare `:<expr>` form.
-- |
-- | Voice tags in the fan-out spec name destinations directly
-- | (`[bass:id, lead:rev]` → bass and lead bindings).  The result is an
-- | array of (binding-name, Pattern) pairs the scheduler dispatches as
-- | parallel BoundTracks — each voice's transformed pattern flows
-- | through its own binding's note resolver and goes to its own
-- | destination.
-- |
-- | v1 only supports `mult` at the top level.  `alternate`, `crossfade`,
-- | and `gate` need pattern-level masking to give a sensible
-- | per-destination interpretation; until that exists, they return an
-- | error pointing the user at the bound-name `<name> :<expr>` form
-- | (which merges through one channel).
evalMulti :: String -> Either String (Array (Tuple String (Pattern String)))
evalMulti src = do
  e <- parseExpr src
  case e of
    EApp (EVar "mult") [ specE, patE ] -> do
      specR <- evalExpr specE
      patR <- evalExpr patE
      spec <- asFanOutSpec "mult" specR
      pat <- asPattern patR
      Right (perVoicePatterns (Branched.fanOut spec pat))
    EApp (EVar "mult") args ->
      Left ("mult: expected 2 arguments, got " <> show (Array.length args))
    EApp (EVar "alternate") _ ->
      Left "alternate is not yet supported in bare :expr form — use `<binding> :alternate ...` instead"
    EApp (EVar "crossfade") _ ->
      Left "crossfade is not yet supported in bare :expr form — use `<binding> :crossfade ...` instead"
    EApp (EVar "gate") _ ->
      Left "gate is not yet supported in bare :expr form — use `<binding> :gate ...` instead"
    _ -> Left "bare :expr requires a multi-destination form (mult [name:fn, ...] pat)"

-- | Pull the `Voice` newtype back to a `String` and pair it with its
-- | per-voice pattern.  Insertion order is preserved by `Branched`.
perVoicePatterns
  :: Branched.Branched String
  -> Array (Tuple String (Pattern String))
perVoicePatterns b =
  map (\(Tuple (Voice name) p) -> Tuple name p) (Branched.branches b)

traverseArgs :: Array Expr -> Either String (Array EvalResult)
traverseArgs = go []
  where
    go acc xs = case Array.uncons xs of
      Nothing -> Right acc
      Just { head, tail } -> do
        r <- evalExpr head
        go (Array.snoc acc r) tail

-- Resolve a bare identifier. Anything in the registry resolves to its
-- registered value; unknown names are an error (we choose strictness
-- over silent silence).
resolveVar :: String -> Either String EvalResult
resolveVar n = case n of
  "id" -> Right (VFunc identity)
  "rev" -> Right (VFunc rev)
  "palindrome" -> Right (VFunc palindrome)
  "brak" -> Right (VFunc brak)
  "silence" -> Right (VPattern silence)
  "true" -> Right (VBool true)
  "false" -> Right (VBool false)
  -- Continuous oscillators — values 0..1 over each cycle.  Wrap as
  -- VNumPattern so they propagate through arithmetic / `range` /
  -- `slow` and end up driving a continuous voice.
  "sine"   -> Right (VNumPattern sine)
  "cosine" -> Right (VNumPattern cosine)
  "saw"    -> Right (VNumPattern saw)
  "isaw"   -> Right (VNumPattern isaw)
  "tri"    -> Right (VNumPattern tri)
  "square" -> Right (VNumPattern square)
  -- Curved ramps: pos²/√pos and their 1→0 inverses.  Pair with the
  -- linear `saw`/`isaw` for modular-style log/exp shapes.
  "expSaw"  -> Right (VNumPattern expSaw)
  "iexpSaw" -> Right (VNumPattern iexpSaw)
  "logSaw"  -> Right (VNumPattern logSaw)
  "ilogSaw" -> Right (VNumPattern ilogSaw)
  "rand"   -> Right (VNumPattern rand)
  _ -> Left ("unknown identifier: " <> n)

-- Apply a head expression to an array of evaluated arguments.
applyExpr :: Expr -> Array EvalResult -> Either String EvalResult
applyExpr head args = case head of
  EVar n -> applyExprByName n args
  _ -> Left "only named functions can be applied"

applyExprByName :: String -> Array EvalResult -> Either String EvalResult
applyExprByName n args = case n of
  "id" -> oneArg "id" args >>= asPattern <#> VPattern
  "rev" -> oneArgPoly "rev" rev rev args
  "palindrome" -> oneArgPoly "palindrome" palindrome palindrome args
  "brak" -> oneArg "brak" args >>= asPattern <#> (brak >>> VPattern)
  "slow" -> binOpPoly "slow" slow slow args
  "fast" -> binOpPoly "fast" fast fast args
  -- `speed N pat`: alternative naming where N > 1 speeds up and N < 1
  -- slows down.  Equivalent to `fast` (since `slow n = fast (1/n)`),
  -- but reads more naturally if you think in playback-speed terms
  -- ("speed 0.5" = half speed) rather than fast/slow direction-words.
  "speed" -> binOpPoly "speed" fast fast args
  "linger" -> binOp "linger" linger args
  "trunc" -> binOp "trunc" trunc args
  "rotL" -> binOp "rotL" rotL args
  "rotR" -> binOp "rotR" rotR args
  "iter" -> intBinOp "iter" iter args
  "compress" -> ratPairOp "compress" compress args
  "zoom" -> ratPairOp "zoom" zoom args
  "off" -> ratFunOp "off" off args
  "stutter" -> intRatOp "stutter" stutter args
  "every" -> applyExprEvery args
  -- Branched combinators
  "jux" -> applyJux args
  "mult" -> applyMult args
  "alternate" -> applyAlternate args
  "crossfade" -> applyCrossfade args
  "gate" -> applyGate args
  -- Continuous-numeric pattern operators.  All return VNumPattern.
  "range" -> applyRange args
  "add" -> numArithOp "add" (+) args
  "mul" -> numArithOp "mul" (*) args
  "sub" -> numArithOp "sub" (-) args
  "neg" -> applyNeg args
  -- Angle-bracket alternation: `<a b c>` desugars to `alt [a, b, c]`.
  -- Polymorphic over String / Number patterns; first slot's kind
  -- decides the result kind, all other slots must match.
  "alt" -> applyAlt args
  _ -> Left ("unknown function: " <> n)

-- `slow N pat` / `fast N pat`.  1-arg partial application returns a
-- `VFunc` so `(slow 2)` can sit inside a fan-out spec
-- (`[lead2:(slow 2)]`) — useful for Fugue Machine vocabulary.
binOp
  :: String
  -> (Rational -> Pattern String -> Pattern String)
  -> Array EvalResult
  -> Either String EvalResult
binOp fname f args = case args of
  [ a ] -> do
    n <- asRational fname a
    Right (VFunc (f n))
  [ a, b ] -> do
    n <- asRational fname a
    p <- asPattern b
    Right (VPattern (f n p))
  _ -> Left (fname <> ": expected 1 or 2 arguments, got " <> show (Array.length args))

-- | Polymorphic version of `binOp` — accepts both `VPattern` (Pattern
-- | String) and `VNumPattern` (Pattern Number) and returns the matching
-- | variant.  Takes the time-warp at both type specialisations because
-- | PureScript's type inference doesn't propagate the polymorphism
-- | through case branches without explicit annotations.
-- |
-- | The 1-arg partial returns a `VFunc` over Pattern String only —
-- | partial-app of `slow 2` against a Number pattern would need a
-- | `VNumFunc` constructor we haven't added.  For LFOs the
-- | full-application form (`slow 4 sine`) covers the common case.
binOpPoly
  :: String
  -> (Rational -> Pattern String -> Pattern String)
  -> (Rational -> Pattern Number -> Pattern Number)
  -> Array EvalResult
  -> Either String EvalResult
binOpPoly fname fStr fNum args = case args of
  [ a ] -> do
    n <- asRational fname a
    Right (VFunc (fStr n))
  [ a, b ] -> do
    n <- asRational fname a
    case b of
      VPattern p -> Right (VPattern (fStr n p))
      VNumPattern p -> Right (VNumPattern (fNum n p))
      _ -> Left (fname <> ": expected pattern, got " <> showResult b)
  _ -> Left (fname <> ": expected 1 or 2 arguments, got " <> show (Array.length args))

-- | Polymorphic version of `oneArg`-style transforms (rev, palindrome).
oneArgPoly
  :: String
  -> (Pattern String -> Pattern String)
  -> (Pattern Number -> Pattern Number)
  -> Array EvalResult
  -> Either String EvalResult
oneArgPoly fname fStr fNum args = case args of
  [ a ] -> case a of
    VPattern p -> Right (VPattern (fStr p))
    VNumPattern p -> Right (VNumPattern (fNum p))
    _ -> Left (fname <> ": expected pattern, got " <> showResult a)
  _ -> Left (fname <> ": expected 1 argument, got " <> show (Array.length args))

-- | `range lo hi pat` — scales a 0..1 pattern to [lo, hi].  All three
-- | args must be Numeric; the pattern is coerced from VRat/VInt scalars
-- | (interpreted as constant patterns) if needed.
applyRange :: Array EvalResult -> Either String EvalResult
applyRange args = case args of
  [ a, b, c ] -> do
    lo <- asNumber "range" a
    hi <- asNumber "range" b
    p <- asNumPattern "range" c
    Right (VNumPattern (range lo hi p))
  _ -> Left ("range: expected 3 arguments (lo hi pat), got " <> show (Array.length args))

-- | `add a b` / `mul a b` / `sub a b` — pointwise arithmetic on two
-- | numeric patterns.  Either argument may be a scalar (Int / Rational),
-- | in which case it's promoted to the constant pattern `pure n`.
numArithOp
  :: String
  -> (Number -> Number -> Number)
  -> Array EvalResult
  -> Either String EvalResult
numArithOp fname op args = case args of
  [ a, b ] -> do
    pa <- asNumPattern fname a
    pb <- asNumPattern fname b
    Right (VNumPattern (lift2 op pa pb))
  _ -> Left (fname <> ": expected 2 arguments, got " <> show (Array.length args))

applyNeg :: Array EvalResult -> Either String EvalResult
applyNeg args = case args of
  [ a ] -> do
    p <- asNumPattern "neg" a
    Right (VNumPattern (negate <$> p))
  _ -> Left ("neg: expected 1 argument, got " <> show (Array.length args))

-- | `<a b c>` alternation — desugared by the parser into `alt a b c`.
-- | The first arg's evaluated kind decides whether the result is a
-- | string or number pattern; remaining args must match.  All cases
-- | use `slowCat`, so each slot takes one cycle and the alternation
-- | repeats every N cycles where N is the slot count.
applyAlt :: Array EvalResult -> Either String EvalResult
applyAlt args = case Array.uncons args of
  Nothing -> Left "alt: empty alternation"
  Just { head } -> case head of
    VNumPattern _ -> do
      ps <- traverseArgsAs (asNumPattern "alt") args
      Right (VNumPattern (slowCat ps))
    VPattern _ -> do
      ps <- traverseArgsAs (asPattern' "alt") args
      Right (VPattern (slowCat ps))
    other -> Left ("alt: first slot must be a pattern, got " <> showResult other)

-- | Pull a `Pattern String` out of an `EvalResult`.  Errors with the
-- | function name in the message for context.  Distinct from
-- | `asPattern` (which is the existing helper without the fname tag)
-- | because the existing one is already in scope and used by the
-- | string-typed dispatchers; this variant keeps the polymorphic
-- | `applyAlt` error message uniform with `asNumPattern`.
asPattern' :: String -> EvalResult -> Either String (Pattern String)
asPattern' fname r = case r of
  VPattern p -> Right p
  _ -> Left (fname <> ": expected string pattern, got " <> showResult r)

-- | `traverse f` over EvalResult arrays, accumulating Either errors.
traverseArgsAs
  :: forall a
   . (EvalResult -> Either String a)
  -> Array EvalResult
  -> Either String (Array a)
traverseArgsAs f = Array.foldM step []
  where
    step acc r = do
      v <- f r
      Right (Array.snoc acc v)

-- | Coerce an `EvalResult` to a `Pattern Number`.  Promotes scalars
-- | (`VInt`, `VRat`) to constant *Analog* patterns; passes
-- | `VNumPattern` through.  Errors on `VPattern` (string-typed) and
-- | other shapes.
-- |
-- | Why Analog and not `pure`?  `pure n` produces Digital events,
-- | one per cycle.  Tidal's default `Apply` for `Pattern` filters
-- | the right side to Digital when the left is Digital — so
-- | `lift2 (*) (pure 0.5) sine` would drop sine's Analog events
-- | and produce silence.  Wrapping scalars as Analog (covering the
-- | full query arc, value constant) means `combineAnalog` runs
-- | instead and the arithmetic comes through.
asNumPattern :: String -> EvalResult -> Either String (Pattern Number)
asNumPattern fname r = case r of
  VNumPattern p -> Right p
  VInt n -> Right (constAnalog (Int.toNumber n))
  VRat n -> Right (constAnalog (RT.toNumber n))
  _ -> Left (fname <> ": expected numeric pattern, got " <> showResult r)

-- | Continuous constant pattern: returns one Analog event covering the
-- | query arc, with the supplied value.  Used to promote scalar
-- | arguments when mixing them with oscillators.
constAnalog :: Number -> Pattern Number
constAnalog v = pattern \(State { arc }) ->
  [ Analog { context: emptyContext, part: arc, value: v } ]

-- | Pull a `Number` out of an `EvalResult`.  Accepts both `VInt` and
-- | `VRat` (since `range` / arithmetic don't need rational precision).
asNumber :: String -> EvalResult -> Either String Number
asNumber fname r = case r of
  VInt n -> Right (Int.toNumber n)
  VRat n -> Right (RT.toNumber n)
  _ -> Left (fname <> ": expected number, got " <> showResult r)

-- | Short tag of an EvalResult variant, for error messages.
showResult :: EvalResult -> String
showResult = case _ of
  VPattern _ -> "pattern (string)"
  VNumPattern _ -> "pattern (number)"
  VFunc _ -> "function"
  VInt _ -> "int"
  VRat _ -> "rational"
  VBool _ -> "bool"
  VList _ -> "list"
  VTagged _ _ -> "tagged"

-- `iter N pat` etc.  Int + Pattern.  1-arg partial returns VFunc.
intBinOp
  :: String
  -> (Int -> Pattern String -> Pattern String)
  -> Array EvalResult
  -> Either String EvalResult
intBinOp fname f args = case args of
  [ a ] -> do
    n <- asInt fname a
    Right (VFunc (f n))
  [ a, b ] -> do
    n <- asInt fname a
    p <- asPattern b
    Right (VPattern (f n p))
  _ -> Left (fname <> ": expected 1 or 2 arguments, got " <> show (Array.length args))

-- `compress lo hi pat` / `zoom lo hi pat`.  2 rationals + Pattern.
-- 2-arg partial application returns a `VFunc`.
ratPairOp
  :: String
  -> (Rational -> Rational -> Pattern String -> Pattern String)
  -> Array EvalResult
  -> Either String EvalResult
ratPairOp fname f args = case args of
  [ a, b ] -> do
    x <- asRational fname a
    y <- asRational fname b
    Right (VFunc (f x y))
  [ a, b, c ] -> do
    x <- asRational fname a
    y <- asRational fname b
    p <- asPattern c
    Right (VPattern (f x y p))
  _ -> Left (fname <> ": expected 2 or 3 arguments, got " <> show (Array.length args))

-- `off N g pat`.  Rational + (Pattern -> Pattern) + Pattern.
-- 2-arg partial application returns a `VFunc`.
ratFunOp
  :: String
  -> ( Rational
       -> (Pattern String -> Pattern String)
       -> Pattern String
       -> Pattern String
     )
  -> Array EvalResult
  -> Either String EvalResult
ratFunOp fname f args = case args of
  [ a, b ] -> do
    n <- asRational fname a
    g <- asFunc fname b
    Right (VFunc (f n g))
  [ a, b, c ] -> do
    n <- asRational fname a
    g <- asFunc fname b
    p <- asPattern c
    Right (VPattern (f n g p))
  _ -> Left (fname <> ": expected 2 or 3 arguments, got " <> show (Array.length args))

-- `stutter N rate pat`.  Int + Rational + Pattern.
-- 2-arg partial application returns a `VFunc`.
intRatOp
  :: String
  -> (Int -> Rational -> Pattern String -> Pattern String)
  -> Array EvalResult
  -> Either String EvalResult
intRatOp fname f args = case args of
  [ a, b ] -> do
    n <- asInt fname a
    r <- asRational fname b
    Right (VFunc (f n r))
  [ a, b, c ] -> do
    n <- asInt fname a
    r <- asRational fname b
    p <- asPattern c
    Right (VPattern (f n r p))
  _ -> Left (fname <> ": expected 2 or 3 arguments, got " <> show (Array.length args))

-- `every N f pat`.  2-arg partial application returns a `VFunc`
-- so `(every 4 rev)` can sit inside a fan-out spec.
applyExprEvery :: Array EvalResult -> Either String EvalResult
applyExprEvery args = case args of
  [ a, b ] -> do
    n <- asInt "every" a
    f <- asFunc "every" b
    Right (VFunc (every n f))
  [ a, b, c ] -> do
    n <- asInt "every" a
    f <- asFunc "every" b
    p <- asPattern c
    Right (VPattern (every n f p))
  _ -> Left ("every: expected 2 or 3 arguments, got " <> show (Array.length args))

oneArg :: String -> Array EvalResult -> Either String EvalResult
oneArg fname args = case args of
  [ a ] -> Right a
  _ -> Left (fname <> ": expected 1 argument, got " <> show (Array.length args))

-- ---------------------------------------------------------------------------
-- Branched combinators
-- ---------------------------------------------------------------------------

-- `jux <f> <pat>`. `f` must be a bare registry name (no partial app yet).
applyJux :: Array EvalResult -> Either String EvalResult
applyJux args = case args of
  [ a, b ] -> do
    f <- asFunc "jux" a
    p <- asPattern b
    Right (VPattern (Branched.jux f p))
  _ -> Left ("jux: expected 2 arguments, got " <> show (Array.length args))

-- `mult <fanOutSpec> <pat>`.
applyMult :: Array EvalResult -> Either String EvalResult
applyMult args = case args of
  [ a, b ] -> do
    spec <- asFanOutSpec "mult" a
    p <- asPattern b
    Right (VPattern (Branched.mult spec p))
  _ -> Left ("mult: expected 2 arguments, got " <> show (Array.length args))

-- `alternate <fanOutSpec> <pat>`.
applyAlternate :: Array EvalResult -> Either String EvalResult
applyAlternate args = case args of
  [ a, b ] -> do
    spec <- asFanOutSpec "alternate" a
    p <- asPattern b
    Right (VPattern (Branched.alternate (Branched.fanOut spec p)))
  _ -> Left ("alternate: expected 2 arguments, got " <> show (Array.length args))

-- `crossfade <voiceStringPat> <fanOutSpec> <pat>`.
applyCrossfade :: Array EvalResult -> Either String EvalResult
applyCrossfade args = case args of
  [ a, b, c ] -> do
    voicePat <- asVoicePattern "crossfade" a
    spec <- asFanOutSpec "crossfade" b
    p <- asPattern c
    Right (VPattern (Branched.crossfade voicePat (Branched.fanOut spec p)))
  _ -> Left ("crossfade: expected 3 arguments, got " <> show (Array.length args))

-- `gate <gateMap> <fanOutSpec> <pat>`.
applyGate :: Array EvalResult -> Either String EvalResult
applyGate args = case args of
  [ a, b, c ] -> do
    gmap <- asGateMap "gate" a
    spec <- asFanOutSpec "gate" b
    p <- asPattern c
    Right (VPattern (Branched.gate gmap (Branched.fanOut spec p)))
  _ -> Left ("gate: expected 3 arguments, got " <> show (Array.length args))

-- ---------------------------------------------------------------------------
-- EvalResult coercions
-- ---------------------------------------------------------------------------

asPattern :: EvalResult -> Either String (Pattern String)
asPattern = case _ of
  VPattern p -> Right p
  _ -> Left "expected a pattern"

-- | Convenience: parse an expression source, evaluate it, and coerce
-- | the result to a `Pattern String`. Used by the WS handler's
-- | PlayByNameExpr migration to install single-voice patterns through
-- | the new tree without surfacing intermediate value types to Erlang.
-- |
-- | Returns `Left` for any of: parse failure, eval failure, or eval
-- | success with a non-`VPattern` result (e.g. `VNumPattern` from a
-- | continuous expression — those are routed to MIDIScheduler by the
-- | caller, which has continuousBindings).
parseEvalPattern :: String -> Either String (Pattern String)
parseEvalPattern src = parseExpr src >>= evalExpr >>= asPattern

-- A list of functions is treated as left-to-right composition:
-- `[rev, (slow 2)]` means "apply rev, then slow 2" — i.e. the
-- composed function is `(slow 2) . rev`.  Empty list = identity.
-- Recursive: lists of lists also compose.
asFunc
  :: String
  -> EvalResult
  -> Either String (Pattern String -> Pattern String)
asFunc ctx = case _ of
  VFunc f -> Right f
  VList items -> do
    fs <- traverseEither (asFunc ctx) items
    Right (Array.foldl (\acc f -> f <<< acc) identity fs)
  _ -> Left (ctx <> ": expected a function argument")

asRational :: String -> EvalResult -> Either String Rational
asRational ctx = case _ of
  VRat r -> Right r
  VInt n -> Right (Rational.fromInt n)
  _ -> Left (ctx <> ": expected a number argument")

asInt :: String -> EvalResult -> Either String Int
asInt ctx = case _ of
  VInt n -> Right n
  VRat r ->
    let
      num = Rational.numerator r
      den = Rational.denominator r
    in
      if den == 1 then Right num
      else Left (ctx <> ": expected an integer, got " <> show num <> "/" <> show den)
  _ -> Left (ctx <> ": expected an integer argument")

-- A fan-out spec is `[name:fn, ...]` — a `VList` of `VTagged String VFunc`.
-- Returns the tuples in declared order so `fanOut` preserves voice order.
asFanOutSpec
  :: String
  -> EvalResult
  -> Either
       String
       (Array (Tuple Voice (Pattern String -> Pattern String)))
asFanOutSpec ctx = case _ of
  VList items -> traverseEither (oneEntry ctx) items
  _ -> Left (ctx <> ": expected a fan-out spec like [L:rev, R:id]")
  where
    oneEntry c = case _ of
      VTagged name v -> do
        f <- asFunc (c <> ": branch \"" <> name <> "\"") v
        Right (Tuple (Voice name) f)
      _ -> Left (c <> ": fan-out spec entries must be name:function")

-- A gate map is `[name:bool, ...]` — a `VList` of `VTagged String VBool`.
-- The bare names `true` / `false` desugar to `pure true` / `pure false`.
asGateMap
  :: String
  -> EvalResult
  -> Either String (Map Voice (Pattern Boolean))
asGateMap ctx = case _ of
  VList items -> do
    pairs <- traverseEither (oneEntry ctx) items
    Right (Map.fromFoldable pairs)
  _ -> Left (ctx <> ": expected a gate map like [lead:true, pad:false]")
  where
    oneEntry c = case _ of
      VTagged name (VBool b) -> Right (Tuple (Voice name) (pure b))
      VTagged name _ -> Left
        (c <> ": gate-map value for \"" <> name
          <> "\" must be `true` or `false`")
      _ -> Left (c <> ": gate-map entries must be name:bool")

-- The crossfade selector takes a mini-notation string and lifts the
-- per-event String into a `Voice` newtype.
asVoicePattern
  :: String
  -> EvalResult
  -> Either String (Pattern Voice)
asVoicePattern ctx = case _ of
  VPattern p -> Right (map Voice p)
  _ -> Left (ctx <> ": expected a mini-notation string for voice selection")

-- Local Either-traversal that keeps the result in Array shape.
traverseEither
  :: forall a b
   . (a -> Either String b)
  -> Array a
  -> Either String (Array b)
traverseEither f = go []
  where
    go acc xs = case Array.uncons xs of
      Nothing -> Right acc
      Just { head, tail } -> do
        b <- f head
        go (Array.snoc acc b) tail

