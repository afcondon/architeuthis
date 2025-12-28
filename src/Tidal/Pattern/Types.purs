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
    -- * Values for control patterns
  , Value(..)
  , Note(..)
  , mkNote
  , ValueMap
  , ControlPattern
    -- * Utilities
  , mkState
    -- * Re-exports
  , module Tidal.Core.Types
  ) where

import Prelude

import Data.Array (concatMap, filter) as Array
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype)
import Data.Rational (fromInt, toNumber) as Rational
import Data.Rational (Rational)
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
  | VNote Note
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

-- | Pure pattern - constant value repeating every cycle
purePattern :: forall a. a -> Pattern a
purePattern v = Pattern \(State { arc: queryArc }) ->
  Array.concatMap (mkEvent v queryArc) (cycleArcsInArc queryArc)
  where
    mkEvent :: a -> Arc -> Arc -> Array (Event a)
    mkEvent val qArc cycleArc =
      case sectArc qArc cycleArc of
        Nothing -> []
        Just part ->
          [ Digital { context: emptyContext, whole: cycleArc, part, value: val } ]

-- | Default applicative: structure from both sides
applyPatternBoth :: forall a b. Pattern (a -> b) -> Pattern a -> Pattern b
applyPatternBoth (Pattern pf) (Pattern px) = Pattern \st ->
  let
    -- Get function events
    fEvents = pf st
    -- For each function event, find matching value events
    applyOne :: Event (a -> b) -> Array (Event b)
    applyOne fe = case fe of
      -- Analog function: query values for the part
      Analog f ->
        let xEvents = px (setState st f.part)
        in Array.concatMap (combineAnalog f) xEvents
      -- Digital function: query values for the whole
      Digital f ->
        let xEvents = filterDigital $ px (setState st f.whole)
        in Array.concatMap (combineDigital f) xEvents
  in Array.concatMap applyOne fEvents
  where
    setState (State s) arc = State s { arc = arc }

    filterDigital :: Array (Event a) -> Array (Event a)
    filterDigital = Array.filter isDigital

    combineAnalog :: forall x y. { context :: Context, part :: Arc, value :: x -> y }
                  -> Event x -> Array (Event y)
    combineAnalog f xe = case sectArc f.part (eventPart xe) of
      Nothing -> []
      Just part ->
        [ Analog
            { context: f.context <> eventContext xe
            , part
            , value: f.value (eventValue xe)
            }
        ]

    combineDigital :: forall x y.
      { context :: Context, whole :: Arc, part :: Arc, value :: x -> y }
      -> Event x -> Array (Event y)
    combineDigital f (Digital x) =
      case sectArc f.whole x.whole of
        Nothing -> []
        Just whole' -> case sectArc f.part x.part of
          Nothing -> []
          Just part' ->
            [ Digital
                { context: f.context <> x.context
                , whole: whole'
                , part: part'
                , value: f.value x.value
                }
            ]
    combineDigital _ (Analog _) = [] -- Already filtered

eventContext :: forall a. Event a -> Context
eventContext (Digital e) = e.context
eventContext (Analog e) = e.context

-------------------------------------------------------------------------------
-- Internal: Monad implementation (unwrap/join)
-------------------------------------------------------------------------------

-- | Bind for patterns - structure from both outer and inner
bindPattern' :: forall a b. Pattern a -> (a -> Pattern b) -> Pattern b
bindPattern' (Pattern pa) f = Pattern \st ->
  let
    outerEvents = pa st
    processOuter :: Event a -> Array (Event b)
    processOuter oe = case oe of
      Analog o ->
        let innerPat = f o.value
            innerEvents = query innerPat (setState st o.part)
        in Array.concatMap (mungeAnalog o) innerEvents
      Digital o ->
        let innerPat = f o.value
            innerEvents = query innerPat (setState st o.part)
        in Array.concatMap (mungeDigital o) innerEvents
  in Array.concatMap processOuter outerEvents
  where
    setState (State s) arc = State s { arc = arc }

    mungeAnalog :: { context :: Context, part :: Arc, value :: a }
                -> Event b -> Array (Event b)
    mungeAnalog o ie = case sectArc o.part (eventPart ie) of
      Nothing -> []
      Just part' -> case ie of
        Analog i ->
          [ Analog { context: o.context <> i.context, part: part', value: i.value } ]
        Digital i ->
          [ Analog { context: o.context <> i.context, part: part', value: i.value } ]

    mungeDigital :: { context :: Context, whole :: Arc, part :: Arc, value :: a }
                 -> Event b -> Array (Event b)
    mungeDigital o ie = case sectArc o.part (eventPart ie) of
      Nothing -> []
      Just part' -> case ie of
        Analog i ->
          [ Digital { context: o.context <> i.context, whole: o.whole, part: part', value: i.value } ]
        Digital i -> case sectArc o.whole i.whole of
          Nothing -> []
          Just whole' ->
            [ Digital { context: o.context <> i.context, whole: whole', part: part', value: i.value } ]

-------------------------------------------------------------------------------
-- Internal: Arc utilities
-------------------------------------------------------------------------------

-- | Intersect two arcs, returning Nothing if they don't overlap
sectArc :: Arc -> Arc -> Maybe Arc
sectArc (Arc a) (Arc b) =
  let s = max a.start b.start
      e = min a.stop b.stop
  in if s < e then Just (Arc { start: s, stop: e }) else Nothing

-- | Get the cycle arcs that overlap with a given arc
-- |
-- | A cycle is the time interval [n, n+1) for integer n.
-- | This splits a query arc into per-cycle chunks.
cycleArcsInArc :: Arc -> Array Arc
cycleArcsInArc (Arc { start, stop }) =
  let startCycle = sam start
      go acc s =
        if s >= stop then acc
        else go (acc <> [Arc { start: max start s, stop: min stop (s + one) }]) (s + one)
  in go [] startCycle

-- | Get the start of the cycle containing this time
-- | (equivalent to floor for positive, needs care for negative)
sam :: Time -> Time
sam t =
  let n = floorTime t
  in if n <= t then n else n - one

-- | Floor as Rational
floorTime :: Time -> Time
floorTime t = Rational.fromInt (Int.floor (Rational.toNumber t))
