-- | Control patterns for synthesis parameters
-- |
-- | Controls are named parameters that can be combined into events.
-- | Based on TidalCycles' control system.
-- |
-- | Usage:
-- | ```purescript
-- | -- Combine sample name with gain
-- | sound (pure "bd") # gain (pure 0.8)
-- | ```
module Tidal.Controls
  ( -- * Types
    Value(..)
  , ValueMap
  , ControlPattern
    -- * Core controls
  , sound
  , s
  , note
  , n
  , gain
  , pan
  , speed
  , begin
  , end
  , loop
  , cut
  , delay
  , delaytime
  , delayfeedback
    -- * Control combinators
  , pS
  , pF
  , pI
  , pN
    -- * Pattern merging
  , merge
  , (#)
  , mergeRight
  , (|>)
  , mergeBoth
  , (|>|)
  , mergeAdd
  , (|+)
  , mergeSub
  , (|-)
  , mergeMul
  , (|*)
  , mergeDiv
  , (|/)
    -- * Value extraction
  , getS
  , getF
  , getI
  , getN
  ) where

import Prelude

import Data.Array (filter)
import Data.Foldable (foldl)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Rational (Rational)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern, State(..), pattern, query)

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

-- | A value that can be stored in a control map
data Value
  = VS String      -- ^ String value (sample names, etc.)
  | VF Number      -- ^ Floating point value
  | VI Int         -- ^ Integer value
  | VN Number      -- ^ Note value (stored as Number for semitones)
  | VR Rational    -- ^ Rational value

derive instance eqValue :: Eq Value

instance showValue :: Show Value where
  show (VS s) = "VS " <> show s
  show (VF f) = "VF " <> show f
  show (VI i) = "VI " <> show i
  show (VN n) = "VN " <> show n
  show (VR r) = "VR " <> show r

-- | A map of control names to values
type ValueMap = Map.Map String Value

-- | A pattern of control maps
type ControlPattern = Pattern ValueMap

-------------------------------------------------------------------------------
-- Control constructors
-------------------------------------------------------------------------------

-- | Create a string control pattern
pS :: String -> Pattern String -> ControlPattern
pS name pat = (\v -> Map.singleton name (VS v)) <$> pat

-- | Create a float control pattern
pF :: String -> Pattern Number -> ControlPattern
pF name pat = (\v -> Map.singleton name (VF v)) <$> pat

-- | Create an integer control pattern
pI :: String -> Pattern Int -> ControlPattern
pI name pat = (\v -> Map.singleton name (VI v)) <$> pat

-- | Create a note control pattern
pN :: String -> Pattern Number -> ControlPattern
pN name pat = (\v -> Map.singleton name (VN v)) <$> pat

-------------------------------------------------------------------------------
-- Core controls
-------------------------------------------------------------------------------

-- | Sample name control
sound :: Pattern String -> ControlPattern
sound = pS "sound"

-- | Alias for sound
s :: Pattern String -> ControlPattern
s = sound

-- | Note/pitch control
note :: Pattern Number -> ControlPattern
note = pN "note"

-- | Alias for note (sample number in sample folders)
n :: Pattern Number -> ControlPattern
n = pN "n"

-- | Volume/gain control (0-1, can exceed)
gain :: Pattern Number -> ControlPattern
gain = pF "gain"

-- | Stereo pan control (0=left, 0.5=center, 1=right)
pan :: Pattern Number -> ControlPattern
pan = pF "pan"

-- | Playback speed control (1=normal, 2=double speed, 0.5=half speed)
speed :: Pattern Number -> ControlPattern
speed = pF "speed"

-- | Sample start position (0-1)
begin :: Pattern Number -> ControlPattern
begin = pF "begin"

-- | Sample end position (0-1)
end :: Pattern Number -> ControlPattern
end = pF "end"

-- | Number of times to loop the sample
loop :: Pattern Number -> ControlPattern
loop = pF "loop"

-- | Cut group (stops other sounds in same group)
cut :: Pattern Int -> ControlPattern
cut = pI "cut"

-- | Delay wet/dry mix
delay :: Pattern Number -> ControlPattern
delay = pF "delay"

-- | Delay time
delaytime :: Pattern Number -> ControlPattern
delaytime = pF "delaytime"

-- | Delay feedback amount
delayfeedback :: Pattern Number -> ControlPattern
delayfeedback = pF "delayfeedback"

-------------------------------------------------------------------------------
-- Pattern merging operators
-------------------------------------------------------------------------------

-- | Combine two control patterns (structure from left, merge values)
-- |
-- | `sound (pure "bd") # gain (pure 0.8)` produces events with both controls
infixl 4 merge as #

merge :: ControlPattern -> ControlPattern -> ControlPattern
merge left right = pattern \st ->
  let
    leftEvents = query left st
    rightEvents = query right st
  in
    concatMapLeft leftEvents rightEvents
  where
    concatMapLeft :: Array (Event ValueMap) -> Array (Event ValueMap) -> Array (Event ValueMap)
    concatMapLeft lefts rights = do
      l <- lefts
      let
        matchingRights = findOverlapping l rights
        mergedValue = foldlValues (eventValue l) (map eventValue matchingRights)
      pure $ mapEventValue (const mergedValue) l

    findOverlapping :: Event ValueMap -> Array (Event ValueMap) -> Array (Event ValueMap)
    findOverlapping evt evts = filter (overlaps evt) evts

    overlaps :: Event ValueMap -> Event ValueMap -> Boolean
    overlaps a b = arcOverlaps (eventPart a) (eventPart b)

    arcOverlaps :: Arc -> Arc -> Boolean
    arcOverlaps (Arc a) (Arc b) = a.start < b.stop && b.start < a.stop

    foldlValues :: ValueMap -> Array ValueMap -> ValueMap
    foldlValues = foldl Map.union

    eventValue :: Event ValueMap -> ValueMap
    eventValue (Digital e) = e.value
    eventValue (Analog e) = e.value

    eventPart :: Event ValueMap -> Arc
    eventPart (Digital e) = e.part
    eventPart (Analog e) = e.part

    mapEventValue :: (ValueMap -> ValueMap) -> Event ValueMap -> Event ValueMap
    mapEventValue f (Digital e) = Digital e { value = f e.value }
    mapEventValue f (Analog e) = Analog e { value = f e.value }

-- | Structure from right
infixl 4 mergeRight as |>

mergeRight :: ControlPattern -> ControlPattern -> ControlPattern
mergeRight left right = pattern \st ->
  let
    leftEvents = query left st
    rightEvents = query right st
  in
    concatMapRight leftEvents rightEvents
  where
    concatMapRight :: Array (Event ValueMap) -> Array (Event ValueMap) -> Array (Event ValueMap)
    concatMapRight lefts rights = do
      r <- rights
      let
        matchingLefts = findOverlapping r lefts
        mergedValue = foldlValues (eventValue r) (map eventValue matchingLefts)
      pure $ mapEventValue (const mergedValue) r

    findOverlapping :: Event ValueMap -> Array (Event ValueMap) -> Array (Event ValueMap)
    findOverlapping evt evts = filter (overlaps evt) evts

    overlaps :: Event ValueMap -> Event ValueMap -> Boolean
    overlaps a b = arcOverlaps (eventPart a) (eventPart b)

    arcOverlaps :: Arc -> Arc -> Boolean
    arcOverlaps (Arc a) (Arc b) = a.start < b.stop && b.start < a.stop

    foldlValues :: ValueMap -> Array ValueMap -> ValueMap
    foldlValues = foldl Map.union

    eventValue :: Event ValueMap -> ValueMap
    eventValue (Digital e) = e.value
    eventValue (Analog e) = e.value

    eventPart :: Event ValueMap -> Arc
    eventPart (Digital e) = e.part
    eventPart (Analog e) = e.part

    mapEventValue :: (ValueMap -> ValueMap) -> Event ValueMap -> Event ValueMap
    mapEventValue f (Digital e) = Digital e { value = f e.value }
    mapEventValue f (Analog e) = Analog e { value = f e.value }

-- | Both structures
infixl 4 mergeBoth as |>|

mergeBoth :: ControlPattern -> ControlPattern -> ControlPattern
mergeBoth left right = pattern \st ->
  let
    leftEvents = query left st
    rightEvents = query right st
  in
    concatMapBoth leftEvents rightEvents
  where
    concatMapBoth :: Array (Event ValueMap) -> Array (Event ValueMap) -> Array (Event ValueMap)
    concatMapBoth lefts rights = do
      l <- lefts
      r <- rights
      case sectArc (eventPart l) (eventPart r) of
        Nothing -> []
        Just part ->
          let mergedValue = Map.union (eventValue l) (eventValue r)
          in [Digital { context: getContext l, whole: eventWhole l, part, value: mergedValue }]

    sectArc :: Arc -> Arc -> Maybe Arc
    sectArc (Arc a) (Arc b) =
      let s = max a.start b.start
          e = min a.stop b.stop
      in if s < e then Just (Arc { start: s, stop: e }) else Nothing

    eventValue :: Event ValueMap -> ValueMap
    eventValue (Digital e) = e.value
    eventValue (Analog e) = e.value

    eventPart :: Event ValueMap -> Arc
    eventPart (Digital e) = e.part
    eventPart (Analog e) = e.part

    eventWhole :: Event ValueMap -> Arc
    eventWhole (Digital e) = e.whole
    eventWhole (Analog e) = e.part

    getContext (Digital e) = e.context
    getContext (Analog e) = e.context

-- | Add numeric values
infixl 4 mergeAdd as |+

mergeAdd :: ControlPattern -> ControlPattern -> ControlPattern
mergeAdd = mergeWith addValues

-- | Subtract numeric values
infixl 4 mergeSub as |-

mergeSub :: ControlPattern -> ControlPattern -> ControlPattern
mergeSub = mergeWith subValues

-- | Multiply numeric values
infixl 4 mergeMul as |*

mergeMul :: ControlPattern -> ControlPattern -> ControlPattern
mergeMul = mergeWith mulValues

-- | Divide numeric values
infixl 4 mergeDiv as |/

mergeDiv :: ControlPattern -> ControlPattern -> ControlPattern
mergeDiv = mergeWith divValues

-- Helper: merge with a combining function for numeric values
mergeWith :: (Value -> Value -> Value) -> ControlPattern -> ControlPattern -> ControlPattern
mergeWith f left right = pattern \st ->
  let
    leftEvents = query left st
    rightEvents = query right st
  in
    concatMapWith leftEvents rightEvents
  where
    concatMapWith lefts rights = do
      l <- lefts
      let
        matchingRights = filter (overlaps l) rights
        mergedValue = foldl (combineMap f) (eventValue l) (map eventValue matchingRights)
      pure $ mapEventValue (const mergedValue) l

    overlaps a b = arcOverlaps (eventPart a) (eventPart b)
    arcOverlaps (Arc a) (Arc b) = a.start < b.stop && b.start < a.stop

    combineMap :: (Value -> Value -> Value) -> ValueMap -> ValueMap -> ValueMap
    combineMap fn m1 m2 = Map.unionWith fn m1 m2

    eventValue (Digital e) = e.value
    eventValue (Analog e) = e.value
    eventPart (Digital e) = e.part
    eventPart (Analog e) = e.part
    mapEventValue fn (Digital e) = Digital e { value = fn e.value }
    mapEventValue fn (Analog e) = Analog e { value = fn e.value }

-- Value arithmetic helpers
addValues :: Value -> Value -> Value
addValues (VF a) (VF b) = VF (a + b)
addValues (VI a) (VI b) = VI (a + b)
addValues (VN a) (VN b) = VN (a + b)
addValues a _ = a

subValues :: Value -> Value -> Value
subValues (VF a) (VF b) = VF (a - b)
subValues (VI a) (VI b) = VI (a - b)
subValues (VN a) (VN b) = VN (a - b)
subValues a _ = a

mulValues :: Value -> Value -> Value
mulValues (VF a) (VF b) = VF (a * b)
mulValues (VI a) (VI b) = VI (a * b)
mulValues (VN a) (VN b) = VN (a * b)
mulValues a _ = a

divValues :: Value -> Value -> Value
divValues (VF a) (VF b) = VF (a / b)
divValues (VI a) (VI b) = VI (a / b)
divValues (VN a) (VN b) = VN (a / b)
divValues a _ = a

-------------------------------------------------------------------------------
-- Value extraction
-------------------------------------------------------------------------------

-- | Get a string value from a control map
getS :: String -> ValueMap -> Maybe String
getS key m = case Map.lookup key m of
  Just (VS s) -> Just s
  _ -> Nothing

-- | Get a float value from a control map
getF :: String -> ValueMap -> Maybe Number
getF key m = case Map.lookup key m of
  Just (VF f) -> Just f
  _ -> Nothing

-- | Get an integer value from a control map
getI :: String -> ValueMap -> Maybe Int
getI key m = case Map.lookup key m of
  Just (VI i) -> Just i
  _ -> Nothing

-- | Get a note value from a control map
getN :: String -> ValueMap -> Maybe Number
getN key m = case Map.lookup key m of
  Just (VN n) -> Just n
  _ -> Nothing
