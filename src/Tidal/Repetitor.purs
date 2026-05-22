-- | Tidal.Repetitor — typed Session-level binding for the BEAM-native
-- | Zularic-Repetitor-inspired virtual module.  Sibling of
-- | Tidal.Balistes; second member of the vmod family per memory
-- | `project_beam_native_virtual_modules`.
-- |
-- | Engine: 14 named African / Indian / Caribbean rhythm patterns,
-- | each four parallel bit-arrays of equal length (M, C1, C2, C3).
-- | Each row is phase-shifted by a per-row offset (knob equivalent).
-- | At zero offsets, reproduces the patterns printed in the ZR manual.
-- | Offset semantics confirmed against rig MIDI capture 2026-05-19 —
-- | hits stay locked to M-cycle boundaries, no drift / polyrhythm-
-- | from-shortening; offset shifts each row's own pattern.
-- |
-- | A typed Session-level binding looks like:
-- |
-- |     kit :: Repetitor "kit"
-- |     kit = repetitor fh2qd 10 "zr_african" "King 1"
-- |
-- | …or with offsets:
-- |
-- |     kit = (repetitor fh2qd 10 "zr_african" "King 1")
-- |       { config { offsetC1 = pure 5, offsetC2 = pure 3 } }
-- |
-- | All four offset slots are `Pattern Int`.  Static values are
-- | `pure n`; live-coded values use mini-notation (`mini "<0 3 5>"`),
-- | the live-control bus (`liveIntOr "c1off" 0`), or composed patterns.
-- | The walker classifies the value by constructor tag, ships a
-- | `RegisterRepetitor` event with the opaque config Foreign payload
-- | to the Erlang shell, which spawns a `repetitor_voice` gen_server.
-- | Per step (default 4 steps per cycle = one step per beat in 4/4),
-- | the voice calls back into PureScript via `evaluateParamsAt` to
-- | query each pattern at the step's cycle position, then hands the
-- | four Ints to `repetitor_engine:evaluate_step`.
-- |
-- | Live mutation = refire the cell with new offsets.  The walker
-- | re-registers under the same alias; the voice's per-step query
-- | reads the latest value.  Same `liveIntOr` plumbing as Balistes.
module Tidal.Repetitor
  ( Repetitor(..)
  , RepetitorConfig
  , RepetitorSnapshot
  , repetitor
  , repetitorWith
  , repetitorConfig
  , evaluateParamsAt
  , evaluateParamsAtControls
  , buildControlMap
  , mkStaticRepetitorConfig
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
-- RepetitorConfig — four Pattern Int slots
-- ---------------------------------------------------------------------------

-- | The four offset slots (one per row), each a Pattern Int.
-- | Static values are `pure n`; patterned/live values use
-- | mini-notation, `liveIntOr`, or `sine # range 0 11 # slow 4`.
type RepetitorConfig =
  { offsetM  :: Pattern Int
  , offsetC1 :: Pattern Int
  , offsetC2 :: Pattern Int
  , offsetC3 :: Pattern Int
  }

-- | Per-step snapshot read out by the Erlang voice.  Field names
-- | match `RepetitorConfig`'s slot names so the FFI layer can pull
-- | values out by atom key.
type RepetitorSnapshot =
  { offsetM  :: Int
  , offsetC1 :: Int
  , offsetC2 :: Int
  , offsetC3 :: Int
  }

-- | All offsets default to 0 — reproduces the printed manual pattern
-- | at the manual's default knob positions.
repetitorConfig :: RepetitorConfig
repetitorConfig =
  { offsetM:  pure 0
  , offsetC1: pure 0
  , offsetC2: pure 0
  , offsetC3: pure 0
  }

-- ---------------------------------------------------------------------------
-- The typed binding
-- ---------------------------------------------------------------------------

-- | A typed Repetitor voice declared at the Session level.  Symbol
-- | parameter is decorative — walker reads the alias from the binding
-- | name (matches Selene, Instrument, Balistes).
data Repetitor (s :: Symbol)
  = RepetitorBinding
      { device        :: MidiDevice
      , channel       :: Int
      , noteM         :: Int
      , noteC1        :: Int
      , noteC2        :: Int
      , noteC3        :: Int
      , vel           :: Int
      , durMs         :: Int
      , stepsPerCycle :: Int    -- 4 = one step per beat in 4/4
      , library       :: String -- e.g. "zr_african"
      , patternSlug   :: String -- e.g. "King 1" (case-insensitive lookup)
      , config        :: RepetitorConfig
      }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

-- | Build a Repetitor binding with sensible defaults: standard drum
-- | note numbers (36/38/40/41 — matches our rig measurement
-- | mapping), velocity 100, 30 ms note, 4 steps per cycle, all
-- | offsets zero.
repetitor
  :: forall s
   . MidiDevice
  -> Int        -- ^ MIDI channel 1..16
  -> String     -- ^ library name, e.g. "zr_african"
  -> String     -- ^ pattern name, e.g. "King 1"
  -> Repetitor s
repetitor dev ch lib slug = RepetitorBinding
  { device: dev
  , channel: ch
  , noteM:  36
  , noteC1: 38
  , noteC2: 40
  , noteC3: 41
  , vel: 100
  , durMs: 30
  , stepsPerCycle: 4
  , library: lib
  , patternSlug: slug
  , config: repetitorConfig
  }

-- | Like `repetitor` but fully explicit — handy when several rigs
-- | use non-standard drum note mappings.
repetitorWith
  :: forall s
   . { device :: MidiDevice
     , channel :: Int
     , noteM :: Int, noteC1 :: Int, noteC2 :: Int, noteC3 :: Int
     , vel :: Int, durMs :: Int
     , stepsPerCycle :: Int
     , library :: String, patternSlug :: String
     , config :: RepetitorConfig
     }
  -> Repetitor s
repetitorWith = RepetitorBinding

-- ---------------------------------------------------------------------------
-- Per-step parameter evaluation (called from Erlang)
-- ---------------------------------------------------------------------------

-- | Evaluate each of the four offset slots at a given cycle position,
-- | using the live control snapshot from the tick window so
-- | `liveIntOr "name"` slots read their current values.  Called by
-- | `repetitor_voice` per step.  Mirror of `Tidal.Balistes.evaluateParamsAt`.
evaluateParamsAt
  :: RepetitorConfig
  -> Array { name :: String, value :: Number }
  -> Number
  -> RepetitorSnapshot
evaluateParamsAt cfg controlPairs pos =
  evaluateParamsAtControls cfg (pairsToControlMap controlPairs) pos

-- | F1 cache-friendly evaluator: takes a pre-built `ControlMap` so the
-- | voice gen_server can hold it across ticks and only rebuild when the
-- | control bus's version counter changes.  Mirror of
-- | `Tidal.Odonus.evaluateParamsAtControls`.
evaluateParamsAtControls
  :: RepetitorConfig
  -> ControlMap
  -> Number
  -> RepetitorSnapshot
evaluateParamsAtControls cfg controls pos =
  { offsetM:  sampleAt controls 0 cfg.offsetM  pos
  , offsetC1: sampleAt controls 0 cfg.offsetC1 pos
  , offsetC2: sampleAt controls 0 cfg.offsetC2 pos
  , offsetC3: sampleAt controls 0 cfg.offsetC3 pos
  }

-- | F1 — Erlang-side entry point for the ControlMap cache.
buildControlMap
  :: Array { name :: String, value :: Number }
  -> ControlMap
buildControlMap = pairsToControlMap

sampleAt :: ControlMap -> Int -> Pattern Int -> Number -> Int
sampleAt controls dflt pat at =
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

-- | Build a RepetitorConfig from four flat Ints — the wire-frame
-- | entry point if the cell-text language ever wants to declare
-- | offsets inline.  Each slot becomes `pure n`.
mkStaticRepetitorConfig :: Int -> Int -> Int -> Int -> RepetitorConfig
mkStaticRepetitorConfig m c1 c2 c3 =
  { offsetM:  pure m
  , offsetC1: pure c1
  , offsetC2: pure c2
  , offsetC3: pure c3
  }

truncTo16th :: Number -> Int
truncTo16th n = floorN (n * 16.0)

-- Floor for Numbers — purs-backend-erl maps via Math.floor.
foreign import floorN :: Number -> Int
