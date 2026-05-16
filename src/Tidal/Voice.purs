-- | Per-voice state container — the value held by a `tidal_voice`
-- | gen_server.
-- |
-- | The voice's two responsibilities:
-- |   1. Hold its current Pattern, kind-specific dispatch info, phase,
-- |      and mute state.
-- |   2. On `compute_until` cast (driven by the clock), query the
-- |      Pattern for events in the requested window and produce a list
-- |      of `EventToDispatch` values — each one a tagged tuple the
-- |      Erlang gen_server iterates over and casts to the dispatcher.
-- |
-- | A voice is one of two kinds:
-- |
-- |   * **Discrete** — `Pattern String`, dispatched through a
-- |     `Tidal.Binding.Binding` (gate / cv / midi-note / midi-cc /
-- |     esx / es5gate). `#`-joined param patterns supply slot
-- |     overrides and compositional fanout.
-- |   * **Continuous** — `Pattern Number` (an LFO, oscillator, or
-- |     numeric-pattern expression), dispatched to a `ContDest`
-- |     (MIDI CC or CV bus). One sample per tick at the clock's
-- |     `currentCycle`; no look-ahead needed.
-- |
-- | The kind is opaque to Erlang: the gen_server passes the State
-- | through PureScript helpers and only inspects events at the
-- | dispatch boundary, where `EventToDispatch`'s tag tells it which
-- | dispatcher API to invoke.
-- |
-- | Side-effecting work (the cast loop) lives in Erlang; PureScript
-- | only does pure pattern math.
module Tidal.Voice
  ( State
  , initialState
  , initialContinuousState
  , setPattern
  , setPatternWithParams
  , setContinuousPattern
  , installFromSpec
  , clearPattern
  , setMuted
  , resetPhase
  , Snapshot
  , snapshot
  , Window
  , EventToDispatch(..)
  , ComputeResult
  , computeUntil
  , liftStringToPitch
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Rational (Rational, fromInt)
import Data.Rational as R
import Data.Tuple (Tuple(..))
import Tidal.Binding (Binding, ContDest)
import Tidal.Dispatch.Helpers (samplePatternAtWith)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Core (queryArcWith)
import Tidal.Pattern.Types (Arc(..), ControlMap, Event(..), Pattern, Value(..))
import Tidal.Pitch (Pitch(..), pitchToken)
import Tidal.Pitch.Parse (miniToken)
import Tidal.Scales (Scale, renderDegree)

-- ---------------------------------------------------------------------------
-- VoiceKind — discrete vs continuous voice payload (private).
-- ---------------------------------------------------------------------------

-- | A voice's kind-specific payload. Internal — not exported. Erlang
-- | sees `State` as opaque; discrimination happens at the
-- | `EventToDispatch` boundary instead.
-- |
-- | A discrete voice's pattern is `Pattern Pitch` — the typed
-- | substrate.  `Pitch` carries Degree / Chromatic / Sample; the
-- | voice renders to a token-string at emit time, consulting the
-- | active scale (Window.activeScale) for Degrees.  Params stay
-- | `Pattern String` since `#`-joined params (`# gain "0.5 0.8"`) are
-- | numeric / sample-name controls, not pitch-bearing.
data VoiceKind
  = Discrete
      { pattern :: Maybe (Pattern Pitch)
      , params :: Map String (Pattern String)
      , binding :: Binding
      }
  | Continuous
      { pattern :: Maybe (Pattern Number)
      , dest :: ContDest
      }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- | Per-voice state.
-- |
-- |   * `name` — the bound name (`bass`, `lead`); the gen_server
-- |     registers as `tidal_voice_<name>`.
-- |   * `kind` — the kind-specific payload (Discrete vs Continuous).
-- |   * `phase` — cycle position. Carries over `setPattern` by default;
-- |     reset by `resetPhase`.
-- |   * `lastEmittedUntil` — cycle-time up to which events have been
-- |     dispatched; the next compute window starts here. Used by the
-- |     Discrete branch to dedup across ticks; the Continuous branch
-- |     ignores it (one emission per tick regardless).
-- |   * `muted` — when true the pattern still queries (phase advances)
-- |     but events are dropped at the dispatch boundary. Distinct from
-- |     stop and from clock-level pause.
newtype State = State
  { name :: String
  , kind :: VoiceKind
  , phase :: Rational
  , lastEmittedUntil :: Rational
  , muted :: Boolean
  }

-- | Make a Discrete voice with no pattern yet, holding its Binding.
initialState :: String -> Binding -> State
initialState name binding = State
  { name
  , kind: Discrete { pattern: Nothing, params: Map.empty, binding }
  , phase: fromInt 0
  , lastEmittedUntil: fromInt 0
  , muted: false
  }

-- | Make a Continuous voice with no pattern yet, holding its ContDest.
initialContinuousState :: String -> ContDest -> State
initialContinuousState name dest = State
  { name
  , kind: Continuous { pattern: Nothing, dest }
  , phase: fromInt 0
  , lastEmittedUntil: fromInt 0
  , muted: false
  }

-- | Replace the pattern on a Discrete voice. Silent no-op on a
-- | Continuous voice — the WS handler is responsible for routing
-- | by kind, so reaching this with a Continuous voice indicates a
-- | bug; we'd rather drop than crash mid-tick.
setPattern :: Pattern Pitch -> State -> State
setPattern p (State s) = case s.kind of
  Discrete d -> State (s { kind = Discrete (d { pattern = Just p, params = Map.empty }) })
  Continuous _ -> State s

-- | Replace the pattern AND the parameter-pattern map atomically on a
-- | Discrete voice. Silent no-op on Continuous.
setPatternWithParams
  :: Pattern Pitch
  -> Map String (Pattern String)
  -> State
  -> State
setPatternWithParams p ps (State s) = case s.kind of
  Discrete d -> State (s { kind = Discrete (d { pattern = Just p, params = ps }) })
  Continuous _ -> State s

-- | Replace the pattern on a Continuous voice. Silent no-op on Discrete.
setContinuousPattern :: Pattern Number -> State -> State
setContinuousPattern p (State s) = case s.kind of
  Continuous c -> State (s { kind = Continuous (c { pattern = Just p }) })
  Discrete _ -> State s

-- | Parse a `<name> <pat>` body + its `# <key> <pat>` segments and
-- | install both atomically on a Discrete voice. Param specs that
-- | fail to parse are dropped (mirroring MIDIScheduler.PlayByName's
-- | behaviour); the structure pattern's parse error returns Left and
-- | leaves state untouched. Silent no-op (returns Right) on Continuous.
installFromSpec
  :: String
  -> Array { name :: String, pat :: String }
  -> State
  -> Either String State
installFromSpec patStr paramSpecs st@(State s) = case s.kind of
  Continuous _ -> Right st
  Discrete _ -> case parse patStr of
    Left err -> Left (show err)
    Right ast ->
      let
        -- Parser produces Pattern String; lift to Pattern Pitch using
        -- mini-classifier (per-token Note vs Sample shape).  Same
        -- semantics as `Tidal.Pitch.Parse.mini`, fused inline so we
        -- avoid re-parsing.
        stringPat = tpatToPattern ast :: Pattern String
        pitchPat = map miniToken stringPat
        paramsMap = Map.fromFoldable
          $ Array.mapMaybe
              (\ps -> case parse ps.pat of
                Right p -> Just (Tuple ps.name (tpatToPattern p :: Pattern String))
                Left _ -> Nothing)
              paramSpecs
      in Right (setPatternWithParams pitchPat paramsMap st)

-- | Lift a `Pattern String` produced by the bare mini parser into a
-- | `Pattern Pitch` using the per-token mini classifier.  Used at the
-- | Erlang boundary by verbs that parse their pattern body separately
-- | (e.g. `fh2-trigger`, `kit`) and then hand it to `set_voice_pat`.
liftStringToPitch :: Pattern String -> Pattern Pitch
liftStringToPitch = map miniToken

-- | Clear the pattern of a voice regardless of kind. Used by
-- | `unbind` and by Tidal-compat `hush_all`.
clearPattern :: State -> State
clearPattern (State s) = case s.kind of
  Discrete d -> State (s { kind = Discrete (d { pattern = Nothing, params = Map.empty }) })
  Continuous c -> State (s { kind = Continuous (c { pattern = Nothing }) })

setMuted :: Boolean -> State -> State
setMuted m (State s) = State (s { muted = m })

resetPhase :: State -> State
resetPhase (State s) = State
  (s { phase = fromInt 0, lastEmittedUntil = fromInt 0 })

-- ---------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------

-- | Read-only snapshot for the `state` verb. Compiles to a flat Erlang
-- | map (no newtype wrapper) so the WS handler can serialize it
-- | directly. The full Pattern object isn't included — `hasPattern`
-- | flags whether one is set.
type Snapshot =
  { name :: String
  , kind :: String
  , hasPattern :: Boolean
  , paramCount :: Int
  , muted :: Boolean
  }

snapshot :: State -> Snapshot
snapshot (State s) = case s.kind of
  Discrete d ->
    { name: s.name
    , kind: "discrete"
    , hasPattern: case d.pattern of
        Just _ -> true
        Nothing -> false
    , paramCount: Map.size d.params
    , muted: s.muted
    }
  Continuous c ->
    { name: s.name
    , kind: "continuous"
    , hasPattern: case c.pattern of
        Just _ -> true
        Nothing -> false
    , paramCount: 0
    , muted: s.muted
    }

-- ---------------------------------------------------------------------------
-- Compute window — the per-tick query the clock broadcasts to voices.
-- ---------------------------------------------------------------------------

-- | The clock's view of "now" + lookahead, packaged for voices.
-- |
-- | Same affine map every voice uses on a given tick; sent in one
-- | message rather than each voice querying LinkAnchor independently.
type Window =
  { currentCycle :: Number
  , lookAheadCycle :: Number
  , cycleDurationMs :: Number
  , nowUnixUs :: Number
  , controlPairs :: Array { name :: String, value :: Number }
  -- ^ Snapshot of the live control bus at the start of this tick.
  --   Erlang side: list of #{name => binary, value => float} maps,
  --   which purerl decodes to this array-of-records shape.  Each
  --   tick gets a fresh snapshot, so all voices in this pass see
  --   the same controls — no cross-voice inconsistency.
  , activeScale :: Maybe Scale
  -- ^ Active scale for rendering unresolved `Degree` pitches.  When
  --   `Nothing`, Degree patterns silently drop (the user hasn't said
  --   `set-scale ...`).  When `Just s`, every Degree event renders
  --   through `s` at this tick — global key changes are one ETS
  --   write away from re-rendering all running degree patterns.
  }

-- | One event the voice wants the dispatcher to send.
-- |
-- | Two flavors, one per voice kind:
-- |
-- |   * `DiscreteEvent` — token + sampled `#`-join params; the
-- |     dispatcher walks the Binding's PrimAction list.
-- |   * `ContinuousEvent` — a single sampled value; the dispatcher
-- |     emits one CC / CV update against the voice's recorded
-- |     `ContDest`.
-- |
-- | The Erlang voice's compute_until handler pattern-matches on the
-- | tag tuple to pick the right `tidal_dispatcher` API:
-- |   `{discreteEvent, M}` → `tidal_dispatcher:dispatch_event/4`.
-- |   `{continuousEvent, M}` → `tidal_dispatcher:dispatch_cont_event/3`.
data EventToDispatch
  = DiscreteEvent
      { token :: String
      , wallTimeUs :: Number
      , params :: Map String String
      }
  | ContinuousEvent
      { value :: Number
      , wallTimeUs :: Number
      }

-- | Result of `computeUntil`: new voice state plus the events to
-- | dispatch this tick. The Erlang gen_server iterates `events` and
-- | casts each to `tidal_dispatcher`.
type ComputeResult =
  { newState :: State
  , events :: Array EventToDispatch
  }

-- | Query the voice's pattern and produce the events to dispatch this
-- | tick. Behavior splits by kind:
-- |
-- |   * **Discrete**: query (lastEmittedUntil .. lookAheadCycle], emit
-- |     one event per Pattern event with absolute Unix-µs wall time.
-- |   * **Continuous**: sample at currentCycle; emit zero or one event
-- |     at `nowUnixUs`. lastEmittedUntil is unused here (each tick
-- |     re-samples; no dedup needed).
-- |
-- | Phase always advances regardless; mute drops emissions but doesn't
-- | gate the query.
-- |
-- | Pure function — no side effects. The cast loop happens in Erlang.
computeUntil :: Window -> State -> ComputeResult
computeUntil w (State s) =
  let controls = pairsToControlMap w.controlPairs
  in case s.kind of
    Discrete d -> computeDiscrete w controls (State s) d
    Continuous c -> computeContinuous w controls (State s) c

-- | Materialise the Window's control-bus snapshot as a ControlMap
-- | the pattern query machinery understands.  Erlang ships the bus
-- | as `Array { name :: String, value :: Number }`; pattern queries
-- | want `Map String Value` with `VNumber` payloads.  Cheap conversion
-- | per tick; the alternative (Erlang building the Map directly) is
-- | tangled in purs-backend-erl's tree-of-Tuples representation.
pairsToControlMap :: Array { name :: String, value :: Number } -> ControlMap
pairsToControlMap = Map.fromFoldable
  <<< map (\p -> Tuple p.name (VNumber p.value))

computeDiscrete
  :: Window
  -> ControlMap
  -> State
  -> { pattern :: Maybe (Pattern Pitch)
     , params :: Map String (Pattern String)
     , binding :: Binding
     }
  -> ComputeResult
computeDiscrete w controls (State s) d = case d.pattern of
  Nothing -> { newState: State s, events: [] }
  Just pat ->
    let
      fromCycleNum = max (R.toNumber s.lastEmittedUntil) w.currentCycle
      toCycleNum = w.lookAheadCycle
      fromCycle = fromInt (Int.floor fromCycleNum)
      toCycle = fromInt (Int.floor toCycleNum + 1)
    in
      if fromCycle >= toCycle then
        { newState: State s, events: [] }
      else
        let
          -- Whole-integer-cycle emission. Dedup across ticks comes
          -- from `lastEmittedUntil` advancing by the same integer
          -- toCycle; subsequent ticks short-circuit until the next
          -- integer boundary. (Earlier sub-cycle filters dropped
          -- events at non-zero positions — see PR1.4e+1 fix.)
          queryEvents = queryArcWith controls pat fromCycle toCycle
          -- Sample each param pattern at this event's cycle position.
          -- Params with no event at this point (e.g. a rest token) are
          -- absent from the map; the dispatcher treats absence as
          -- "use binding default".
          sampleParamsAt cyc =
            Map.fromFoldable
              $ Array.mapMaybe
                  (\(Tuple paramName paramPat) ->
                    case samplePatternAtWith controls cyc paramPat of
                      Just v -> Just (Tuple paramName v)
                      Nothing -> Nothing)
                  (Map.toUnfoldable d.params :: Array (Tuple String (Pattern String)))
          -- Render Pitch → dispatcher-facing token using the active
          -- scale (if any).  Degree pitches without an active scale
          -- become silence (token = "" → dispatcher drops).
          renderToken :: Pitch -> Maybe String
          renderToken = case _ of
            Chromatic n -> Just (show n)
            Sample tok -> Just tok
            Degree deg -> case w.activeScale of
              Just scl -> Just (show (renderDegree scl deg))
              Nothing -> Nothing
          toDispatch :: Event Pitch -> Maybe EventToDispatch
          toDispatch e = case renderToken (eventPitch e) of
            Nothing -> Nothing
            Just tok ->
              let
                eventCycle = eventStartCycle e
                cycleN = R.toNumber eventCycle
                delayMs = (cycleN - w.currentCycle) * w.cycleDurationMs
                delayClamped = max 0.0 delayMs
                wallTimeUs = w.nowUnixUs + delayClamped * 1000.0
              in Just $ DiscreteEvent
                { token: tok
                , wallTimeUs
                , params: sampleParamsAt eventCycle
                }
          evs = if s.muted
                  then []
                  else Array.mapMaybe toDispatch queryEvents
          newSt = State (s { lastEmittedUntil = toCycle })
        in
          { newState: newSt, events: evs }

computeContinuous
  :: Window
  -> ControlMap
  -> State
  -> { pattern :: Maybe (Pattern Number), dest :: ContDest }
  -> ComputeResult
computeContinuous w controls (State s) c = case c.pattern of
  Nothing -> { newState: State s, events: [] }
  Just pat ->
    let
      cyc = numberToCycleRat w.currentCycle
      mValue = samplePatternAtWith controls cyc pat
      evs = case mValue of
        Just v
          | not s.muted ->
              [ ContinuousEvent { value: v, wallTimeUs: w.nowUnixUs } ]
        _ -> []
    in
      { newState: State s, events: evs }

-- | Convert a fractional-cycle Number to a Rational at microcycle
-- | precision (one part per million per cycle). Plenty for the
-- | continuous-voice sampler — at BPM 120 that's 1µs precision,
-- | well below the ~50ms tick period.
numberToCycleRat :: Number -> Rational
numberToCycleRat c = fromInt (Int.floor (c * 1000000.0)) / fromInt 1000000

-- ---------------------------------------------------------------------------
-- Event helpers (private — not yet promoted to Pattern.Types).
-- ---------------------------------------------------------------------------

-- | Start cycle of an event. Digital events use `whole.start`
-- | (the canonical event boundary, Tidal-style); Analog events fall
-- | back to `part.start` (analog has no whole).
eventStartCycle :: forall a. Event a -> Rational
eventStartCycle = case _ of
  Digital { whole: Arc { start } } -> start
  Analog { part: Arc { start } } -> start

eventPitch :: Event Pitch -> Pitch
eventPitch = case _ of
  Digital { value } -> value
  Analog { value } -> value
