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

import Data.Array (catMaybes, find, index)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String (split)
import Data.String as String
import Data.Tuple (Tuple(..))
import Tidal.Pattern.Types (ControlPattern, Pattern, Value(..), ValueMap, applyLeft)

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
-- | control's kind. A number that does not read is dropped, as GHCi would
-- | refuse the literal; the line language checks literals before this.
control :: Control -> Pattern String -> ControlPattern
control k = map case k.kind of
  KString -> one VString <<< Just
  KSound -> grp
  KFloat -> one VNumber <<< Number.fromString
  KNote -> one VNote <<< Number.fromString
  KInt -> one VInt <<< Int.fromString
  where
  one :: forall a. (a -> Value) -> Maybe a -> ValueMap
  one box = Map.fromFoldable <<< map (Tuple k.key <<< box)

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
