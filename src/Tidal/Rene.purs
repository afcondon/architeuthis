-- | Tidal.Rene — typed Session-level binding for the BEAM-native
-- | Make-Noise-René-inspired machine.  Third member of the machine
-- | family per [[project_machines_naming]], after Grids (autonomous,
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
-- |     seq :: Rene "seq"
-- |     seq = reneWith
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
module Tidal.Rene
  ( Rene(..)
  , ReneConfig
  , ReneSnapshot
  , NavMode(..)
  , rene
  , reneWith
  , reneConfig
  , replicate16
  , evaluateParamsAt
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
-- ReneConfig — patterned slots queried per step
-- ---------------------------------------------------------------------------

-- | Per-step patterned configuration.  For now: just the Y-clock
-- | (a `Pattern Bool` that fires step_y when true).  Future
-- | extensions: dynamic quantise scale (`Pattern Scale`), running
-- | nav-mode (`Pattern NavMode`), live note replacement, …
type ReneConfig =
  { stepYNow :: Pattern Boolean
  }

-- | Snapshot returned by `evaluateParamsAt`.
type ReneSnapshot =
  { stepYNow :: Boolean
  }

-- | Default config: Y-clock fires once per 4-step cycle (so
-- | Cartesian mode walks row by row of the 4x4 grid).  Override to
-- | something like `pure false` to lock the cursor to row 0.
reneConfig :: ReneConfig
reneConfig =
  { stepYNow: pure false
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
data Rene (s :: Symbol)
  = ReneBinding
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
      , config        :: ReneConfig
      }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

-- | Build a René binding with sensible defaults: vel 100, dur
-- | 200 ms, 4 steps per cycle, Cartesian navigation, all gates open,
-- | nothing skipped, no glides, Y-clock = `pure false` (single-row
-- | loop until you override).  User supplies 16 notes.
rene
  :: forall s
   . MidiDevice
  -> Int          -- ^ MIDI channel 1..16
  -> Array Int    -- ^ 16 MIDI notes (padded/truncated to 16 on the engine side)
  -> Rene s
rene dev ch ns = ReneBinding
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
  , config: reneConfig
  }

-- | Like `rene` but fully explicit.
reneWith
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
     , config :: ReneConfig
     }
  -> Rene s
reneWith = ReneBinding

-- ---------------------------------------------------------------------------
-- Per-step parameter evaluation (called from Erlang)
-- ---------------------------------------------------------------------------

evaluateParamsAt
  :: ReneConfig
  -> Array { name :: String, value :: Number }
  -> Number
  -> ReneSnapshot
evaluateParamsAt cfg controlPairs pos =
  let controls = pairsToControlMap controlPairs
  in { stepYNow: sampleBoolAt controls false cfg.stepYNow pos
     }

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

pairsToControlMap
  :: Array { name :: String, value :: Number }
  -> ControlMap
pairsToControlMap pairs =
  foldl (\m p -> Map.insert p.name (VNumber p.value) m) Map.empty pairs

truncTo16th :: Number -> Int
truncTo16th n = floorN (n * 16.0)

foreign import floorN :: Number -> Int
