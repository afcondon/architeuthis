-- | Core types for Tidal pattern evaluation
-- |
-- | This module defines the fundamental types for pattern-based music:
-- | - `Arc` for time intervals
-- | - `Event` for discrete and continuous musical events
-- | - `Pattern` for time-varying musical structures
-- |
-- | Design improvements over Haskell Tidal:
-- | - Explicit Digital/Analog event distinction at type level
-- | - No optimization fields leaking into Pattern type
-- | - Clean Value type without embedded computations
module Tidal.Pattern.Types
  ( -- * Time intervals
    Arc(..)
  , arcStart
  , arcStop
  , arcDuration
  , mkArc
    -- * Query state
  , State(..)
  , ControlMap
    -- * Events (the core output of pattern queries)
  , Event(..)
  , eventValue
  , eventPart
  , eventWhole
  , isDigital
  , isAnalog
  , mapEventValue
    -- * Context for source tracking
  , Context(..)
  , emptyContext
    -- * Patterns (the core abstraction)
  , Pattern(..)
  , query
  , pattern
  , silence
  , applyLeft
  , applyRight
  , subArc
  , wholeOrPart
  , sect
  , cycleArcsInArc
  , floorDiv
  , floorMod
  , floorR
    -- * Values for control patterns
  , Value(..)
  , Note(..)
  , mkNote
  , class TidalEnum
  , enumRange
  , addSemitones
  , ValueMap
  , ControlPattern
    -- * Utilities
  , mkState
    -- * Re-exports
  , module Tidal.Core.Types
  ) where

import Prelude

import Data.Array (concatMap, cons, filter, mapMaybe, range, reverse) as Array
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype)
import Haskell.Rational (Rational, fromInt)
import Haskell.Integer as Integer
import Haskell.Rational (floor, fromInt) as Rational
import Tidal.Core.Types (Time, SourceSpan, emptySpan, Seed, ControlName)

-------------------------------------------------------------------------------
-- Arc: Time intervals
-------------------------------------------------------------------------------

-- | A time interval with start and stop times
-- |
-- | Arcs are half-open: [start, stop) - includes start, excludes stop.
-- | This ensures adjacent arcs don't overlap.
newtype Arc = Arc { start :: Time, stop :: Time }

derive instance eqArc :: Eq Arc
derive instance ordArc :: Ord Arc
derive instance newtypeArc :: Newtype Arc _

instance showArc :: Show Arc where
  show (Arc { start, stop }) = "Arc(" <> show start <> ", " <> show stop <> ")"

-- | Extract start time
arcStart :: Arc -> Time
arcStart (Arc { start }) = start

-- | Extract stop time
arcStop :: Arc -> Time
arcStop (Arc { stop }) = stop

-- | Duration of an arc
arcDuration :: Arc -> Time
arcDuration (Arc { start, stop }) = stop - start

-- | Smart constructor ensuring start <= stop
mkArc :: Time -> Time -> Arc
mkArc s e = Arc { start: min s e, stop: max s e }

-------------------------------------------------------------------------------
-- Context: Source location tracking
-------------------------------------------------------------------------------

-- | Context tracks where an event originated in source code
-- |
-- | This is useful for error messages and visual feedback in editors.
newtype Context = Context (Array SourceSpan)

derive instance eqContext :: Eq Context
derive instance newtypeContext :: Newtype Context _

instance showContext :: Show Context where
  show (Context spans) = "Context " <> show spans

instance semigroupContext :: Semigroup Context where
  append (Context a) (Context b) = Context (a <> b)

instance monoidContext :: Monoid Context where
  mempty = Context []

-- | Empty context for generated events
emptyContext :: Context
emptyContext = Context []

-------------------------------------------------------------------------------
-- Event: Musical events with timing
-------------------------------------------------------------------------------

-- | Musical events with explicit digital/analog distinction
-- |
-- | - **Digital** events have a defined "whole" - they represent discrete
-- |   occurrences like note onsets with clear start/stop boundaries
-- | - **Analog** events are continuous - they represent parameter sweeps
-- |   or values without defined boundaries
-- |
-- | This distinction is critical for how patterns combine:
-- | - Digital events combine only with compatible digital events
-- | - Analog events broadcast to all overlapping events
data Event a
  = Digital
      { context :: Context
      , whole :: Arc      -- The complete event span
      , part :: Arc       -- The portion within the query arc
      , value :: a
      }
  | Analog
      { context :: Context
      , part :: Arc       -- The portion within the query arc
      , value :: a
      }

derive instance functorEvent :: Functor Event

instance showEvent :: Show a => Show (Event a) where
  show (Digital e) =
    "Digital { whole: " <> show e.whole <>
    ", part: " <> show e.part <>
    ", value: " <> show e.value <> " }"
  show (Analog e) =
    "Analog { part: " <> show e.part <>
    ", value: " <> show e.value <> " }"

instance eqEvent :: Eq a => Eq (Event a) where
  eq (Digital a) (Digital b) =
    a.whole == b.whole && a.part == b.part && a.value == b.value
  eq (Analog a) (Analog b) =
    a.part == b.part && a.value == b.value
  eq _ _ = false

-- | Extract the value from an event
eventValue :: forall a. Event a -> a
eventValue (Digital e) = e.value
eventValue (Analog e) = e.value

-- | Extract the part (active timespan) from an event
eventPart :: forall a. Event a -> Arc
eventPart (Digital e) = e.part
eventPart (Analog e) = e.part

-- | Extract the whole from an event (Nothing for analog)
eventWhole :: forall a. Event a -> Maybe Arc
eventWhole (Digital e) = Just e.whole
eventWhole (Analog _) = Nothing

-- | Check if an event is digital (has defined boundaries)
isDigital :: forall a. Event a -> Boolean
isDigital (Digital _) = true
isDigital (Analog _) = false

-- | Check if an event is analog (continuous)
isAnalog :: forall a. Event a -> Boolean
isAnalog = not <<< isDigital

-- | Map over an event's value
mapEventValue :: forall a b. (a -> b) -> Event a -> Event b
mapEventValue f (Digital e) = Digital e { value = f e.value }
mapEventValue f (Analog e) = Analog e { value = f e.value }

-------------------------------------------------------------------------------
-- Value: Musical values for control patterns
-------------------------------------------------------------------------------

-- | A musical note (MIDI note number + optional microtonal offset)
newtype Note = Note { note :: Int, bend :: Number }

derive instance eqNote :: Eq Note
derive instance ordNote :: Ord Note
derive instance newtypeNote :: Newtype Note _

instance showNote :: Show Note where
  show (Note { note, bend })
    | bend == 0.0 = "Note " <> show note
    | otherwise = "Note " <> show note <> " (+" <> show bend <> ")"

-- | Create a note from MIDI number
mkNote :: Int -> Note
mkNote n = Note { note: n, bend: 0.0 }

-------------------------------------------------------------------------------
-- TidalEnum: Enumeration for range operator (..)
-------------------------------------------------------------------------------

-- | Type class for types that can be enumerated in ranges
-- |
-- | Used by the `..` operator, e.g., `0 .. 7` or `c4 .. c5`
-- |
-- | Haskell Tidal's `Enumerable`, plus what its chords ask of a type
-- | (`Num`): `addSemitones` moves a value up by an interval. Types that
-- | chords never apply to (strings) leave the value alone.
class TidalEnum a where
  enumRange :: a -> a -> Array a
  addSemitones :: Int -> a -> a

-- | Int enumeration: 0 .. 5 = [0, 1, 2, 3, 4, 5]
instance tidalEnumInt :: TidalEnum Int where
  enumRange from to
    | from <= to = Array.range from to
    | otherwise = Array.reverse (Array.range to from)
  addSemitones k x = x + k

-- | Note enumeration: chromatic scale between notes
instance tidalEnumNote :: TidalEnum Note where
  enumRange (Note { note: from }) (Note { note: to })
    | from <= to = map mkNote (Array.range from to)
    | otherwise = map mkNote (Array.reverse (Array.range to from))
  addSemitones k (Note n) = Note n { note = n.note + k }

-- | Number enumeration: step by 1.0
-- | Haskell's `[a .. b]` for Doubles (`numericEnumFromTo`): steps of one
-- | from a while at most b + 1/2; descending, the reverse of b's.
instance tidalEnumNumber :: TidalEnum Number where
  enumRange from to
    | from <= to = upTo from
        where
        upTo x = if x > to + 0.5 then [] else Array.cons x (upTo (x + 1.0))
    | otherwise = Array.reverse (enumRange to from)
  addSemitones k x = x + Int.toNumber k

-- | String: the two ends, as Tidal's `fromTo` for String.
instance tidalEnumString :: TidalEnum String where
  enumRange from to = [ from, to ]
  addSemitones _ x = x

-- | Rational: step by 1
instance tidalEnumRational :: TidalEnum Rational where
  enumRange from to = map fromInt (enumRange (rationalToInt from) (rationalToInt to))
    where
      rationalToInt r = floorR r
  addSemitones k x = x + fromInt k

-- | Primitive values for control patterns
-- |
-- | Unlike Haskell Tidal, this does NOT include:
-- | - VState (computations don't belong in values)
-- | - VPattern (patterns are separate from values)
-- | - VList (use arrays at pattern level instead)
data Value
  = VInt Int
  | VNumber Number
  | VString String
  | VNote Number
  | VBool Boolean
  | VRational Rational

derive instance eqValue :: Eq Value

-- | Semigroup instance for Value - right-biased (newer value wins)
-- | This is needed for Map String Value to have Monoid
instance semigroupValue :: Semigroup Value where
  append _ b = b

instance showValue :: Show Value where
  show = case _ of
    VInt n -> "VInt " <> show n
    VNumber n -> "VNumber " <> show n
    VString s -> "VString " <> show s
    VNote n -> "VNote " <> show n
    VBool b -> "VBool " <> show b
    VRational r -> "VRational " <> show r

instance ordValue :: Ord Value where
  compare a b = case a, b of
    -- Same types: compare values
    VInt x, VInt y -> compare x y
    VNumber x, VNumber y -> compare x y
    VString x, VString y -> compare x y
    VNote x, VNote y -> compare x y
    VBool x, VBool y -> compare x y
    VRational x, VRational y -> compare x y
    -- Different types: order by constructor tag
    VInt _, _ -> LT
    _, VInt _ -> GT
    VNumber _, _ -> LT
    _, VNumber _ -> GT
    VString _, _ -> LT
    _, VString _ -> GT
    VNote _, _ -> LT
    _, VNote _ -> GT
    VBool _, _ -> LT
    _, VBool _ -> GT

-- | Named control values
type ValueMap = Map String Value

-- | Control patterns produce named value maps
type ControlMap = ValueMap

-- | A pattern of control values
type ControlPattern = Pattern ValueMap

-------------------------------------------------------------------------------
-- State: Query context
-------------------------------------------------------------------------------

-- | State passed to pattern queries
-- |
-- | Contains the time arc being queried and any control values
-- | that should be threaded through the query.
newtype State = State
  { arc :: Arc
  , controls :: ControlMap
  }

derive instance newtypeState :: Newtype State _

instance showState :: Show State where
  show (State s) = "State { arc: " <> show s.arc <> " }"

-- | Create a state for querying a time arc
mkState :: Arc -> State
mkState arc = State { arc, controls: Map.empty }

-------------------------------------------------------------------------------
-- Pattern: The core abstraction
-------------------------------------------------------------------------------

-- | A Pattern is a function from a query state to events
-- |
-- | This is the fundamental abstraction in Tidal:
-- | - Patterns don't compute until queried with a specific time arc
-- | - The same query always produces the same events (referentially transparent)
-- | - Patterns compose functionally via Functor/Applicative/Monad
-- |
-- | Unlike Haskell Tidal, we don't expose optimization fields like
-- | `steps` or `pureValue` - these are implementation details.
newtype Pattern a = Pattern (State -> Array (Event a))

instance showPattern :: Show a => Show (Pattern a) where
  show _ = "Pattern <function>"

-- | Query a pattern for events in a time arc
query :: forall a. Pattern a -> State -> Array (Event a)
query (Pattern f) = f

-- | Construct a pattern from a query function
pattern :: forall a. (State -> Array (Event a)) -> Pattern a
pattern = Pattern

-- | The silent pattern - produces no events
silence :: forall a. Pattern a
silence = Pattern \_ -> []

-------------------------------------------------------------------------------
-- Pattern instances
-------------------------------------------------------------------------------

instance functorPattern :: Functor Pattern where
  map f (Pattern q) = Pattern \st -> map (mapEventValue f) (q st)

instance applyPattern :: Apply Pattern where
  apply = applyPatternBoth

instance applicativePattern :: Applicative Pattern where
  pure = purePattern

instance bindPattern :: Bind Pattern where
  bind = bindPattern'

instance monadPattern :: Monad Pattern

-------------------------------------------------------------------------------
-- Internal: Applicative implementation
-------------------------------------------------------------------------------

-- | Pure pattern: the value once per cycle, as Haskell Tidal's `pure`. The
-- | part is the cycle intersected with the query, zero-width when the query
-- | is (Tidal's zero-width queries find the event at that instant).
purePattern :: forall a. a -> Pattern a
purePattern v = Pattern \(State { arc: queryArc }) ->
  map
    (\cycleArc -> Digital { context: emptyContext, whole: cycleArc, part: sect queryArc cycleArc, value: v })
    (cycleArcsInArc queryArc)

-- | Structure from both sides: Haskell Tidal's `<*>` (`applyPatToPatBoth`).
-- | Digital function events meet digital values over the function's whole;
-- | analog ones meet every value over their part; analog values meet
-- | digital functions over theirs. Wholes are intersected (`Nothing` if
-- | either is analog), parts by `subArc`.
applyPatternBoth :: forall a b. Pattern (a -> b) -> Pattern a -> Pattern b
applyPatternBoth (Pattern pf) (Pattern px) = Pattern \st ->
  let
    at arc = setArc st arc
    match ef = case ef of
      Analog f -> Array.mapMaybe (withFX ef) (px (at f.part))
      Digital f -> Array.mapMaybe (withFX ef) (Array.filter isDigital (px (at f.whole)))
    matchX ex = Array.mapMaybe (\ef -> withFX ef ex) (Array.filter isDigital (pf (at (eventPart ex))))
  in
    Array.concatMap match (pf st) <> Array.concatMap matchX (Array.filter isAnalog (px st))
  where
  withFX :: Event (a -> b) -> Event a -> Maybe (Event b)
  withFX ef ex = do
    part <- subArc (eventPart ef) (eventPart ex)
    let context = eventContext ef <> eventContext ex
        value = eventValue ef (eventValue ex)
    case eventWhole ef, eventWhole ex of
      Just wf, Just wx -> subArc wf wx <#> \whole -> Digital { context, whole, part, value }
      _, _ -> Just (Analog { context, part, value })

eventContext :: forall a. Event a -> Context
eventContext (Digital e) = e.context
eventContext (Analog e) = e.context

-- | The whole of a digital event, the part of an analog one.
wholeOrPart :: forall a. Event a -> Arc
wholeOrPart (Digital e) = e.whole
wholeOrPart (Analog e) = e.part

-- | Structure from the left: Haskell Tidal's `<*` (`applyPatToPatLeft`).
-- | Each function event keeps its whole; the values are queried over that
-- | whole, and each match narrows the part. This is what `#` is built on.
applyLeft :: forall a b. Pattern (a -> b) -> Pattern a -> Pattern b
applyLeft (Pattern pf) (Pattern px) = Pattern \st ->
  Array.concatMap
    (\ef -> Array.mapMaybe (withFX ef) (px (setArc st (wholeOrPart ef))))
    (pf st)
  where
  withFX ef ex = subArc (eventPart ef) (eventPart ex) <#> \part ->
    rebuild ef part (eventContext ef <> eventContext ex) (eventValue ef (eventValue ex))

-- | Structure from the right: Haskell Tidal's `*>` (`applyPatToPatRight`).
applyRight :: forall a b. Pattern (a -> b) -> Pattern a -> Pattern b
applyRight (Pattern pf) (Pattern px) = Pattern \st ->
  Array.concatMap
    (\ex -> Array.mapMaybe (\ef -> withFX ef ex) (pf (setArc st (wholeOrPart ex))))
    (px st)
  where
  withFX ef ex = subArc (eventPart ef) (eventPart ex) <#> \part ->
    rebuild ex part (eventContext ef <> eventContext ex) (eventValue ef (eventValue ex))

setArc :: State -> Arc -> State
setArc (State s) arc = State s { arc = arc }

-- | An event of the given one's kind and whole, with a new part, context and
-- | value.
rebuild :: forall a b. Event a -> Arc -> Context -> b -> Event b
rebuild e part context value = case e of
  Digital d -> Digital { context, whole: d.whole, part, value }
  Analog _ -> Analog { context, part, value }

-------------------------------------------------------------------------------
-- Internal: Monad implementation (unwrap/join)
-------------------------------------------------------------------------------

-- | Bind is Haskell Tidal's `unwrap`: each outer event's part queries the
-- | inner pattern; wholes are intersected (`Nothing` if either is analog),
-- | parts by `subArc`.
bindPattern' :: forall a b. Pattern a -> (a -> Pattern b) -> Pattern b
bindPattern' (Pattern pa) f = Pattern \st@(State s) ->
  Array.concatMap
    (\oe -> Array.mapMaybe (munge oe) (query (f (eventValue oe)) (State s { arc = eventPart oe })))
    (pa st)
  where
  munge oe ie = do
    part <- subArc (eventPart oe) (eventPart ie)
    let context = eventContext ie <> eventContext oe
        value = eventValue ie
    case eventWhole oe, eventWhole ie of
      Just wo, Just wi -> subArc wo wi <#> \whole -> Digital { context, whole, part, value }
      _, _ -> Just (Analog { context, part, value })

-------------------------------------------------------------------------------
-- Internal: Arc utilities
-------------------------------------------------------------------------------

-- | Haskell Tidal's `subArc`: the intersection of two arcs, `Nothing` when
-- | they do not meet. A zero-width intersection survives only when it is not
-- | the end of a non-zero-width arc, so an event is not matched by the next
-- | one's start.
subArc :: Arc -> Arc -> Maybe Arc
subArc (Arc x) (Arc y) =
  let
    s = max x.start y.start
    e = min x.stop y.stop
    endOf a = s == e && s == a.stop && a.start < a.stop
  in
    if endOf x || endOf y || s > e then Nothing
    else Just (Arc { start: s, stop: e })

-- | The whole cycles a query touches, as Haskell Tidal's `cycleArcsInArc`:
-- | none for a backwards arc, the cycle containing it for a zero-width one,
-- | otherwise every cycle from the start's to the one before the end's
-- | ceiling. Full cycles, not clipped: atoms take their whole from these.
cycleArcsInArc :: Arc -> Array Arc
cycleArcsInArc (Arc { start, stop }) =
  if start > stop then []
  else if start == stop then [ cycleOf (sam start) ]
  else
    let first = floorR start
        lastC = ceilR stop - 1
    in if lastC < first then [] else map (cycleOf <<< fromInt) (Array.range first lastC)
  where
  cycleOf c = Arc { start: c, stop: c + one }

-- | Haskell's `sect`: the overlap of two arcs, possibly empty or backwards.
sect :: Arc -> Arc -> Arc
sect (Arc a) (Arc b) = Arc { start: max a.start b.start, stop: min a.stop b.stop }

-- | Haskell's `floor` on a time, exact, as a cycle number.
floorR :: Rational -> Int
floorR = Integer.toInt <<< Rational.floor

ceilR :: Rational -> Int
ceilR r = negate (floorR (negate r))

-- | Floor division. Not `div`: purs-backend-erl compiles Int `div` to
-- | Erlang's, which truncates towards zero, so `-1 div 2` is 0 there.
floorDiv :: Int -> Int -> Int
floorDiv a b =
  let q = Int.quot a b
  in if Int.rem a b /= 0 && ((a < 0) /= (b < 0)) then q - 1 else q

-- | The remainder to go with `floorDiv`: the sign of the divisor.
floorMod :: Int -> Int -> Int
floorMod a b = a - b * floorDiv a b

-- | Get the start of the cycle containing this time
-- | (equivalent to floor for positive, needs care for negative)
sam :: Time -> Time
sam t =
  let n = floorTime t
  in if n <= t then n else n - one

-- | Floor as Rational
floorTime :: Time -> Time
floorTime t = Rational.fromInt (floorR t)
