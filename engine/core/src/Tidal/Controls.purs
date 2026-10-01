-- | Control patterns, as Haskell Tidal has them.
-- |
-- | A control pattern is a pattern of named values (`ControlPattern`, from
-- | `Tidal.Pattern.Types`); `s "bd" # n "2"` is two of them combined. The
-- | names, their types and their keys follow Tidal 1.10's `Sound.Tidal.Params`,
-- | checked against GHCi: `lpf` writes `cutoff`, `orbit` is an integer, `n` is
-- | a note, and `s "bd:3"` splits into `s` and `n`.
-- |
-- | The operators are Tidal's: `#` is `|>` (structure from the left, values
-- | from the right), `|<` keeps the left's values. They have Tidal's fixity,
-- | the Haskell default `infixl 9`, so `s "bd" # n "1"` needs no brackets.
-- |
-- | This replaced an earlier model with its own `Value` type whose `#` kept
-- | the left's values and did not divide events (2026-10-01).
module Tidal.Controls
  ( Kind(..)
  , Control
  , controls
  , lookupControl
  , control
  , readValue
  , controlFromMini
  , pS
  , pF
  , pI
  , pN
  , sound
  , s
  , n
  , note
  , gain
  , union
  , flipUnion
  , keepRight
  , keepLeft
  , (#)
  , (|>)
  , (|<)
  ) where

import Prelude

import Control.Alt ((<|>))

import Data.Array (catMaybes, find, index)
import Data.Foldable (foldl)
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String (split)
import Data.String.CodeUnits as CU
import Data.String as String
import Data.Tuple (Tuple(..))
import Tidal.Parse.Class (class AtomParseable)
import Tidal.Parse.Haskell (TDouble(..), TInt(..), TNote(..), Vocable(..))
import Tidal.Parse.Parser (parseTPat)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Pattern.Types (class TidalEnum, ControlPattern, Pattern, Value(..), ValueMap, applyLeft)

-- | What a control's pattern holds. `Sound` is Tidal's `grp [mS "s", mF "n"]`:
-- | a string whose `:`-suffix, when it is a number, becomes `n`.
data Kind = KString | KFloat | KInt | KNote | KSound

derive instance Eq Kind

-- | A control as the line language sees it: the name typed, the key written.
type Control = { name :: String, key :: String, kind :: Kind }

-- | The controls known, by name. Aliases write their target's key.
controls :: Array Control
controls =
  [ c "s" "s" KSound
  , c "sound" "s" KSound
  , c "n" "n" KNote
  , c "note" "note" KNote
  , c "vowel" "vowel" KString
  , c "unit" "unit" KString
  , c "orbit" "orbit" KInt
  , c "cut" "cut" KInt
  , c "channel" "channel" KInt
  , c "lpf" "cutoff" KFloat
  , c "lpq" "resonance" KFloat
  , c "hpf" "hcutoff" KFloat
  , c "hpq" "hresonance" KFloat
  ]
    <> map (\k -> c k k KFloat)
      [ "gain", "amp", "velocity", "pan", "speed", "shape", "cutoff"
      , "resonance", "hcutoff", "hresonance", "bandf", "bandq", "room", "size"
      , "dry", "legato", "sustain", "begin", "end", "accelerate", "delay"
      , "delaytime", "delayfeedback", "crush", "coarse", "squiz"
      ]
  where
  c name key kind = { name, key, kind }

lookupControl :: String -> Maybe Control
lookupControl name = find (\k -> k.name == name) controls

-- | A pattern of strings as the control: each string is read at the
-- | control's kind (`readValue`). A string that does not read is dropped;
-- | the line language refuses such a literal before it gets here.
control :: Control -> Pattern String -> ControlPattern
control k = map case k.kind of
  KSound -> grp
  kind -> \v -> Map.fromFoldable (Tuple k.key <$> readValue kind v)

-- | One mini-notation atom read at a kind, as Tidal's `Parseable` instances
-- | read it. Notes are numbers or note names (`e` 4, `cs6` 13, `ef4` -9);
-- | ints take note names too; floats also take Tidal's duration letters
-- | (`e` is an eighth, 0.125), which win over note names.
readValue :: Kind -> String -> Maybe Value
readValue kind v = case kind of
  KString -> Just (VString v)
  KSound -> Just (VString v)
  KNote -> VNote <$> readNote v
  KInt -> VInt <$> readInt v
  KFloat -> VNumber <$> readFloat v

readNote :: String -> Maybe Number
readNote v = Number.fromString v <|> noteName v

readInt :: String -> Maybe Int
readInt v = Int.fromString v <|> (Int.round <$> noteName v)

readFloat :: String -> Maybe Number
readFloat v = Number.fromString v <|> durationLetter v <|> noteName v

-- | Mini-notation as a control, parsed at the control's type as Tidal
-- | parses it (`Tidal.Parse.Haskell`): `n "0..8"` and `gain "3h"` read as
-- | numbers, `s "bd:3"` as a string. A string that does not parse at that
-- | type is refused with the parser's message.
controlFromMini :: Control -> String -> Either String ControlPattern
controlFromMini k src = case k.kind of
  KString -> pS k.key <<< map (\(Vocable v) -> v) <$> typed
  KSound -> map (grp <<< \(Vocable v) -> v) <$> typed
  KFloat -> pF k.key <<< map (\(TDouble v) -> v) <$> typed
  KNote -> pN k.key <<< map (\(TNote v) -> v) <$> typed
  KInt -> pI k.key <<< map (\(TInt v) -> v) <$> typed
  where
  typed :: forall a. AtomParseable a => TidalEnum a => Either String (Pattern a)
  typed = case parseTPat src of
    Right tpat -> Right (tpatToPattern tpat)
    Left err -> Left ("mini-notation " <> show src <> ": " <> show err)

-- | Tidal's note names: a letter, any of `s` (sharp), `f` (flat), `n`
-- | (natural), then an octave, 5 if none. C5 is 0.
noteName :: String -> Maybe Number
noteName v = do
  { head, tail } <- CU.uncons v
  base <- case head of
    'c' -> Just 0
    'd' -> Just 2
    'e' -> Just 4
    'f' -> Just 5
    'g' -> Just 7
    'a' -> Just 9
    'b' -> Just 11
    _ -> Nothing
  let
    mods = CU.takeWhile (\ch -> ch == 's' || ch == 'f' || ch == 'n') tail
    octaveText = CU.drop (CU.length mods) tail
    shift = foldl (\acc ch -> acc + modifier ch) 0 (CU.toCharArray mods)
  octave <- if octaveText == "" then Just 5 else Int.fromString octaveText
  pure (Int.toNumber (base + shift + (octave - 5) * 12))
  where
  modifier = case _ of
    's' -> 1
    'f' -> -1
    _ -> 0

-- | Tidal's single-letter durations, read where a number is wanted.
durationLetter :: String -> Maybe Number
durationLetter = case _ of
  "w" -> Just 1.0
  "h" -> Just 0.5
  "q" -> Just 0.25
  "e" -> Just 0.125
  "s" -> Just 0.0625
  "t" -> Just (1.0 / 3.0)
  "f" -> Just 0.2
  "x" -> Just (1.0 / 6.0)
  _ -> Nothing

-- | `grp [mS "s", mF "n"]`: `bd:3` is `s` "bd" and `n` 3; a suffix that is
-- | not a number is dropped, as are any after the second.
grp :: String -> ValueMap
grp v = Map.fromFoldable (catMaybes [ sample, number ])
  where
  parts = split (String.Pattern ":") v
  sample = index parts 0 <#> \str -> Tuple "s" (VString str)
  number = index parts 1 >>= Number.fromString <#> \x -> Tuple "n" (VNumber x)

pS :: String -> Pattern String -> ControlPattern
pS key = map (Map.singleton key <<< VString)

pF :: String -> Pattern Number -> ControlPattern
pF key = map (Map.singleton key <<< VNumber)

pI :: String -> Pattern Int -> ControlPattern
pI key = map (Map.singleton key <<< VInt)

pN :: String -> Pattern Number -> ControlPattern
pN key = map (Map.singleton key <<< VNote)

sound :: Pattern String -> ControlPattern
sound = control { name: "sound", key: "s", kind: KSound }

s :: Pattern String -> ControlPattern
s = sound

n :: Pattern Number -> ControlPattern
n = pN "n"

note :: Pattern Number -> ControlPattern
note = pN "note"

gain :: Pattern Number -> ControlPattern
gain = pF "gain"

-- | Tidal's `union` on value maps: the left's values win.
union :: ValueMap -> ValueMap -> ValueMap
union = Map.union

flipUnion :: ValueMap -> ValueMap -> ValueMap
flipUnion = flip Map.union

-- | `a |> b`: structure from `a`, values from `b` where both have a key.
keepRight :: ControlPattern -> ControlPattern -> ControlPattern
keepRight a b = applyLeft (flipUnion <$> a) b

-- | `a |< b`: structure from `a`, values from `a` where both have a key.
keepLeft :: ControlPattern -> ControlPattern -> ControlPattern
keepLeft a b = applyLeft (union <$> a) b

infixl 9 keepRight as #
infixl 9 keepRight as |>
infixl 9 keepLeft as |<
