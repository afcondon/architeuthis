-- | Tidal.VirtualPolySignal — pure evaluator for polysignal values
-- | targeting a `Virtual` bank.
-- |
-- | The voice gen_server (`virtual_polysignal_voice.erl`) holds the
-- | typed PolySignal value as opaque Foreign and calls
-- | `evaluateAt(value, cyclePos)` per clock tick.  The result is a
-- | flat `Array { index :: Int, value :: Number }` — one entry per
-- | active slot — which the voice writes to the live-control bus at
-- | `<busPrefix>.<index>`.
-- |
-- | Output convention: values land in the 0..255 controller range
-- | so vmod parameter slots (`liveIntOr 128 "lfoBank.0"`,
-- | `gridsConfig.x`, René notes, etc.) pick them up without a
-- | scaling step on the cell-text side.  An LFO's natural -1..+1
-- | swing is mapped to 0..255 here; clock / euclid gates write
-- | 0 (off) or 127 (on).  The OutputRange field of the PolySignal
-- | is ignored on the virtual path — it's an FH-2 firmware concept
-- | that doesn't translate to integer-valued control-bus slots.
-- |
-- | Implemented families (MVP): LFO, Clock, Euclid.  Env / Rand /
-- | Preset / PresetNote are returned as empty arrays for now (the
-- | voice logs once and moves on).  Adding a family is one new
-- | clause in `evaluateAt` plus its slot evaluator.
module Tidal.VirtualPolySignal
  ( evaluateAt
  , Output
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Math as Math
import Tidal.PolySignal
  ( PolySignal(..)
  , ClockSlot
  , EuclidSlot
  , LfoSlot
  , LfoWave(..)
  , ClockBase(..)
  )

-- | One output sample destined for a single bus key.  The voice
-- | writes `<busPrefix>.<index>` ← `value`.  Index is 0-based.
type Output = { index :: Int, value :: Number }

-- | Evaluate a virtual polysignal at the given cycle position
-- | (cycles, not seconds).  Returns one Output per active slot.
evaluateAt :: forall s. PolySignal s -> Number -> Array Output
evaluateAt polysig pos = case polysig of
  PolyLfoConfig    cfg -> evaluateLfo    cfg.slots pos
  PolyClockConfig  cfg -> evaluateClock  cfg.slots pos
  PolyEuclidConfig cfg -> evaluateEuclid cfg.slots pos
  -- The remaining families are valid surface but unimplemented on
  -- the virtual side at MVP.  Empty array → bus keys are not
  -- written, vmods fall through to their `liveIntOr` defaults.
  PolyEnvConfig         _ -> []
  PolyRandConfig        _ -> []
  PolyPresetConfig      _ -> []
  PolyPresetNoteConfig  _ -> []

-- ---------------------------------------------------------------------------
-- LFO
-- ---------------------------------------------------------------------------

-- | Each slot's instantaneous value at `pos`, scaled to 0..255.
-- | `ratio` is cycles-per-cycle: 1.0 = one full LFO per Tidal cycle,
-- | 0.5 = half-speed, 2.0 = double-speed.  Negative or zero ratios
-- | are clamped to 1.0 to avoid divide-by-zero / static output.
evaluateLfo :: Array LfoSlot -> Number -> Array Output
evaluateLfo slots pos = Array.mapWithIndex sample slots
  where
  sample i slot =
    let
      r = if slot.ratio <= 0.0 then 1.0 else slot.ratio
      phase = fracPart (pos * r)
      raw = lfoWaveValue slot.shape phase  -- -1..+1
      v = (raw + 1.0) * 127.5              -- 0..255
    in
      { index: i, value: v }

-- | Sample a waveform at unit phase (0..1).  All shapes return
-- | values in [-1, +1] except `LfoRnd` (stepped sample-and-hold —
-- | not implemented at MVP, returns 0) and `LfoNse` (white noise —
-- | not implemented at MVP, returns 0).
lfoWaveValue :: LfoWave -> Number -> Number
lfoWaveValue shape phase = case shape of
  LfoSin -> Math.sin (2.0 * Math.pi * phase)
  LfoSqr -> if phase < 0.5 then 1.0 else -1.0
  LfoTri -> 4.0 * absNumber (phase - 0.5) - 1.0
  LfoSaw -> 2.0 * phase - 1.0
  LfoRnd -> 0.0
  LfoNse -> 0.0

-- ---------------------------------------------------------------------------
-- Clock
-- ---------------------------------------------------------------------------

-- | Each slot is a clock-pulse train.  We compute `pulsesPerCycle`
-- | from `base × multiplier`, then a pulse fires (0..127) when the
-- | current sub-step's phase is within `pulseWidth / 16` of its
-- | start.  `phase` lets the user offset the pulse origin.
evaluateClock :: Array ClockSlot -> Number -> Array Output
evaluateClock slots pos = Array.mapWithIndex sample slots
  where
  sample i slot =
    let
      pulsesPerCycle = clockBaseRate slot.base
        * Int.toNumber (max 1 slot.multiplier)
      phaseOffset = Int.toNumber slot.phase / 16.0
      cycleStep = fracPart (pos * pulsesPerCycle + phaseOffset)
      width = clamp01 (Int.toNumber slot.pulseWidth / 16.0)
      v = if cycleStep < width then 127.0 else 0.0
    in
      { index: i, value: v }

-- | How many of this base unit fit in one Tidal cycle.  Whole = 1
-- | per cycle, quarter = 4, sixteenth = 16, etc.  Triplet forms are
-- | 1.5× the straight rate.
clockBaseRate :: ClockBase -> Number
clockBaseRate = case _ of
  ClockWhole         -> 1.0
  ClockHalf          -> 2.0
  ClockQuarter       -> 4.0
  ClockQuarterT      -> 6.0
  ClockEighth        -> 8.0
  ClockEighthT       -> 12.0
  ClockSixteenth     -> 16.0
  ClockSixteenthT    -> 24.0
  ClockThirtySecond  -> 32.0
  ClockThirtySecondT -> 48.0
  ClockSixtyFourthT  -> 96.0

-- ---------------------------------------------------------------------------
-- Euclid
-- ---------------------------------------------------------------------------

-- | Euclidean rhythm gate output.  `steps` total positions per
-- | `rate` cycles, `beats` of those positions fire (using Bjorklund-
-- | style even distribution).  `accentRate` fires every Nth beat as
-- | a 127, others as 64.  Output is 0 / 64 / 127.
evaluateEuclid :: Array EuclidSlot -> Number -> Array Output
evaluateEuclid slots pos = Array.mapWithIndex sample slots
  where
  sample i slot =
    let
      stepsN = max 1 slot.steps
      beatsN = max 0 (min stepsN slot.beats)
      rateN = max 1 slot.rate
      cycleStep = fracPart (pos / Int.toNumber rateN)
      stepIx = Int.floor (cycleStep * Int.toNumber stepsN)
      onThisStep = euclideanOn stepsN beatsN stepIx
      v = if not onThisStep then 0.0
          else
            let
              accentN = max 1 slot.accentRate
              beatOrdinal = countBeatsBefore stepsN beatsN stepIx
            in
              if beatOrdinal `mod` accentN == 0 then 127.0 else 64.0
    in
      { index: i, value: v }

-- | Bjorklund-style: step `k` of `steps` is "on" iff
-- | `floor(k * beats / steps) /= floor((k - 1) * beats / steps)`.
-- | Cheap and well-known; matches what every modular Euclid module
-- | does up to phase choice.
euclideanOn :: Int -> Int -> Int -> Boolean
euclideanOn steps beats step =
  if beats <= 0 then false
  else if beats >= steps then true
  else
    let
      a = (step * beats) `div` steps
      b = ((step - 1 + steps) `mod` steps * beats) `div` steps
    in
      a /= b && step >= 0

-- | How many beats have fired before this step (used for accent
-- | ordinal — every Nth beat gets the accent value).
countBeatsBefore :: Int -> Int -> Int -> Int
countBeatsBefore steps beats step =
  Array.length
    (Array.filter (euclideanOn steps beats)
      (Array.range 0 (step - 1)))

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

fracPart :: Number -> Number
fracPart x = x - Math.floor x

absNumber :: Number -> Number
absNumber x = if x < 0.0 then -x else x

clamp01 :: Number -> Number
clamp01 x = if x < 0.0 then 0.0 else if x > 1.0 then 1.0 else x
