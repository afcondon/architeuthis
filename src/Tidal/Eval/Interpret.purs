-- | **Mini-notation to patterns, as Haskell Tidal does it.**
-- |
-- | A port of `toPat`, `resolve_tpat`, `resolve_seq` and `resolve_size` from
-- | Tidal 1.10.1's `Sound.Tidal.ParseBP`, over the same AST. What it decides,
-- | and what the earlier interpreter got wrong (found by the GHCi oracle,
-- | `Test.OracleSpec`, 2026-10-01):
-- |
-- | - A sequence is a `timeCat` of its steps, each step weighted: `@r` and
-- |   `_` weight a step, `!n` repeats it n times. Both were ignored.
-- | - `<a b c>` and `{a b, c d e}` speed each sequence by the step rate over
-- |   its own step count, so `<a b c>` alternates rather than playing all
-- |   three in one cycle. The step rate defaults to the first sequence's.
-- | - Rates (`*`, `/`, `%`) and Euclidean arguments are patterns: a
-- |   constant is applied directly, anything else through `innerJoin`, as
-- |   Tidal's `patternify` does with and without a pure value.
-- | - `?` and `|` use Tidal's own randomness (`Tidal.Pattern.Random`),
-- |   offset by the parse-order seed, so they drop and choose what Tidal
-- |   drops and chooses.
-- | - `a .. b` enumerates as Tidal's `fromTo` does, per type.
module Tidal.Eval.Interpret
  ( tpatToPattern
  , evalTPat
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, (%))
import Data.Tuple (Tuple(..), snd)
import Tidal.AST.Types (Located(..), TPat(..))
import Tidal.Core.Types (Seed(..))
import Tidal.Pattern.Core (chooseBy, degradeByUsing, euclidOff, fast, fastCat, innerJoin, rand, rotL, segment, slow, stack, timeCat, unwrap)
import Tidal.Pattern.Types (class TidalEnum, Pattern, enumRange, silence)

-- | Evaluate mini-notation: Haskell Tidal's `toPat`.
tpatToPattern :: forall a. TidalEnum a => TPat a -> Pattern a
tpatToPattern = case _ of
  TPat_Atom (Located _ x) -> pure x
  TPat_Silence _ -> silence
  TPat_Var _ _ -> silence
  TPat_Seq _ xs -> snd (resolveSeq xs)
  TPat_Stack _ xs -> stack (map tpatToPattern xs)
  TPat_Fast _ t x -> timeParam fast t (tpatToPattern x)
  TPat_Slow _ t x -> timeParam slow t (tpatToPattern x)
  TPat_Polyrhythm _ mSteprate xs ->
    let
      pats = map resolveTPat xs
      base = case Array.head pats of
        Just (Tuple size _) -> size
        Nothing -> zero
      adjust (Tuple size pat) = case mSteprate of
        Nothing -> fast (base / size) pat
        Just steprate -> timeParam (\r -> fast (r / size)) steprate pat
    in
      stack (map adjust pats)
  TPat_DegradeBy _ (Seed seed) amount x ->
    degradeByUsing (rotL (seed % 10000) rand) amount (tpatToPattern x)
  TPat_CycleChoose _ (Seed seed) xs ->
    unwrap $ segment 1 $ chooseBy (rotL (seed % 10000) rand) (map tpatToPattern xs)
  TPat_Euclid _ n k s x -> euclidParam n k s (tpatToPattern x)
  TPat_EnumFromTo _ a b -> unwrap (fromTo <$> tpatToPattern a <*> tpatToPattern b)
  -- Only meaningful as steps of a sequence, where resolveSize reads them.
  TPat_Elongate _ _ _ -> silence
  TPat_Repeat _ _ _ -> silence

evalTPat :: forall a. TidalEnum a => TPat a -> Pattern a
evalTPat = tpatToPattern

-- | `resolve_tpat`: a pattern and its step count (a sequence counts its
-- | weighted steps, anything else is one step).
resolveTPat :: forall a. TidalEnum a => TPat a -> Tuple Rational (Pattern a)
resolveTPat = case _ of
  TPat_Seq _ xs -> resolveSeq xs
  other -> Tuple one (tpatToPattern other)

-- | `resolve_seq`: the steps, weighted, side by side in one cycle.
resolveSeq :: forall a. TidalEnum a => Array (TPat a) -> Tuple Rational (Pattern a)
resolveSeq xs =
  let
    sized = map (\(Tuple r t) -> Tuple r (tpatToPattern t)) (Array.concatMap resolveSize xs)
    total = foldl (\acc (Tuple r _) -> acc + r) zero sized
  in
    Tuple total (timeCat sized)

-- | `resolve_size`: `@r` weights a step, `!n` makes n of it.
resolveSize :: forall a. TPat a -> Array (Tuple Rational (TPat a))
resolveSize = case _ of
  TPat_Elongate _ r p -> [ Tuple r p ]
  TPat_Repeat _ n p -> Array.replicate n (Tuple one p)
  p -> [ Tuple one p ]

-- | The value of a mini-notation pattern that is one value, as Haskell's
-- | `pureValue` would be `Just`: an atom, or a sequence of one step.
constantOf :: forall a. TPat a -> Maybe a
constantOf = case _ of
  TPat_Atom (Located _ x) -> Just x
  TPat_Seq _ [ x ] -> constantOf x
  TPat_Elongate _ _ x -> constantOf x
  _ -> Nothing

-- | A time argument: applied directly when constant, through `innerJoin`
-- | otherwise (Haskell's `patternify`).
timeParam
  :: forall a
   . (Rational -> Pattern a -> Pattern a)
  -> TPat Rational
  -> Pattern a
  -> Pattern a
timeParam f t p = case constantOf t of
  Just r -> f r p
  Nothing -> innerJoin (map (\r -> f r p) (tpatToPattern t))

-- | Euclid's three arguments, as Haskell's `patternify3`: directly when all
-- | are constant, otherwise joined from their combined pattern.
euclidParam :: forall a. TPat Int -> TPat Int -> TPat Int -> Pattern a -> Pattern a
euclidParam n k s p = case constantOf n, constantOf k, constantOf s of
  Just n', Just k', Just s' -> euclidOff n' k' s' p
  _, _, _ ->
    innerJoin
      ( (\x y z -> euclidOff x y z p)
          <$> tpatToPattern n
          <*> tpatToPattern k
          <*> tpatToPattern s
      )

-- | Tidal's `fromTo`: `fastFromList` of the enumeration.
fromTo :: forall a. TidalEnum a => a -> a -> Pattern a
fromTo a b = fastCat (map pure (enumRange a b))
