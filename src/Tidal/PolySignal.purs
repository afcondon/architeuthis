-- | Tidal.PolySignal — typed polysignals as first-class Session
-- | bindings.  Slab C steps 1 & 2 (2026-05-18).
-- |
-- | A polysignal is an autonomous, multi-output configuration installed
-- | on an FH-2 bank — an LFO bank, a clock-bus, an ADSR cluster, a
-- | euclidean rhythm machine, etc.  It is *not* a Part (no event
-- | stream) and *not* an Instrument (no pitch/CV emission per beat).
-- | It's a third notation alongside Tidal mini-patterns: a declarative
-- | musical specification of standing-wave control behaviour.
-- |
-- | A typed Session-level binding looks like:
-- |
-- |     testLfo :: PolySignal "testLfo"
-- |     testLfo = polyLfo BankMain
-- |       [ { ratio: 1.0, shape: LfoTri }, …8 slots… ]
-- |       (Just Bipolar5V)
-- |
-- | The Symbol parameter is decorative — the walker derives the alias
-- | from the binding name (`testLfo` here).  Keeping it in the type
-- | makes the intended alias visible at the type-level boundary and
-- | leaves room for a future binding-name === Symbol checker.
-- |
-- | The walker classifies the value by constructor tag, builds the
-- | JSON envelope (same shape as Calypso's cell-text
-- | `polySignalEnvelopeJson`), and emits a `RegisterPolySignal` event.
-- | The Erlang side hands the envelope verbatim to fh2-daemon via
-- | `fh2_daemon_call`, which puts it through `Rig.applyWithClaims` —
-- | the unified port-claims layer from `project_port_claims_design`.
-- |
-- | The seven families:
-- |   PolyLfoConfig         — eight LFOs (sin/sqr/tri/saw/rnd/nse × ratio)
-- |   PolyClockConfig       — eight clock-pulse trains (base × multiplier
-- |                           × pulseWidth × phase)
-- |   PolyEnvConfig         — eight ADSR envelopes (attack/decay/sustain/
-- |                           release plus shape and depth)
-- |   PolyEuclidConfig      — eight euclidean rhythms (beats/steps/rate)
-- |   PolyRandConfig        — eight random-walk CV outputs
-- |   PolyPresetConfig      — eight fixed voltages (literal volts per slot)
-- |   PolyPresetNoteConfig  — eight fixed pitches (MIDI note number per
-- |                           slot, converted to V/oct by the daemon)
-- |
-- | The last two are the "simplest of all" — they put a known reference
-- | voltage (or pitch) on each claimed CV output and leave it there.
-- | Useful for calibration, drone bedrock, or as a static counterweight
-- | to other polysignals.
module Tidal.PolySignal
  ( PolySignal(..)
  , OutputRange(..)
  , Bank(..)
  , LfoWave(..)
  , ClockBase(..)
  , RandDirection(..)
  , RandScale(..)
  , RandKey(..)
  , LfoSlot
  , ClockSlot
  , EnvSlot
  , EuclidSlot
  , RandSlot
  , PresetSlot
  , PresetNoteSlot
  , polyLfo
  , polyClock
  , polyEnv
  , polyEuclid
  , polyRand
  , polyPreset
  , polyPresetNote
  , polySignalAsJson
  , polySignalFamily
  , bankToWire
  , rangeToWire
  , lfoWaveToWire
  , clockBaseToWire
  , randDirectionToWire
  , randScaleToWire
  , randKeyToWire
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String as Str

-- ---------------------------------------------------------------------------
-- Output range (mirrors FH2.OutputRange)
-- ---------------------------------------------------------------------------

data OutputRange
  = Unipolar10V
  | Bipolar5V
  | Unipolar1V
  | Unipolar5V
  | Unipolar8V

derive instance eqOutputRange :: Eq OutputRange

rangeToWire :: OutputRange -> String
rangeToWire = case _ of
  Unipolar10V -> "unipolar10v"
  Bipolar5V   -> "bipolar5v"
  Unipolar1V  -> "unipolar1v"
  Unipolar5V  -> "unipolar5v"
  Unipolar8V  -> "unipolar8v"

-- ---------------------------------------------------------------------------
-- Bank — names a target jack-bank on FH-2 + expanders (mirrors FH2.Roles.Bank)
-- ---------------------------------------------------------------------------

data Bank
  = BankMain
  | BankCv Int   -- FHX-8CV expander, indices 0..6
  | BankGt Int   -- FHX-8GT expander, indices 0..7

derive instance eqBank :: Eq Bank

bankToWire :: Bank -> String
bankToWire = case _ of
  BankMain -> "main"
  BankCv n -> "cv" <> show n
  BankGt n -> "gt" <> show n

-- ---------------------------------------------------------------------------
-- LFO waveform + slot
-- ---------------------------------------------------------------------------

data LfoWave
  = LfoSin
  | LfoSqr
  | LfoTri
  | LfoSaw
  | LfoRnd
  | LfoNse

derive instance eqLfoWave :: Eq LfoWave

lfoWaveToWire :: LfoWave -> String
lfoWaveToWire = case _ of
  LfoSin -> "sin"
  LfoSqr -> "sqr"
  LfoTri -> "tri"
  LfoSaw -> "saw"
  LfoRnd -> "rnd"
  LfoNse -> "nse"

-- | A single LFO output slot.  Wire-format field name is `shape`
-- | (the FH-2 firmware term, kept here for symmetry with the daemon's
-- | slot parser — see `FH2/PolyBank.purs` `assertKnownKeys` for the
-- | authoritative set).
type LfoSlot =
  { ratio :: Number
  , shape :: LfoWave
  }

-- ---------------------------------------------------------------------------
-- Clock-pulse base duration + slot
-- ---------------------------------------------------------------------------

-- | The musical base duration each slot's clock divides.  Wire-format
-- | tokens are short — `whole`, `qt` (quarter-triplet), `8th`, `8t`,
-- | `16th`, `16t`, etc. — chosen for readability on a single line.
data ClockBase
  = ClockWhole
  | ClockHalf
  | ClockQuarter
  | ClockQuarterT
  | ClockEighth
  | ClockEighthT
  | ClockSixteenth
  | ClockSixteenthT
  | ClockThirtySecond
  | ClockThirtySecondT
  | ClockSixtyFourthT

derive instance eqClockBase :: Eq ClockBase

clockBaseToWire :: ClockBase -> String
clockBaseToWire = case _ of
  ClockWhole         -> "whole"
  ClockHalf          -> "half"
  ClockQuarter       -> "quarter"
  ClockQuarterT      -> "qt"
  ClockEighth        -> "8th"
  ClockEighthT       -> "8t"
  ClockSixteenth     -> "16th"
  ClockSixteenthT    -> "16t"
  ClockThirtySecond  -> "32nd"
  ClockThirtySecondT -> "32t"
  ClockSixtyFourthT  -> "64t"

-- | A single clock-bus output slot.  Wire field names match the
-- | daemon's slot parser (`pulseWidth`/`phase` are the user-friendly
-- | names; firmware calls them `length`/`shift`).
type ClockSlot =
  { base :: ClockBase
  , multiplier :: Int
  , pulseWidth :: Int
  , phase :: Int
  }

-- ---------------------------------------------------------------------------
-- Envelope slot — ADSR + shape + range
-- ---------------------------------------------------------------------------

-- | A single envelope output slot.  All fields are Ints in firmware
-- | encoding — attack/decay/release are 0..16383 (14-bit time), sustain
-- | is 0..16383 (14-bit level), shape fields are 0..6 (curve index),
-- | randomDepth is 0..127.
type EnvSlot =
  { attack :: Int
  , decay :: Int
  , sustain :: Int
  , release :: Int
  , attackShape :: Int
  , decayShape :: Int
  , releaseShape :: Int
  , randomDepth :: Int
  , range :: Maybe OutputRange
  }

-- ---------------------------------------------------------------------------
-- Euclidean rhythm slot
-- ---------------------------------------------------------------------------

-- | A single euclidean-rhythm output slot.  Wire-format `beats` (the
-- | Tidal-friendly term) maps to firmware `pulses`.
type EuclidSlot =
  { beats :: Int       -- 1..steps
  , steps :: Int       -- 1..32
  , rate :: Int        -- subdivision rate
  , accentRate :: Int  -- accent every Nth pulse
  }

-- ---------------------------------------------------------------------------
-- Random-walk slot — direction + length + scale + key + …
-- ---------------------------------------------------------------------------

data RandDirection
  = DirStop
  | DirFwd
  | DirBwd

derive instance eqRandDirection :: Eq RandDirection

randDirectionToWire :: RandDirection -> String
randDirectionToWire = case _ of
  DirStop -> "stop"
  DirFwd  -> "fwd"
  DirBwd  -> "bwd"

-- | Scale-quantisation for the random walk output.  Firmware supports
-- | 19 scales; only the most common five are named tokens, the rest
-- | go via raw Int (see `RandScaleRaw`).
data RandScale
  = ScaleUnquantized
  | ScaleChromatic
  | ScaleMajor
  | ScaleMinor
  | ScaleTriad
  | ScaleRaw Int

derive instance eqRandScale :: Eq RandScale

randScaleToWire :: RandScale -> String
randScaleToWire = case _ of
  ScaleUnquantized -> "unq"
  ScaleChromatic   -> "chromatic"
  ScaleMajor       -> "major"
  ScaleMinor       -> "minor"
  ScaleTriad       -> "triad"
  ScaleRaw n       -> show n

data RandKey
  = KeyC | KeyCs | KeyD | KeyDs | KeyE | KeyF
  | KeyFs | KeyG | KeyGs | KeyA | KeyAs | KeyB

derive instance eqRandKey :: Eq RandKey

randKeyToWire :: RandKey -> String
randKeyToWire = case _ of
  KeyC  -> "c"
  KeyCs -> "c#"
  KeyD  -> "d"
  KeyDs -> "d#"
  KeyE  -> "e"
  KeyF  -> "f"
  KeyFs -> "f#"
  KeyG  -> "g"
  KeyGs -> "g#"
  KeyA  -> "a"
  KeyAs -> "a#"
  KeyB  -> "b"

type RandSlot =
  { direction :: RandDirection
  , length :: Int
  , randomness :: Int
  , rate :: Int
  , attenuator :: Int
  , scale :: RandScale
  , key :: RandKey
  , gateLength :: Int
  , range :: Maybe OutputRange
  }

-- ---------------------------------------------------------------------------
-- Preset slots — fixed voltages on the bank's outputs
-- ---------------------------------------------------------------------------

-- | A fixed voltage on a single CV output.  The daemon interprets
-- | `value` in volts, maps to the FH-2's 14-bit directLevel based on
-- | the envelope's `outputRange` (clamped to that range).  Use this
-- | for drone bedrock, calibration references, or a static
-- | counterweight to other polysignals on the same bank.
type PresetSlot =
  { value :: Number  -- volts
  }

-- | A fixed MIDI pitch on a single CV output (V/oct).  The daemon
-- | converts `note` to voltage via the conventional 1V/octave mapping
-- | with note 12 (C0) = 0V (so note 60 = 4V, fits unipolar 0-10V or
-- | bipolar ±5V comfortably).
type PresetNoteSlot =
  { note :: Int  -- MIDI 0..127
  }

-- ---------------------------------------------------------------------------
-- PolySignal sum
-- ---------------------------------------------------------------------------

data PolySignal (s :: Symbol)
  = PolyLfoConfig
      { bank :: Bank
      , slots :: Array LfoSlot
      , range :: Maybe OutputRange
      }
  | PolyClockConfig
      { bank :: Bank
      , slots :: Array ClockSlot
      , range :: Maybe OutputRange
      }
  | PolyEnvConfig
      { bank :: Bank
      , slots :: Array EnvSlot
      , range :: Maybe OutputRange
      }
  | PolyEuclidConfig
      { bank :: Bank
      , slots :: Array EuclidSlot
      , range :: Maybe OutputRange
      }
  | PolyRandConfig
      { bank :: Bank
      , slots :: Array RandSlot
      , range :: Maybe OutputRange
      }
  | PolyPresetConfig
      { bank :: Bank
      , slots :: Array PresetSlot
      , range :: Maybe OutputRange
      }
  | PolyPresetNoteConfig
      { bank :: Bank
      , slots :: Array PresetNoteSlot
      , range :: Maybe OutputRange
      }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

polyLfo
  :: forall s
   . Bank -> Array LfoSlot -> Maybe OutputRange -> PolySignal s
polyLfo bank slots range = PolyLfoConfig { bank, slots, range }

polyClock
  :: forall s
   . Bank -> Array ClockSlot -> Maybe OutputRange -> PolySignal s
polyClock bank slots range = PolyClockConfig { bank, slots, range }

polyEnv
  :: forall s
   . Bank -> Array EnvSlot -> Maybe OutputRange -> PolySignal s
polyEnv bank slots range = PolyEnvConfig { bank, slots, range }

polyEuclid
  :: forall s
   . Bank -> Array EuclidSlot -> Maybe OutputRange -> PolySignal s
polyEuclid bank slots range = PolyEuclidConfig { bank, slots, range }

polyRand
  :: forall s
   . Bank -> Array RandSlot -> Maybe OutputRange -> PolySignal s
polyRand bank slots range = PolyRandConfig { bank, slots, range }

polyPreset
  :: forall s
   . Bank -> Array PresetSlot -> Maybe OutputRange -> PolySignal s
polyPreset bank slots range = PolyPresetConfig { bank, slots, range }

polyPresetNote
  :: forall s
   . Bank -> Array PresetNoteSlot -> Maybe OutputRange -> PolySignal s
polyPresetNote bank slots range = PolyPresetNoteConfig { bank, slots, range }

-- ---------------------------------------------------------------------------
-- JSON envelope projection
-- ---------------------------------------------------------------------------

-- | The family name for a typed PolySignal value — same string the
-- | daemon's wire parser dispatches on (`polylfo`, `polyclock`, …).
polySignalFamily :: forall s. PolySignal s -> String
polySignalFamily = case _ of
  PolyLfoConfig _         -> "polylfo"
  PolyClockConfig _       -> "polyclock"
  PolyEnvConfig _         -> "polyenv"
  PolyEuclidConfig _      -> "polyeuclid"
  PolyRandConfig _        -> "polyrand"
  PolyPresetConfig _      -> "polypreset"
  PolyPresetNoteConfig _  -> "polypresetnote"

-- | Project a PolySignal to the JSON envelope the daemon expects.
-- | The alias argument carries the binding name (resolved by the
-- | walker from `enumerateExports`).
polySignalAsJson :: forall s. String -> PolySignal s -> String
polySignalAsJson alias = case _ of
  PolyLfoConfig cfg ->
    envelope "polylfo" cfg.bank alias cfg.range
      (map lfoSlotJson cfg.slots)
  PolyClockConfig cfg ->
    envelope "polyclock" cfg.bank alias cfg.range
      (map clockSlotJson cfg.slots)
  PolyEnvConfig cfg ->
    envelope "polyenv" cfg.bank alias cfg.range
      (map envSlotJson cfg.slots)
  PolyEuclidConfig cfg ->
    envelope "polyeuclid" cfg.bank alias cfg.range
      (map euclidSlotJson cfg.slots)
  PolyRandConfig cfg ->
    envelope "polyrand" cfg.bank alias cfg.range
      (map randSlotJson cfg.slots)
  PolyPresetConfig cfg ->
    envelope "polypreset" cfg.bank alias cfg.range
      (map presetSlotJson cfg.slots)
  PolyPresetNoteConfig cfg ->
    envelope "polypresetnote" cfg.bank alias cfg.range
      (map presetNoteSlotJson cfg.slots)

-- | Shared envelope frame.  Slot JSON is family-specific; everything
-- | around it is uniform.
envelope :: String -> Bank -> String -> Maybe OutputRange -> Array String -> String
envelope family bank alias range slotJsons =
  "{\"bank\":\"" <> bankToWire bank
    <> "\",\"family\":\"" <> family
    <> "\",\"alias\":\"" <> alias
    <> "\"" <> rangeField range
    <> ",\"slots\":[" <> Str.joinWith "," slotJsons <> "]}"
  where
  rangeField = case _ of
    Nothing -> ""
    Just r  -> ",\"outputRange\":\"" <> rangeToWire r <> "\""

-- Per-family slot serialisers

lfoSlotJson :: LfoSlot -> String
lfoSlotJson s =
  "{\"ratio\":" <> show s.ratio
    <> ",\"shape\":\"" <> lfoWaveToWire s.shape
    <> "\"}"

clockSlotJson :: ClockSlot -> String
clockSlotJson s =
  "{\"base\":\"" <> clockBaseToWire s.base
    <> "\",\"multiplier\":" <> show s.multiplier
    <> ",\"pulseWidth\":" <> show s.pulseWidth
    <> ",\"phase\":" <> show s.phase
    <> "}"

envSlotJson :: EnvSlot -> String
envSlotJson s =
  "{\"attack\":" <> show s.attack
    <> ",\"decay\":" <> show s.decay
    <> ",\"sustain\":" <> show s.sustain
    <> ",\"release\":" <> show s.release
    <> ",\"attackShape\":" <> show s.attackShape
    <> ",\"decayShape\":" <> show s.decayShape
    <> ",\"releaseShape\":" <> show s.releaseShape
    <> ",\"randomDepth\":" <> show s.randomDepth
    <> rangeOnSlot s.range
    <> "}"

euclidSlotJson :: EuclidSlot -> String
euclidSlotJson s =
  "{\"beats\":" <> show s.beats
    <> ",\"steps\":" <> show s.steps
    <> ",\"rate\":" <> show s.rate
    <> ",\"accentRate\":" <> show s.accentRate
    <> "}"

randSlotJson :: RandSlot -> String
randSlotJson s =
  "{\"direction\":\"" <> randDirectionToWire s.direction
    <> "\",\"length\":" <> show s.length
    <> ",\"randomness\":" <> show s.randomness
    <> ",\"rate\":" <> show s.rate
    <> ",\"attenuator\":" <> show s.attenuator
    <> ",\"scale\":\"" <> randScaleToWire s.scale
    <> "\",\"key\":\"" <> randKeyToWire s.key
    <> "\",\"gateLength\":" <> show s.gateLength
    <> rangeOnSlot s.range
    <> "}"

presetSlotJson :: PresetSlot -> String
presetSlotJson s =
  "{\"value\":" <> show s.value <> "}"

presetNoteSlotJson :: PresetNoteSlot -> String
presetNoteSlotJson s =
  "{\"note\":" <> show s.note <> "}"

-- | Per-slot range field — `,"range":"bipolar5v"` when set, empty
-- | otherwise.  Used by env and rand families which allow per-slot
-- | range overrides.
rangeOnSlot :: Maybe OutputRange -> String
rangeOnSlot = case _ of
  Nothing -> ""
  Just r  -> ",\"range\":\"" <> rangeToWire r <> "\""
