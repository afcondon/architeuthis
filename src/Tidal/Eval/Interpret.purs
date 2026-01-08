-- | Interpreter for TPat AST to Pattern evaluation
-- |
-- | This module bridges the parsed mini-notation AST (`TPat`) with the
-- | pattern evaluation engine (`Pattern`). It converts the static AST
-- | into executable patterns.
-- |
-- | Design notes:
-- | - Each TPat constructor maps to a pattern combinator
-- | - Source locations from TPat are preserved in event contexts
-- | - Polymorphic over the atom type (String, Number, etc.)
module Tidal.Eval.Interpret
  ( -- * Main evaluation function
    tpatToPattern
  , evalTPat
    -- * Utilities
  , atom
  , atomWith
    -- * Euclidean rhythm
  , euclidean
  , bjorklund
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt, toNumber)
import Tidal.AST.Types (Located(..), TPat(..), SourceSpan)
import Tidal.Core.Types (Time, Seed(..))
import Tidal.Pattern.Core (fast, fastCat, slow, stack)
import Tidal.Pattern.Types
  ( Arc(..)
  , Context(..)
  , Event(..)
  , Pattern
  , State(..)
  , arcStart
  , pattern
  , query
  , silence
  , class TidalEnum
  , enumRange
  )

-------------------------------------------------------------------------------
-- Main evaluation functions
-------------------------------------------------------------------------------

-- | Convert a TPat AST to an executable Pattern
-- |
-- | This is the main entry point for pattern evaluation.
-- | The resulting Pattern can be queried for events in any time arc.
-- |
-- | Requires TidalEnum for range operator (..) support.
tpatToPattern :: forall a. TidalEnum a => TPat a -> Pattern a
tpatToPattern = go
  where
    go :: TPat a -> Pattern a
    go = case _ of
      TPat_Atom loc -> evalAtom loc
      TPat_Silence _ -> silence
      TPat_Var _ _ -> silence  -- TODO: implement variable lookup
      TPat_Seq _ pats -> evalSeq pats
      TPat_Stack _ pats -> evalStack pats
      TPat_Polyrhythm _ mRate pats -> evalPolyrhythm mRate pats
      TPat_Fast _ ratePat innerPat -> evalFast ratePat innerPat
      TPat_Slow _ ratePat innerPat -> evalSlow ratePat innerPat
      TPat_Elongate _ _ innerPat -> go innerPat
      TPat_Repeat _ n innerPat -> evalRepeat n innerPat
      TPat_DegradeBy _ seed prob innerPat -> evalDegradeBy seed prob innerPat
      TPat_CycleChoose _ seed pats -> evalCycleChoose seed pats
      TPat_Euclid _ nPat kPat sPat innerPat -> evalEuclid nPat kPat sPat innerPat
      TPat_EnumFromTo span fromPat toPat -> evalEnumFromTo span fromPat toPat

    -- Atom evaluation
    evalAtom :: Located a -> Pattern a
    evalAtom (Located span value) = atomWith span value

    -- Sequence evaluation
    evalSeq :: Array (TPat a) -> Pattern a
    evalSeq pats = case Array.length pats of
      0 -> silence
      1 -> case Array.head pats of
        Just p -> go p
        Nothing -> silence
      _ -> fastCat (map go pats)

    -- Stack evaluation
    evalStack :: Array (TPat a) -> Pattern a
    evalStack pats = stack (map go pats)

    -- Polyrhythm evaluation
    evalPolyrhythm :: Maybe (TPat Rational) -> Array (TPat a) -> Pattern a
    evalPolyrhythm mRatePat pats = case mRatePat of
      Nothing -> stack (map go pats)
      Just ratePat ->
        let r = getConstantRate ratePat
        in stack (map (\p -> slow r (go p)) pats)

    -- Fast evaluation
    evalFast :: TPat Rational -> TPat a -> Pattern a
    evalFast ratePat innerPat =
      fast (getConstantRate ratePat) (go innerPat)

    -- Slow evaluation
    evalSlow :: TPat Rational -> TPat a -> Pattern a
    evalSlow ratePat innerPat =
      slow (getConstantRate ratePat) (go innerPat)

    -- Repeat evaluation
    evalRepeat :: Int -> TPat a -> Pattern a
    evalRepeat n innerPat =
      fastCat (Array.replicate n (go innerPat))

    -- Degradation evaluation
    evalDegradeBy :: Seed -> Number -> TPat a -> Pattern a
    evalDegradeBy (Seed seed) prob innerPat =
      pattern \st ->
        let events = query (go innerPat) st
        in Array.mapWithIndex (maybeKeep seed prob) events # Array.catMaybes

    maybeKeep :: Int -> Number -> Int -> Event a -> Maybe (Event a)
    maybeKeep s p idx event =
      let rand = pseudoRandom (s + idx)
      in if rand < p then Nothing else Just event

    -- Cycle choose evaluation
    evalCycleChoose :: Seed -> Array (TPat a) -> Pattern a
    evalCycleChoose (Seed seed) pats = case Array.length pats of
      0 -> silence
      n -> pattern \(State st) ->
        let
          cycleNum = Int.floor (toNumber (arcStart st.arc))
          choice = (seed + cycleNum) `mod` n
        in case Array.index pats choice of
          Nothing -> []
          Just p -> query (go p) (State st)

    -- Euclidean evaluation
    evalEuclid :: TPat Int -> TPat Int -> TPat Int -> TPat a -> Pattern a
    evalEuclid nPat kPat sPat innerPat =
      let
        n = getConstantInt nPat
        k = getConstantInt kPat
        s = getConstantInt sPat
        pattern' = euclidean n k
        rotated = rotate s pattern'
        toPat b = if b then go innerPat else silence
      in fastCat (map toPat rotated)

    -- Enumeration evaluation: from .. to
    evalEnumFromTo :: SourceSpan -> TPat a -> TPat a -> Pattern a
    evalEnumFromTo span fromPat toPat =
      case getConstantValue fromPat, getConstantValue toPat of
        Just from, Just to ->
          let values = enumRange from to
              atoms = map (atomWith span) values
          in fastCat atoms
        _, _ -> go fromPat  -- Fallback if not constant

    -- Extract constant value from atom pattern
    getConstantValue :: TPat a -> Maybe a
    getConstantValue = case _ of
      TPat_Atom (Located _ v) -> Just v
      TPat_Seq _ pats -> case Array.head pats of
        Just p -> getConstantValue p
        Nothing -> Nothing
      _ -> Nothing

-- | Evaluate a TPat to a Pattern (alias for tpatToPattern)
evalTPat :: forall a. TidalEnum a => TPat a -> Pattern a
evalTPat = tpatToPattern

-------------------------------------------------------------------------------
-- Atom utilities
-------------------------------------------------------------------------------

-- | Create a pattern from a single value (filling each cycle)
atom :: forall a. a -> Pattern a
atom = pure

-- | Create a pattern from a value with source location context
atomWith :: forall a. SourceSpan -> a -> Pattern a
atomWith span value = pattern \(State { arc: queryArc }) ->
  Array.concatMap (mkEvent value queryArc) (cycleArcsInArc queryArc)
  where
    mkEvent :: a -> Arc -> Arc -> Array (Event a)
    mkEvent val qArc cycleArc =
      case sectArc qArc cycleArc of
        Nothing -> []
        Just part ->
          [ Digital
              { context: Context [span]
              , whole: cycleArc
              , part
              , value: val
              }
          ]

-------------------------------------------------------------------------------
-- Helper functions
-------------------------------------------------------------------------------

-- | Get a constant rate from a TPat Rational
getConstantRate :: TPat Rational -> Rational
getConstantRate = case _ of
  TPat_Atom (Located _ r) -> r
  _ -> one

-- | Get constant int from a TPat Int
getConstantInt :: TPat Int -> Int
getConstantInt = case _ of
  TPat_Atom (Located _ n) -> n
  _ -> 0

-- | Simple pseudo-random number generator (0 to 1)
-- | Uses a simple hash function for deterministic randomness
pseudoRandom :: Int -> Number
pseudoRandom seed =
  -- Simple xorshift-style hash, JS-safe
  let s1 = ((seed + 1) * 17) `mod` 65536
      s2 = (s1 * 31 + 12345) `mod` 65536
      s3 = (s2 * 101 + 54321) `mod` 65536
  in Int.toNumber s3 / 65536.0

-------------------------------------------------------------------------------
-- Euclidean rhythm
-------------------------------------------------------------------------------

-- | Generate Euclidean rhythm pattern
-- |
-- | Uses Bjorklund's algorithm to distribute n events over k steps.
euclidean :: Int -> Int -> Array Boolean
euclidean n k
  | k <= 0 = []
  | n <= 0 = Array.replicate k false
  | n >= k = Array.replicate k true
  | otherwise = bjorklund n k

-- | Bjorklund's algorithm for Euclidean distribution
-- |
-- | Special case: when k-n == 1 (only one zero), we need to place it
-- | in the middle to get proper distribution. The standard algorithm
-- | would just append it at the end.
bjorklund :: Int -> Int -> Array Boolean
bjorklund n k =
  let
    zeros = k - n
  in
    if zeros == 1 then
      -- Special case: one zero goes in the middle
      -- E.g., E(1,2) = [1,0], E(2,3) = [1,0,1], E(3,4) = [1,0,1,1]
      -- Use ceiling division to ensure at least 1 pulse before the zero
      let mid = (n + 1) / 2  -- ceiling of n/2
      in Array.replicate mid true
           <> [false]
           <> Array.replicate (n - mid) true
    else
      let
        ones = Array.replicate n [true]
        zerosArr = Array.replicate zeros [false]
      in
        Array.concat (bjorklundStep ones zerosArr)

-- | Recursive step of Bjorklund's algorithm
-- |
-- | The algorithm distributes elements from ys into xs by appending.
-- | Terminates when ys has <= 1 element (can't evenly distribute further).
bjorklundStep :: Array (Array Boolean) -> Array (Array Boolean) -> Array (Array Boolean)
bjorklundStep xs ys =
  let lenYs = Array.length ys
  in if lenYs <= 1 then xs <> ys
     else
       let
         minLen = min (Array.length xs) lenYs
         combined = Array.zipWith (<>) (Array.take minLen xs) (Array.take minLen ys)
         remainingXs = Array.drop minLen xs
         remainingYs = Array.drop minLen ys
       in
         bjorklundStep combined (remainingXs <> remainingYs)

-- | Rotate an array by n positions
rotate :: forall a. Int -> Array a -> Array a
rotate n arr =
  let len = Array.length arr
  in if len == 0 then arr
     else
       let n' = n `mod` len
       in Array.drop n' arr <> Array.take n' arr

-------------------------------------------------------------------------------
-- Arc utilities
-------------------------------------------------------------------------------

-- | Intersect two arcs
sectArc :: Arc -> Arc -> Maybe Arc
sectArc (Arc a) (Arc b) =
  let s = max a.start b.start
      e = min a.stop b.stop
  in if s < e then Just (Arc { start: s, stop: e }) else Nothing

-- | Get cycle arcs within a query arc
cycleArcsInArc :: Arc -> Array Arc
cycleArcsInArc (Arc { start, stop }) =
  let startCycle = sam start
      go acc s =
        if s >= stop then acc
        else go (acc <> [Arc { start: max start s, stop: min stop (s + one) }]) (s + one)
  in go [] startCycle

-- | Start of cycle containing time
sam :: Time -> Time
sam t =
  let n = floorTime t
  in if n <= t then n else n - one

-- | Floor time to integer
floorTime :: Time -> Time
floorTime t = fromInt (Int.floor (toNumber t))
