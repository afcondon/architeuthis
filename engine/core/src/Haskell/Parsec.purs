-- | **Haskell's Parsec**: `Text.Parsec` (parsec 3.1), over a `String`.
-- |
-- | Part of the reference-semantics types (`Haskell.*`): importing this
-- | module says "these parsers mean what Parsec means", not what
-- | purescript-parsing means. Tidal's grammar is written in Parsec, and
-- | which inputs it accepts depends on Parsec's rules for consumption and
-- | backtracking, so a faithful port of the grammar needs these rules
-- | underneath it. Where they differ from purescript-parsing:
-- |
-- | - `string` consumes what it matched before failing (Parsec's `tokens`):
-- |   `string "ab"` on "ax" is a *consumed* error, so `<|>` will not try its
-- |   alternative without `try`. purescript-parsing's `string` is atomic.
-- | - The input is read by code point, as Haskell's `Char` is; `letter`,
-- |   `alphaNum` and `space` are Unicode, `digit` is ASCII, as in
-- |   `Data.Char`. A code point outside the BMP is one token but cannot be a
-- |   PureScript `Char`, so no `Char` predicate accepts it.
-- | - The user state rolls back with the input on backtracking, as Parsec's
-- |   does (`getState` / `putState` / `modifyState`).
-- | - Errors merge as Parsec's do (the furthest wins; equal positions pool
-- |   their messages) and print as Parsec prints them:
-- |   `(line 1, column 3):\nunexpected "x"\nexpecting "]"`.
-- | - Positions are Parsec's: from (1, 1), a tab advancing to the next
-- |   multiple of 8 plus one.
-- | - `many` on a parser that succeeds without consuming is an error, as in
-- |   Parsec, rather than a loop.
-- |
-- | Only the stream type is narrowed: `Parsec u a` is Haskell's
-- | `Parsec String u a`.
module Haskell.Parsec
  ( Parsec
  , SourcePos
  , sourceName
  , sourceLine
  , sourceColumn
  , ParseError
  , errorPos
  , runParser
  , parse
    -- * State
  , getPosition
  , getInput
  , getState
  , putState
  , modifyState
    -- * Combinators
  , try
  , lookAhead
  , notFollowedBy
  , label
  , (<?>)
  , unexpected
  , fail
  , parserZero
  , many
  , many1
  , skipMany
  , skipMany1
  , option
  , optionMaybe
  , optional
  , choice
  , between
  , sepBy
  , sepBy1
  , count
  , eof
    -- * Characters
  , satisfy
  , char
  , string
  , oneOf
  , noneOf
  , anyChar
  , digit
  , letter
  , alphaNum
  , space
  , spaces
  , upper
  , lower
  ) where

import Prelude

import Control.Alt (class Alt, (<|>))
import Control.Alternative (class Alternative)
import Control.Lazy (class Lazy)
import Control.Plus (class Plus)
import Data.Array as Array
import Data.CodePoint.Unicode as Unicode
import Data.Either (Either(..))
import Data.Enum (fromEnum)
import Data.Foldable (elem, foldMap, foldr, intercalate)
import Data.Char (fromCharCode, toCharCode)
import Data.List (List(..), reverse, (:))
import Data.List as List
import Data.Maybe (Maybe(..))
import Data.String.CodePoints (CodePoint)
import Data.String.CodePoints as CodePoints
import Data.String.CodeUnits as CodeUnits
import Partial.Unsafe (unsafeCrashWith)

-------------------------------------------------------------------------------
-- Positions and errors (Text.Parsec.Pos, Text.Parsec.Error)
-------------------------------------------------------------------------------

newtype SourcePos = SourcePos { name :: String, line :: Int, column :: Int }

derive instance Eq SourcePos

instance Ord SourcePos where
  compare (SourcePos a) (SourcePos b) =
    compare a.name b.name <> compare a.line b.line <> compare a.column b.column

instance Show SourcePos where
  show (SourcePos p) =
    let
      lc = "(line " <> show p.line <> ", column " <> show p.column <> ")"
    in
      if p.name == "" then lc else showString p.name <> " " <> lc

sourceName :: SourcePos -> String
sourceName (SourcePos p) = p.name

sourceLine :: SourcePos -> Int
sourceLine (SourcePos p) = p.line

sourceColumn :: SourcePos -> Int
sourceColumn (SourcePos p) = p.column

-- | `updatePosChar`.
advance :: SourcePos -> CodePoint -> SourcePos
advance (SourcePos p) c = SourcePos case fromEnum c of
  10 -> p { line = p.line + 1, column = 1 }
  9 -> p { column = p.column + 8 - ((p.column - 1) `mod` 8) }
  _ -> p { column = p.column + 1 }

data Message
  = SysUnExpect String
  | UnExpect String
  | Expect String
  | Message String

-- | Parsec compares messages by kind alone.
kind :: Message -> Int
kind = case _ of
  SysUnExpect _ -> 0
  UnExpect _ -> 1
  Expect _ -> 2
  Message _ -> 3

messageString :: Message -> String
messageString = case _ of
  SysUnExpect s -> s
  UnExpect s -> s
  Expect s -> s
  Message s -> s

data ParseError = ParseError SourcePos (Array Message)

errorPos :: ParseError -> SourcePos
errorPos (ParseError pos _) = pos

unknownError :: SourcePos -> ParseError
unknownError pos = ParseError pos []

newErrorMessage :: Message -> SourcePos -> ParseError
newErrorMessage msg pos = ParseError pos [ msg ]

isUnknown :: ParseError -> Boolean
isUnknown (ParseError _ msgs) = Array.null msgs

-- | `mergeError`: an error with messages beats one without; otherwise the
-- | further one wins, and at the same position the messages are pooled.
mergeError :: ParseError -> ParseError -> ParseError
mergeError e1@(ParseError pos1 msgs1) e2@(ParseError pos2 msgs2)
  | Array.null msgs2 && not (Array.null msgs1) = e1
  | Array.null msgs1 && not (Array.null msgs2) = e2
  | otherwise = case compare pos1 pos2 of
      EQ -> ParseError pos1 (msgs1 <> msgs2)
      GT -> e1
      LT -> e2

-- | `setErrorMessage`: replaces every message of the same kind.
setErrorMessage :: Message -> ParseError -> ParseError
setErrorMessage msg (ParseError pos msgs) =
  ParseError pos (Array.cons msg (Array.filter (\m -> kind m /= kind msg) msgs))

-- | `setExpectErrors`, for one label.
setExpectError :: String -> ParseError -> ParseError
setExpectError msg = setErrorMessage (Expect msg)

-- | Parsec's `show`: the position, then `showErrorMessages` in English.
instance Show ParseError where
  show (ParseError pos msgs) = show pos <> ":" <> showErrorMessages msgs

showErrorMessages :: Array Message -> String
showErrorMessages msgs0
  | Array.null msgs0 = "unknown parse error"
  | otherwise =
      let
        msgs = Array.sortWith kind msgs0
        sysUnExpect = Array.filter (\m -> kind m == 0) msgs
        unExpect = Array.filter (\m -> kind m == 1) msgs
        expect = Array.filter (\m -> kind m == 2) msgs
        messages = Array.filter (\m -> kind m == 3) msgs
        showSysUnExpect = case Array.head sysUnExpect of
          Just first | Array.null unExpect ->
            if messageString first == "" then "unexpected end of input"
            else "unexpected " <> messageString first
          _ -> ""
      in
        foldMap ("\n" <> _) $ clean
          [ showSysUnExpect
          , showMany "unexpected" unExpect
          , showMany "expecting" expect
          , showMany "" messages
          ]
  where
  clean = Array.nub <<< Array.filter (_ /= "")
  showMany pre ms = case clean (map messageString ms) of
    [] -> ""
    strs | pre == "" -> commasOr strs
    strs -> pre <> " " <> commasOr strs
  commasOr strs = case Array.unsnoc strs of
    Nothing -> ""
    Just { init: [], last } -> last
    Just { init, last } -> intercalate ", " init <> " or " <> last

-- | Haskell's `show` for a `String`: quoted, with the escapes that matter.
showString :: String -> String
showString s = "\"" <> foldMap esc (CodePoints.toCodePointArray s) <> "\""
  where
  esc c = if fromEnum c == 34 then "\\\"" else escape c

-- | The escapes `show` uses inside a `String` or a `Char` literal.
escape :: CodePoint -> String
escape c = case fromEnum c of
  92 -> "\\\\"
  10 -> "\\n"
  9 -> "\\t"
  13 -> "\\r"
  n | n < 32 || n == 127 -> "\\" <> show n
  _ -> CodePoints.singleton c

-------------------------------------------------------------------------------
-- The parser (Text.Parsec.Prim)
-------------------------------------------------------------------------------

type State u = { input :: String, pos :: SourcePos, user :: u }

data Reply u a
  = Ok a (State u) ParseError
  | Error ParseError

-- | Whether input was consumed: Parsec's `Consumed` and `Empty`.
data Consumed a
  = Consumed a
  | Empty a

newtype Parsec u a = Parsec (State u -> Consumed (Reply u a))

run :: forall u a. Parsec u a -> State u -> Consumed (Reply u a)
run (Parsec p) = p

instance Functor (Parsec u) where
  map f p = Parsec \s -> case run p s of
    Consumed r -> Consumed (mapReply r)
    Empty r -> Empty (mapReply r)
    where
    mapReply = case _ of
      Ok a s' e -> Ok (f a) s' e
      Error e -> Error e

instance Apply (Parsec u) where
  apply = ap

instance Applicative (Parsec u) where
  pure a = Parsec \s -> Empty (Ok a s (unknownError s.pos))

-- | `parserBind`: when the second parser consumes nothing, its error is
-- | merged with the first's.
instance Bind (Parsec u) where
  bind p f = Parsec \s -> case run p s of
    Empty (Error e) -> Empty (Error e)
    Consumed (Error e) -> Consumed (Error e)
    Empty (Ok a s' e) -> case run (f a) s' of
      Empty (Ok b s'' e') -> Empty (Ok b s'' (mergeError e e'))
      Empty (Error e') -> Empty (Error (mergeError e e'))
      consumed -> consumed
    Consumed (Ok a s' e) -> Consumed case run (f a) s' of
      Empty (Ok b s'' e') -> Ok b s'' (mergeError e e')
      Empty (Error e') -> Error (mergeError e e')
      Consumed r -> r

instance Monad (Parsec u)

-- | `parserPlus`: the second parser is tried only when the first failed
-- | without consuming input.
instance Alt (Parsec u) where
  alt m n = Parsec \s -> case run m s of
    Empty (Error e) -> case run n s of
      Empty (Error e') -> Empty (Error (mergeError e e'))
      Empty (Ok b s' e') -> Empty (Ok b s' (mergeError e e'))
      consumed -> consumed
    other -> other

instance Plus (Parsec u) where
  empty = parserZero

instance Alternative (Parsec u)

instance Lazy (Parsec u a) where
  defer f = Parsec \s -> run (f unit) s

runParser :: forall u a. Parsec u a -> u -> String -> String -> Either ParseError a
runParser p user name input =
  case run p { input, pos: SourcePos { name, line: 1, column: 1 }, user } of
    Consumed r -> result r
    Empty r -> result r
  where
  result = case _ of
    Ok a _ _ -> Right a
    Error e -> Left e

-- | `parse`: `runParser` with a unit user state.
parse :: forall a. Parsec Unit a -> String -> String -> Either ParseError a
parse p = runParser p unit

getPosition :: forall u. Parsec u SourcePos
getPosition = Parsec \s -> Empty (Ok s.pos s (unknownError s.pos))

getInput :: forall u. Parsec u String
getInput = Parsec \s -> Empty (Ok s.input s (unknownError s.pos))

getState :: forall u. Parsec u u
getState = Parsec \s -> Empty (Ok s.user s (unknownError s.pos))

putState :: forall u. u -> Parsec u Unit
putState u = Parsec \s -> Empty (Ok unit (s { user = u }) (unknownError s.pos))

modifyState :: forall u. (u -> u) -> Parsec u Unit
modifyState f = Parsec \s -> Empty (Ok unit (s { user = f s.user }) (unknownError s.pos))

-------------------------------------------------------------------------------
-- Combinators (Text.Parsec.Prim, Text.Parsec.Combinator)
-------------------------------------------------------------------------------

-- | A consumed error becomes an empty one, so `<|>` may try the next.
try :: forall u a. Parsec u a -> Parsec u a
try p = Parsec \s -> case run p s of
  Consumed (Error e) -> Empty (Error e)
  other -> other

-- | On success, the result without the input it consumed. A consumed error
-- | stays consumed, as in parsec 3.1.
lookAhead :: forall u a. Parsec u a -> Parsec u a
lookAhead p = Parsec \s -> case run p s of
  Consumed (Ok a _ _) -> Empty (Ok a s (unknownError s.pos))
  Empty (Ok a _ _) -> Empty (Ok a s (unknownError s.pos))
  other -> other

notFollowedBy :: forall u a. Show a => Parsec u a -> Parsec u Unit
notFollowedBy p = try ((try p >>= \c -> unexpected (show c)) <|> pure unit)

-- | `<?>`: when the parser consumes nothing, its expectation is the label.
label :: forall u a. Parsec u a -> String -> Parsec u a
label p msg = Parsec \s -> case run p s of
  Empty (Error e) -> Empty (Error (setExpectError msg e))
  Empty (Ok a s' e) -> Empty (Ok a s' (if isUnknown e then e else setExpectError msg e))
  other -> other

infix 0 label as <?>

unexpected :: forall u a. String -> Parsec u a
unexpected msg = Parsec \s -> Empty (Error (newErrorMessage (UnExpect msg) s.pos))

-- | `parserFail` (Haskell's `fail` in `ParsecT`).
fail :: forall u a. String -> Parsec u a
fail msg = Parsec \s -> Empty (Error (newErrorMessage (Message msg) s.pos))

parserZero :: forall u a. Parsec u a
parserZero = Parsec \s -> Empty (Error (unknownError s.pos))

-- | Zero or more. A parser that succeeds without consuming is an error
-- | here, as in Parsec, since `many` of it would never end.
many :: forall u a. Parsec u a -> Parsec u (Array a)
many p = Parsec \s0 -> go Nil false s0
  where
  go acc consumed s = case run p s of
    Consumed (Ok a s' _) -> go (a : acc) true s'
    Consumed (Error e) -> Consumed (Error e)
    Empty (Ok _ _ _) ->
      unsafeCrashWith "Text.ParserCombinators.Parsec.Prim.many: combinator 'many' is applied to a parser that accepts an empty string."
    Empty (Error e) ->
      let
        r = Ok (List.toUnfoldable (reverse acc)) s e
      in
        if consumed then Consumed r else Empty r

many1 :: forall u a. Parsec u a -> Parsec u (Array a)
many1 p = do
  x <- p
  xs <- many p
  pure (Array.cons x xs)

skipMany :: forall u a. Parsec u a -> Parsec u Unit
skipMany p = void (many p)

skipMany1 :: forall u a. Parsec u a -> Parsec u Unit
skipMany1 p = p *> skipMany p

option :: forall u a. a -> Parsec u a -> Parsec u a
option x p = p <|> pure x

optionMaybe :: forall u a. Parsec u a -> Parsec u (Maybe a)
optionMaybe p = option Nothing (Just <$> p)

optional :: forall u a. Parsec u a -> Parsec u Unit
optional p = void p <|> pure unit

choice :: forall u a. Array (Parsec u a) -> Parsec u a
choice = foldr (<|>) parserZero

between :: forall u open close a. Parsec u open -> Parsec u close -> Parsec u a -> Parsec u a
between open close p = open *> p <* close

sepBy :: forall u a sep. Parsec u a -> Parsec u sep -> Parsec u (Array a)
sepBy p sep = sepBy1 p sep <|> pure []

sepBy1 :: forall u a sep. Parsec u a -> Parsec u sep -> Parsec u (Array a)
sepBy1 p sep = do
  x <- p
  xs <- many (sep *> p)
  pure (Array.cons x xs)

count :: forall u a. Int -> Parsec u a -> Parsec u (Array a)
count n p
  | n <= 0 = pure []
  | otherwise = Array.cons <$> p <*> count (n - 1) p

-- | `eof = notFollowedBy anyToken <?> "end of input"`.
eof :: forall u. Parsec u Unit
eof = notFollowedBy anyToken <?> "end of input"
  where
  -- Parsec's `anyToken` consumes the token but leaves the position where it
  -- was (`tokenPrim show (\pos _ _ -> pos) Just`), so `eof` reports a
  -- leftover token at its start, and pools its expectation with whatever
  -- failed there.
  anyToken = Parsec \s -> case CodePoints.uncons s.input of
    Nothing -> Empty (Error (newErrorMessage (SysUnExpect "") s.pos))
    Just { head, tail } ->
      Consumed (Ok (Token head) (s { input = tail }) (unknownError s.pos))

-- | `anyToken`'s result, shown as Haskell shows a `Char`: `'a'`.
newtype Token = Token CodePoint

instance Show Token where
  show (Token c) = case fromEnum c of
    39 -> "'\\''"
    _ -> "'" <> escape c <> "'"

-------------------------------------------------------------------------------
-- Characters (Text.Parsec.Char)
-------------------------------------------------------------------------------

asChar :: CodePoint -> Maybe Char
asChar = fromCharCode <<< fromEnum

-- | One code point that is a `Char` the predicate accepts.
satisfy :: forall u. (Char -> Boolean) -> Parsec u Char
satisfy f = Parsec \s -> case CodePoints.uncons s.input of
  Nothing -> Empty (Error (newErrorMessage (SysUnExpect "") s.pos))
  Just { head, tail } -> case asChar head of
    Just c | f c ->
      let
        pos' = advance s.pos head
      in
        Consumed (Ok c (s { input = tail, pos = pos' }) (unknownError pos'))
    _ -> Empty (Error (newErrorMessage (SysUnExpect (showString (CodePoints.singleton head))) s.pos))

-- | As `satisfy`, with a Unicode predicate on the code point.
satisfyCodePoint :: forall u. (CodePoint -> Boolean) -> Parsec u Char
satisfyCodePoint f = satisfy \c -> f (CodePoints.codePointFromChar c)

char :: forall u. Char -> Parsec u Char
char c = satisfy (_ == c) <?> showString (CodeUnits.singleton c)

-- | Parsec's `string` (`tokens`): consumes what matched before a mismatch.
-- | Errors are reported where the string began, as `tokens` reports them.
string :: forall u. String -> Parsec u String
string tts = Parsec \s0 ->
  let
    expected = showString tts
    failed i e = if i == 0 then Empty (Error e) else Consumed (Error e)
    unexpectedAt msg = setExpectError expected (newErrorMessage (SysUnExpect msg) s0.pos)
    walk cs i st = case Array.index cs i of
      Nothing ->
        if i == 0 then Empty (Ok tts st (unknownError st.pos))
        else Consumed (Ok tts st (unknownError st.pos))
      Just c -> case CodePoints.uncons st.input of
        Nothing -> failed i (unexpectedAt "")
        Just { head, tail }
          | head == c -> walk cs (i + 1) (st { input = tail, pos = advance st.pos head })
          | otherwise -> failed i (unexpectedAt (showString (CodePoints.singleton head)))
  in
    walk (CodePoints.toCodePointArray tts) 0 s0

oneOf :: forall u. Array Char -> Parsec u Char
oneOf cs = satisfy (_ `elem` cs)

noneOf :: forall u. Array Char -> Parsec u Char
noneOf cs = satisfy (not <<< (_ `elem` cs))

anyChar :: forall u. Parsec u Char
anyChar = satisfy (const true)

-- | `isDigit`: ASCII only, as in `Data.Char`.
digit :: forall u. Parsec u Char
digit = satisfy (\c -> let n = toCharCode c in n >= 48 && n <= 57) <?> "digit"

letter :: forall u. Parsec u Char
letter = satisfyCodePoint Unicode.isAlpha <?> "letter"

alphaNum :: forall u. Parsec u Char
alphaNum = satisfyCodePoint Unicode.isAlphaNum <?> "letter or digit"

space :: forall u. Parsec u Char
space = satisfyCodePoint Unicode.isSpace <?> "space"

spaces :: forall u. Parsec u Unit
spaces = skipMany space <?> "white space"

upper :: forall u. Parsec u Char
upper = satisfyCodePoint Unicode.isUpper <?> "uppercase letter"

lower :: forall u. Parsec u Char
lower = satisfyCodePoint Unicode.isLower <?> "lowercase letter"
