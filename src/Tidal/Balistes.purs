-- | Tidal.Balistes — typed Session-level binding for the BEAM-native MI
-- | Balistes virtual module.  First member of the vmod family per memory
-- | `project_beam_native_virtual_modules`; first concrete instance of
-- | the parameter-as-Pattern lift per `project_parameter_as_pattern_lift`.
-- |
-- | A typed Session-level binding looks like:
-- |
-- |     drums :: Balistes "drums"
-- |     drums = balistes fh2qd 14 $ balistesConfig
-- |       { x          = pure 128
-- |       , y          = pure 128
-- |       , fillBd     = pure 200
-- |       , fillSd     = pure 140
-- |       , fillHh     = pure 180
-- |       , randomness = pure 32
-- |       }
-- |
-- | All seven config slots are `Pattern Int`.  Static values are
-- | `pure n`; live-coded values use mini-notation (`mini "<100 150
-- | 200>"`) or composed patterns (`sine # range 0 255 # slow 4`).
-- | The walker classifies the value by constructor tag, ships a
-- | `RegisterBalistes` event with the opaque config Foreign payload to
-- | the Erlang shell, which spawns a `balistes_voice` gen_server.  Per
-- | step (32 steps per cycle), the voice calls back into PureScript
-- | via `evaluateParamsAt` to query each pattern at the step's cycle
-- | position, then hands the seven Ints to `balistes_engine:evaluate_step`.
-- |
-- | Live mutation = refire the cell with a new BalistesConfig.  The
-- | walker registers the new config under the same alias; the voice's
-- | per-step query reads the latest value.
module Tidal.Balistes
  ( Balistes(..)
  , BalistesConfig
  , BalistesSnapshot
  , balistes
  , balistesWith
  , balistesConfig
  , evaluateParamsAt
  , evaluateParamsAtControls
  , buildControlMap
  , mkStaticBalistesConfig
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
-- BalistesConfig — seven Pattern Int slots
-- ---------------------------------------------------------------------------

-- | All seven Balistes parameters as Pattern Int slots.  Static values
-- | are `pure n`; patterned values come from mini-notation or
-- | combinators (`sine # range 0 255 # slow 4` etc.).
type BalistesConfig =
  { x          :: Pattern Int
  , y          :: Pattern Int
  , fillBd     :: Pattern Int
  , fillSd     :: Pattern Int
  , fillHh     :: Pattern Int
  , randomness :: Pattern Int
  , mode       :: Pattern Int
  }

-- | Snapshot returned by `evaluateParamsAt`.  Field order doesn't
-- | matter — the Erlang voice reads by key.
type BalistesSnapshot =
  { x          :: Int
  , y          :: Int
  , fillBd     :: Int
  , fillSd     :: Int
  , fillHh     :: Int
  , randomness :: Int
  , mode       :: Int
  }

-- | Sensible defaults: central node in the 5×5, moderate density,
-- | no randomness, Drums mode.  Users override fields they care
-- | about: `balistesConfig { fillBd = pure 200 }`.
balistesConfig :: BalistesConfig
balistesConfig =
  { x          : pure 128
  , y          : pure 128
  , fillBd     : pure 128
  , fillSd     : pure 128
  , fillHh     : pure 128
  , randomness : pure 0
  , mode       : pure 0
  }

-- ---------------------------------------------------------------------------
-- The typed binding
-- ---------------------------------------------------------------------------

-- | A typed Balistes voice declared at the Session level.  The Symbol
-- | parameter is decorative — the walker reads the alias from the
-- | binding name (consistent with PolySignal and Instrument).
data Balistes (s :: Symbol)
  = BalistesBinding
      { device     :: MidiDevice
      , channel    :: Int
      , noteBd     :: Int
      , noteSd     :: Int
      , noteHh     :: Int
      , vel        :: Int
      , velAccent  :: Int
      , durMs      :: Int
      , config     :: BalistesConfig
      }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

-- | Build a Balistes binding with system-default note numbers (BD=36,
-- | SD=38, HH=42) and velocities (90 normal, 127 accent), 30 ms note
-- | length.
balistes
  :: forall s
   . MidiDevice
  -> Int          -- ^ MIDI channel 1..16
  -> BalistesConfig
  -> Balistes s
balistes dev ch cfg = BalistesBinding
  { device: dev
  , channel: ch
  , noteBd: 36
  , noteSd: 38
  , noteHh: 42
  , vel: 90
  , velAccent: 127
  , durMs: 30
  , config: cfg
  }

-- | Like `balistes` but with explicit per-instrument MIDI notes — useful
-- | when the rig's FH-2 routing has BD/SD/HH on non-standard MCV
-- | channels.
balistesWith
  :: forall s
   . { device :: MidiDevice
     , channel :: Int
     , noteBd :: Int, noteSd :: Int, noteHh :: Int
     , vel :: Int, velAccent :: Int
     , durMs :: Int
     , config :: BalistesConfig
     }
  -> Balistes s
balistesWith = BalistesBinding

-- ---------------------------------------------------------------------------
-- Per-step parameter evaluation (called from Erlang)
-- ---------------------------------------------------------------------------

-- | Evaluate each of the seven Pattern Int slots at a given cycle
-- | position, using the live control snapshot from the tick window
-- | so `liveIntOr "name"` slots read their current values.  Called
-- | by `balistes_voice` once per 32-step tick.
-- |
-- | The query arc is `[pos, pos + 1/32)` — exactly one Balistes step.
evaluateParamsAt
  :: BalistesConfig
  -> Array { name :: String, value :: Number }
  -> Number
  -> BalistesSnapshot
evaluateParamsAt cfg controlPairs pos =
  evaluateParamsAtControls cfg (pairsToControlMap controlPairs) pos

-- | F1 cache-friendly evaluator: takes a pre-built `ControlMap` so the
-- | voice gen_server can hold it across ticks and only rebuild when the
-- | control bus's version counter changes.  See the odonus_voice F1
-- | implementation and `tools/timing-data/phase-4-diagnostic-f1/`.
evaluateParamsAtControls
  :: BalistesConfig
  -> ControlMap
  -> Number
  -> BalistesSnapshot
evaluateParamsAtControls cfg controls pos =
  { x          : sampleAt controls 128 cfg.x          pos
  , y          : sampleAt controls 128 cfg.y          pos
  , fillBd     : sampleAt controls 128 cfg.fillBd     pos
  , fillSd     : sampleAt controls 128 cfg.fillSd     pos
  , fillHh     : sampleAt controls 128 cfg.fillHh     pos
  , randomness : sampleAt controls 0   cfg.randomness pos
  , mode       : sampleAt controls 0   cfg.mode       pos
  }

-- | F1 — Erlang-side entry point: build the opaque PureScript
-- | ControlMap once per control-bus version, reuse across steps.
buildControlMap
  :: Array { name :: String, value :: Number }
  -> ControlMap
buildControlMap = pairsToControlMap

sampleAt :: ControlMap -> Int -> Pattern Int -> Number -> Int
sampleAt controls dflt pat at =
  let arc0 = fromInt (truncTo32nd at)
      -- Quantise the query window onto 32nd-of-a-cycle boundaries so
      -- adjacent Balistes steps land in disjoint arcs.  Truncation, not
      -- rounding — step 5 should query [5/32, 6/32) regardless of
      -- floating-point slop in the timestamp we were handed.
      arc1 = fromInt (truncTo32nd at + 1)
      slice = queryArcWith controls pat
                (arc0 / fromInt 32)
                (arc1 / fromInt 32)
  in case Array.head slice of
       Just (Digital e) -> e.value
       Just (Analog e)  -> e.value
       Nothing -> dflt

-- | Build a ControlMap from the tick window's control snapshot.
-- | Mirrors `Tidal.Voice.pairsToControlMap` (kept local to avoid
-- | pulling Voice's full machinery into the Balistes module).
pairsToControlMap
  :: Array { name :: String, value :: Number }
  -> ControlMap
pairsToControlMap pairs =
  foldl (\m p -> Map.insert p.name (VNumber p.value) m) Map.empty pairs

-- | Build a BalistesConfig from seven flat Ints — the wire-frame entry
-- | point for the cell-text `balistes` declaration.  Each slot becomes
-- | `pure n`.  For dynamic patterns the user should declare in
-- | Studio.purs with `liveIntOr` or richer Pattern expressions.
mkStaticBalistesConfig
  :: Int -> Int -> Int -> Int -> Int -> Int -> Int -> BalistesConfig
mkStaticBalistesConfig x y fBd fSd fHh r m =
  { x: pure x
  , y: pure y
  , fillBd: pure fBd
  , fillSd: pure fSd
  , fillHh: pure fHh
  , randomness: pure r
  , mode: pure m
  }

truncTo32nd :: Number -> Int
truncTo32nd n = floorN (n * 32.0)

-- Floor for Numbers — purs-backend-erl maps via Math.floor.
foreign import floorN :: Number -> Int
