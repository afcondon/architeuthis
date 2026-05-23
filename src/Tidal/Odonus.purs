-- | Tidal.Odonus — typed Session-level binding for the BEAM-native
-- | Make-Noise-René-inspired machine.  Third member of the machine
-- | family per [[project_machines_naming]], after Balistes (autonomous,
-- | internal content) and Repetitor (autonomous, internal corpus).
-- |
-- | René sits in the hybrid quadrant: **user supplies the content**
-- | (16 notes the user writes, plus skip/gate/glide modal arrays),
-- | **engine supplies the traversal** (Cartesian XY or linear
-- | forward/reverse advance, skip-aware).  Y-clock is itself a
-- | `Pattern Bool` so the user can declare row-advance rhythm
-- | (e.g. `mini "1 0 0 0"` = advance row on beat 1 of each cycle).
-- |
-- | A typed Session-level binding looks like:
-- |
-- |     seq :: Odonus "seq"
-- |     seq = odonusWith
-- |       { device: iac
-- |       , channel: 11
-- |       , vel: 100
-- |       , durMs: 200
-- |       , stepsPerCycle: 4
-- |       , notes: [60, 62, 64, 65, 67, 69, 71, 72,
-- |                 74, 76, 77, 79, 81, 83, 84, 86]
-- |       , skip:  replicate16 false
-- |       , gate:  replicate16 true
-- |       , glide: replicate16 false
-- |       , navMode: NavCartesian
-- |       , config: { stepYNow: mini "1 0 0 0" }
-- |       }
-- |
-- | Engine fires X-step every master tick (default 4 per cycle).
-- | Whenever `stepYNow` returns true at a step's cycle position the
-- | engine fires Y-step BEFORE that step's X-step.  Skip-aware
-- | traversal hops over `skip` cells without firing; gate-off cells
-- | are landed on but silent.
module Tidal.Odonus
  ( Odonus(..)
  , OdonusConfig
  , OdonusSnapshot
  , NavMode(..)
  , odonus
  , odonusWith
  , odonusConfig
  , replicate16
  , evaluateParamsAt
  , evaluateParamsAtControls
  , buildControlMap
  ) where

import Prelude

import Tidal.MidiDevice (MidiDevice)
import Control.Applicative (pure)
import Data.Array as Array
import Data.Foldable (foldl)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Tidal.Pattern.Core (queryArcWith)
import Tidal.Pattern.Types (ControlMap, Event(..), Pattern, Value(..))
import Data.Rational (fromInt)

-- ---------------------------------------------------------------------------
-- NavMode — traversal modes
-- ---------------------------------------------------------------------------

-- | Three navigation modes for v1.  Cartesian uses both X and Y
-- | trigger inputs as independent axes (classic René).  Forward
-- | treats (x,y) as a single linear cursor that wraps 0..15.
-- | Reverse is forward in reverse — starts at 0, X-trigger advances
-- | to 15 then 14 etc.  Snake and random modes can be added later.
data NavMode = NavCartesian | NavForward | NavReverse

-- ---------------------------------------------------------------------------
-- OdonusConfig — patterned slots queried per step
-- ---------------------------------------------------------------------------

-- | Per-step patterned configuration.  The Y-clock (`stepYNow`) plus
-- | the two live-controllable modal arrays — 16 per-cell `notes` and
-- | 16 per-cell `skip` patterns — sampled by the voice on every step.
-- |
-- | The patterns are typically `liveIntOr` / `liveBoolOr` readers
-- | pointed at the live-control bus (`liveIntArrayOr` / `liveBoolArrayOr`
-- | spread the prefix across the 16 indices), so a controller surface
-- | like the Twister can sweep individual cells live.  Static defaults
-- | are perfectly valid — `map pure [60, 62, …]` works.
-- |
-- | Future extensions: dynamic quantise scale (`Pattern Scale`),
-- | per-cell `Pattern Int` velocity, per-cell gate weight, running
-- | nav-mode (`Pattern NavMode`).  Same shape; add fields here.
type OdonusConfig =
  { stepYNow :: Pattern Boolean
  , notes    :: Array (Pattern Int)
  , skip     :: Array (Pattern Boolean)
  -- | Advance gate.  Sampled per micro-tick; when false the engine
  -- | does NOT step (no X-advance, no Y-advance, no emit).  Default
  -- | `pure true` preserves "advance every tick" behaviour.  Drive
  -- | this with a Tidal pattern to get irregular clocking — e.g.
  -- | `pitch "1 0 0 1 0 1 0 0"` gives a 3-against-8 euclidean tempo.
  -- | The same gate-pattern shape will eventually apply to Balistes /
  -- | Repetitor / Steppy-style siblings.
  , advance  :: Pattern Boolean
  }

-- | Snapshot returned by `evaluateParamsAt`.  Carries the resolved
-- | per-cell arrays so the voice can refresh the engine's traversal
-- | state before step_x / step_y / current_event run.
type OdonusSnapshot =
  { stepYNow :: Boolean
  , notes    :: Array Int
  , skip     :: Array Boolean
  , advance  :: Boolean
  }

-- | Default config: Y-clock fires once per 4-step cycle (so
-- | Cartesian mode walks row by row of the 4x4 grid).  Default
-- | notes are middle-C-ish drum range; default skip is all-false.
-- | Override `stepYNow` to `pure false` to lock to row 0; override
-- | notes/skip with `liveIntArrayOr` / `liveBoolArrayOr` to make
-- | them controller-driven.
odonusConfig :: OdonusConfig
odonusConfig =
  { stepYNow: pure false
  , notes:    Array.replicate 16 (pure 60)
  , skip:     Array.replicate 16 (pure false)
  , advance:  pure true
  }

-- | Helper: build a 16-element array of a single repeated value.
-- | Cell-text-friendly shorthand for the `skip`/`gate`/`glide`
-- | defaults.
replicate16 :: forall a. a -> Array a
replicate16 v = Array.replicate 16 v

-- ---------------------------------------------------------------------------
-- The typed binding
-- ---------------------------------------------------------------------------

-- | A typed René voice declared at the Session level.  16-cell
-- | content + 4 modal arrays + nav mode + patterned Y-clock.
data Odonus (s :: Symbol)
  = OdonusBinding
      { device        :: MidiDevice
      , channel       :: Int
      , vel           :: Int
      , durMs         :: Int
      , stepsPerCycle :: Int
      , notes         :: Array Int   -- 16 entries; MIDI note numbers
      , skip          :: Array Boolean
      , gate          :: Array Boolean
      , glide         :: Array Boolean
      , navMode       :: NavMode
      , config        :: OdonusConfig
      }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

-- | Build a René binding with sensible defaults: vel 100, dur
-- | 200 ms, 4 steps per cycle, Cartesian navigation, all gates open,
-- | nothing skipped, no glides, Y-clock = `pure false` (single-row
-- | loop until you override).  User supplies 16 notes.
odonus
  :: forall s
   . MidiDevice
  -> Int          -- ^ MIDI channel 1..16
  -> Array Int    -- ^ 16 MIDI notes (padded/truncated to 16 on the engine side)
  -> Odonus s
odonus dev ch ns = OdonusBinding
  { device: dev
  , channel: ch
  , vel: 100
  , durMs: 200
  , stepsPerCycle: 4
  , notes: ns
  , skip:  replicate16 false
  , gate:  replicate16 true
  , glide: replicate16 false
  , navMode: NavCartesian
  , config: odonusConfig
  }

-- | Like `odonus` but fully explicit.
odonusWith
  :: forall s
   . { device :: MidiDevice
     , channel :: Int
     , vel :: Int, durMs :: Int
     , stepsPerCycle :: Int
     , notes :: Array Int
     , skip :: Array Boolean
     , gate :: Array Boolean
     , glide :: Array Boolean
     , navMode :: NavMode
     , config :: OdonusConfig
     }
  -> Odonus s
odonusWith = OdonusBinding

-- ---------------------------------------------------------------------------
-- Per-step parameter evaluation (called from Erlang)
-- ---------------------------------------------------------------------------

evaluateParamsAt
  :: OdonusConfig
  -> Array { name :: String, value :: Number }
  -> Number
  -> OdonusSnapshot
evaluateParamsAt cfg controlPairs pos =
  evaluateParamsAtControls cfg (pairsToControlMap controlPairs) pos

-- | Cache-friendly evaluator: takes a pre-built `ControlMap` instead
-- | of rebuilding from the snapshot pairs every step.  The voice
-- | gen_server holds onto the map across ticks and only rebuilds when
-- | `tidal_control_bus`'s version counter changes (F1 — see the
-- | timing investigation notes at `tools/timing-data/phase-4-diagnostic/`).
evaluateParamsAtControls
  :: OdonusConfig
  -> ControlMap
  -> Number
  -> OdonusSnapshot
evaluateParamsAtControls cfg controls pos =
  let sampleN p = sampleIntAt controls 60 p pos
      sampleS p = sampleBoolAt controls false p pos
  in { stepYNow: sampleBoolAt controls false cfg.stepYNow pos
     , notes:    map sampleN cfg.notes
     , skip:     map sampleS cfg.skip
     , advance:  sampleBoolAt controls true cfg.advance pos
     }

-- | Erlang-facing entry point so a voice can build the `ControlMap`
-- | once per control-bus version and reuse the opaque PureScript value
-- | across many `evaluateParamsAtControls` calls.
buildControlMap
  :: Array { name :: String, value :: Number }
  -> ControlMap
buildControlMap = pairsToControlMap

sampleBoolAt :: ControlMap -> Boolean -> Pattern Boolean -> Number -> Boolean
sampleBoolAt controls dflt pat at =
  let arc0 = fromInt (truncTo16th at)
      arc1 = fromInt (truncTo16th at + 1)
      slice = queryArcWith controls pat
                (arc0 / fromInt 16)
                (arc1 / fromInt 16)
  in case Array.head slice of
       Just (Digital e) -> e.value
       Just (Analog e)  -> e.value
       Nothing -> dflt

-- | Integer-typed twin of `sampleBoolAt`.  Used to sample per-cell
-- | `Pattern Int` notes at each step's cycle position.
sampleIntAt :: ControlMap -> Int -> Pattern Int -> Number -> Int
sampleIntAt controls dflt pat at =
  let arc0 = fromInt (truncTo16th at)
      arc1 = fromInt (truncTo16th at + 1)
      slice = queryArcWith controls pat
                (arc0 / fromInt 16)
                (arc1 / fromInt 16)
  in case Array.head slice of
       Just (Digital e) -> e.value
       Just (Analog e)  -> e.value
       Nothing -> dflt

pairsToControlMap
  :: Array { name :: String, value :: Number }
  -> ControlMap
pairsToControlMap pairs =
  foldl (\m p -> Map.insert p.name (VNumber p.value) m) Map.empty pairs

truncTo16th :: Number -> Int
truncTo16th n = floorN (n * 16.0)

foreign import floorN :: Number -> Int
