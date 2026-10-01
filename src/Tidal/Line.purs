-- | **The line language: what a Tidal user types, read the way GHCi reads it.**
-- |
-- | A block of text becomes one `Command`: `d1 $ s "bd*4" # n "0 2"` plays a
-- | control pattern on stream 1, `hush` silences the streams, `setcps 0.5`
-- | sets the tempo. Limulus sends these over the WebSocket as `tidal <block>`.
-- |
-- | The expression grammar is a small piece of Haskell's: application, the
-- | operators `$` (infixr 0), `.` (infixr 9) and the `#` family (infixl 9,
-- | the Haskell default, since Tidal declares no fixity for them), the
-- | arithmetic operators on plain numbers, parentheses, numbers and string
-- | literals. As in GHC, `.` and `#` may not be mixed without brackets.
-- |
-- | A string literal is mini-notation, read at the type of whatever consumes
-- | it: `s` reads samples, `n` notes, `gain` floats (`Tidal.Controls`). Every
-- | atom is checked there, so `n "0 zz"` is refused rather than half-played.
-- |
-- | Functions come from one table (`functions`). A name that is not in it is
-- | refused by name: a line that is accepted means what Tidal means, which
-- | the conformance harness holds it to. That is the difference from the
-- | retired `Tidal.Expr`, whose vocabulary looked like Tidal's and was not.
module Tidal.Line
  ( Command(..)
  , parseLine
  , functionNames
  ) where

import Prelude

import Data.Array (cons, elem, index, length, sort, uncons)
import Data.Array as Array
import Data.Either (Either(..), note)
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.Rational (Rational, (%))
import Data.Rational as Rational
import Data.String (trim)
import Data.String as String
import Data.String.CodeUnits as CU
import Data.Tuple (Tuple(..))
import Tidal.Controls (Control, Kind(..), controlFromMini, controls, keepLeft, keepRight)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Core (fast, rev, slow)
import Tidal.Pattern.Types (ControlPattern, silence)

-- | What a block asks for.
data Command
  = Play Int ControlPattern
  | Hush
  | SetCps Number

-------------------------------------------------------------------------------
-- Tokens
-------------------------------------------------------------------------------

data Token
  = TName String
  | TNumber String
  | TString String
  | TOp String
  | TOpen
  | TClose

derive instance Eq Token

describe :: Token -> String
describe = case _ of
  TName x -> x
  TNumber x -> x
  TString x -> show x
  TOp x -> x
  TOpen -> "("
  TClose -> ")"

isOpChar :: Char -> Boolean
isOpChar ch = elem ch [ '$', '.', '#', '|', '<', '>', '+', '-', '*', '/' ]

isNameStart :: Char -> Boolean
isNameStart ch = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'

isNameChar :: Char -> Boolean
isNameChar ch = isNameStart ch || isDigit ch || ch == '\''

isDigit :: Char -> Boolean
isDigit ch = ch >= '0' && ch <= '9'

-- | Split a block into tokens. `--` starts a comment to the end of the line.
tokenize :: String -> Either String (Array Token)
tokenize = go [] <<< CU.toCharArray
  where
  go acc chars = case uncons chars of
    Nothing -> Right (Array.reverse acc)
    Just { head, tail }
      | head == ' ' || head == '\n' || head == '\t' || head == '\r' -> go acc tail
      | head == '-' && index tail 0 == Just '-' ->
          go acc (Array.dropWhile (_ /= '\n') tail)
      | head == '(' -> go (cons TOpen acc) tail
      | head == ')' -> go (cons TClose acc) tail
      | head == '"' ->
          let body = Array.takeWhile (_ /= '"') tail
          in
            if length body == length tail then Left "a string is not closed"
            else go (cons (TString (CU.fromCharArray body)) acc) (Array.drop (length body + 1) tail)
      | isDigit head ->
          let
            digits = Array.takeWhile (\ch -> isDigit ch || ch == '.') chars
          in
            go (cons (TNumber (CU.fromCharArray digits)) acc) (Array.drop (length digits) chars)
      | isNameStart head ->
          let name = Array.takeWhile isNameChar chars
          in go (cons (TName (CU.fromCharArray name)) acc) (Array.drop (length name) chars)
      | isOpChar head ->
          let op = Array.takeWhile isOpChar chars
          in go (cons (TOp (CU.fromCharArray op)) acc) (Array.drop (length op) chars)
      | otherwise -> Left ("unexpected character " <> show (CU.singleton head))

-------------------------------------------------------------------------------
-- Expressions
-------------------------------------------------------------------------------

data Expr
  = EName String
  | ENumber String
  | EString String
  | EApp Expr Expr
  | EOp String Expr Expr
  | ENegate Expr

data Assoc = AssocLeft | AssocRight

derive instance Eq Assoc

-- | Haskell's fixities for the operators the language knows.
fixity :: String -> Maybe { prec :: Int, assoc :: Assoc }
fixity = case _ of
  "$" -> Just { prec: 0, assoc: AssocRight }
  "+" -> Just { prec: 6, assoc: AssocLeft }
  "-" -> Just { prec: 6, assoc: AssocLeft }
  "*" -> Just { prec: 7, assoc: AssocLeft }
  "/" -> Just { prec: 7, assoc: AssocLeft }
  "." -> Just { prec: 9, assoc: AssocRight }
  "#" -> Just { prec: 9, assoc: AssocLeft }
  "|>" -> Just { prec: 9, assoc: AssocLeft }
  "|<" -> Just { prec: 9, assoc: AssocLeft }
  _ -> Nothing

type Parse a = Array Token -> Either String (Tuple a (Array Token))

-- | Operator precedence by climbing. `seen` holds the associativity met so
-- | far at each level, so `a # b . c` is refused as GHC refuses it.
expr :: Int -> Parse Expr
expr minPrec tokens = do
  Tuple lhs rest <- application tokens
  climb lhs Nothing rest
  where
  climb lhs seen ts = case uncons ts of
    Just { head: TOp op, tail } -> case fixity op of
      Nothing -> Left ("unknown operator " <> op)
      Just f
        | f.prec < minPrec -> Right (Tuple lhs ts)
        | Just other <- seen, other.prec == f.prec, other.assoc /= f.assoc ->
            Left ("cannot mix " <> other.op <> " and " <> op <> " without brackets")
        | otherwise -> do
            let next = if f.assoc == AssocLeft then f.prec + 1 else f.prec
            Tuple rhs rest <- expr next tail
            climb (EOp op lhs rhs) (Just { prec: f.prec, assoc: f.assoc, op }) rest
    _ -> Right (Tuple lhs ts)

application :: Parse Expr
application tokens = do
  Tuple f rest <- atom tokens
  more f rest
  where
  more f ts = case atom ts of
    Right (Tuple x rest) -> more (EApp f x) rest
    Left _ -> Right (Tuple f ts)

atom :: Parse Expr
atom tokens = case uncons tokens of
  Just { head: TName x, tail } -> Right (Tuple (EName x) tail)
  Just { head: TNumber x, tail } -> Right (Tuple (ENumber x) tail)
  Just { head: TString x, tail } -> Right (Tuple (EString x) tail)
  Just { head: TOpen, tail } -> case uncons tail of
    -- `(-0.25)`: Haskell's one prefix operator.
    Just { head: TOp "-", tail: afterMinus } -> do
      Tuple inner rest <- expr 6 afterMinus
      closing (ENegate inner) rest
    _ -> do
      Tuple inner rest <- expr 0 tail
      closing inner rest
  Just { head } -> Left ("unexpected " <> describe head)
  Nothing -> Left "unexpected end of the line"
  where
  closing e ts = case uncons ts of
    Just { head: TClose, tail } -> Right (Tuple e tail)
    Just { head } -> Left ("expected ) but found " <> describe head)
    Nothing -> Left "a bracket is not closed"

-------------------------------------------------------------------------------
-- Values
-------------------------------------------------------------------------------

data Value
  = VPattern ControlPattern
  | VString String
  | VNumber Number Rational
  | VFunction String (Value -> Either String Value)

kindName :: Value -> String
kindName = case _ of
  VPattern _ -> "a control pattern"
  VString _ -> "a string"
  VNumber _ _ -> "a number"
  VFunction name _ -> "the function " <> name

asPattern :: Value -> Either String ControlPattern
asPattern = case _ of
  VPattern p -> Right p
  VString s -> Left ("the string " <> show s <> " is not a control pattern; did you mean s " <> show s <> "?")
  other -> Left (kindName other <> " is not a control pattern")

-- | A time argument, as `fast` and `slow` take one. Tidal patterns these; a
-- | constant is all this reads so far, and a pattern is refused by name.
asTime :: String -> Value -> Either String Rational
asTime fn = case _ of
  VNumber _ r -> Right r
  VString s -> case exactNumber (trim s) of
    Just r -> Right r
    Nothing -> Left ("a patterned argument to " <> fn <> " (" <> show s <> ") is not supported yet")
  other -> Left (fn <> " wants a number, not " <> kindName other)

-- | A decimal literal as an exact rational: `1.25` is 5/4, not a float.
exactNumber :: String -> Maybe Rational
exactNumber text = case String.split (String.Pattern ".") text of
  [ whole ] -> Int.fromString whole <#> Rational.fromInt
  [ whole, frac ] | frac /= "" -> do
    w <- Int.fromString whole
    f <- Int.fromString frac
    let scale = pow10 (CU.length frac)
    pure (Rational.fromInt w + (f % scale))
  _ -> Nothing
  where
  pow10 k = foldl (\acc _ -> acc * 10) 1 (Array.range 1 k)

function :: String -> (Value -> Either String Value) -> Value
function = VFunction

-- | A control applied to a string or a number, as `s "bd"` or `gain 0.8`.
controlFunction :: Control -> Value
controlFunction k = function k.name case _ of
  VString src -> VPattern <$> miniControl k src
  VNumber x _ -> case k.kind of
    KString -> Left (k.name <> " wants a string, not a number")
    KSound -> Left (k.name <> " wants a string, not a number")
    _ -> map VPattern (miniControl k (show' x))
  other -> Left (k.name <> " wants a string, not " <> kindName other)
  where
  show' x = if Int.toNumber (Int.round x) == x then show (Int.round x) else show x

-- | Mini-notation read at a control's kind, every atom checked.
miniControl :: Control -> String -> Either String ControlPattern
miniControl k src = case parse src of
  Left err -> Left ("mini-notation " <> show src <> ": " <> show err)
  Right tpat -> note (k.name <> " cannot read every value in " <> show src) (controlFromMini k tpat)

transform :: String -> (ControlPattern -> ControlPattern) -> Value
transform name f = function name \v -> VPattern <<< f <$> asPattern v

timeTransform :: String -> (Rational -> ControlPattern -> ControlPattern) -> Value
timeTransform name f = function name \t -> do
  r <- asTime name t
  pure (transform name (f r))

-- | Every name the language knows, controls included.
functions :: Array (Tuple String Value)
functions =
  [ Tuple "fast" (timeTransform "fast" fast)
  , Tuple "slow" (timeTransform "slow" slow)
  , Tuple "rev" (transform "rev" rev)
  , Tuple "id" (function "id" Right)
  , Tuple "silence" (VPattern silence)
  ]
    <> map (\k -> Tuple k.name (controlFunction k)) controls

functionNames :: Array String
functionNames = sort (map (\(Tuple name _) -> name) functions)

lookupName :: String -> Either String Value
lookupName name =
  note ("unknown name " <> name <> " (not in purerl-tidal's Tidal yet)")
    (map (\(Tuple _ v) -> v) (Array.find (\(Tuple n _) -> n == name) functions))

eval :: Expr -> Either String Value
eval = case _ of
  EName name -> lookupName name
  ENumber text -> number text
  EString s -> Right (VString s)
  ENegate e -> eval e >>= case _ of
    VNumber x r -> Right (VNumber (negate x) (negate r))
    other -> Left ("cannot negate " <> kindName other)
  EApp f x -> do
    fv <- eval f
    xv <- eval x
    applyValue fv xv
  EOp "$" f x -> do
    fv <- eval f
    xv <- eval x
    applyValue fv xv
  EOp "." f g -> do
    fv <- eval f
    gv <- eval g
    pure $ function "composition" \x -> applyValue gv x >>= applyValue fv
  EOp op a b -> do
    av <- eval a
    bv <- eval b
    binary op av bv
  where
  number text = case exactNumber text, Number.fromString text of
    Just r, Just x -> Right (VNumber x r)
    _, _ -> Left ("cannot read the number " <> text)

applyValue :: Value -> Value -> Either String Value
applyValue f x = case f of
  VFunction _ run -> run x
  other -> Left (kindName other <> " is not a function, so it cannot take " <> kindName x)

binary :: String -> Value -> Value -> Either String Value
binary op a b = case op, a, b of
  "#", _, _ -> both keepRight
  "|>", _, _ -> both keepRight
  "|<", _, _ -> both keepLeft
  "+", VNumber x r, VNumber y s -> Right (VNumber (x + y) (r + s))
  "-", VNumber x r, VNumber y s -> Right (VNumber (x - y) (r - s))
  "*", VNumber x r, VNumber y s -> Right (VNumber (x * y) (r * s))
  "/", VNumber x r, VNumber y s -> Right (VNumber (x / y) (r / s))
  _, _, _ -> Left (op <> " on " <> kindName a <> " and " <> kindName b <> " is not supported yet")
  where
  both f = do
    p <- asPattern a
    q <- asPattern b
    pure (VPattern (f p q))

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

-- | Read a block. `d1`..`d16` take an expression, as Tidal's do; `hush`
-- | stands alone; `setcps` takes a number (Tidal's takes a pattern; a
-- | constant is what this reads).
parseLine :: String -> Either String Command
parseLine text = do
  tokens <- tokenize text
  case uncons tokens of
    Nothing -> Left "nothing to evaluate"
    Just { head: TName "hush", tail: [] } -> Right Hush
    Just { head: TName "setcps", tail } -> do
      v <- whole tail >>= eval
      case v of
        VNumber x _ -> Right (SetCps x)
        VString s | Just r <- exactNumber (trim s) -> Right (SetCps (Rational.toNumber r))
        other -> Left ("setcps wants a number, not " <> kindName other)
    Just { head: TName name, tail } | Just n <- stream name -> do
      body <- case uncons tail of
        Just { head: TOp "$", tail: afterDollar } -> Right afterDollar
        _ -> Right tail
      v <- whole body >>= eval
      p <- asPattern v
      Right (Play n p)
    Just { head } -> Left ("a block starts with d1..d16, hush or setcps, not " <> describe head)
  where
  whole ts = do
    Tuple e rest <- expr 0 ts
    case uncons rest of
      Nothing -> Right e
      Just { head } -> Left ("unexpected " <> describe head)

-- | `d1`..`d16`, and nothing else.
stream :: String -> Maybe Int
stream name = do
  digits <- String.stripPrefix (String.Pattern "d") name
  n <- Int.fromString digits
  if n >= 1 && n <= 16 && show n == digits then Just n else Nothing
