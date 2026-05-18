-- | Tidal.PolySignal — typed polysignals as first-class Session
-- | bindings.  Slab C step 1 (2026-05-18).
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
-- |       [ { ratio: 1.0, wave: LfoTri }
-- |       , { ratio: 0.5, wave: LfoSaw }
-- |       , { ratio: 2.0, wave: LfoSin }
-- |       , { ratio: 4.0, wave: LfoSqr }
-- |       , { ratio: 0.25, wave: LfoTri }
-- |       , { ratio: 0.5, wave: LfoSaw }
-- |       , { ratio: 1.0, wave: LfoSin }
-- |       , { ratio: 0.5, wave: LfoSqr }
-- |       ]
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
module Tidal.PolySignal
  ( PolySignal(..)
  , OutputRange(..)
  , Bank(..)
  , LfoWave(..)
  , LfoSlot
  , polyLfo
  , polySignalAsJson
  , polySignalFamily
  , bankToWire
  , rangeToWire
  , lfoWaveToWire
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
-- PolyLfo (first family)
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
-- PolySignal sum
-- ---------------------------------------------------------------------------

data PolySignal (s :: Symbol)
  = PolyLfoConfig
      { bank :: Bank
      , slots :: Array LfoSlot
      , range :: Maybe OutputRange
      }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

polyLfo
  :: forall s
   . Bank
  -> Array LfoSlot
  -> Maybe OutputRange
  -> PolySignal s
polyLfo bank slots range = PolyLfoConfig { bank, slots, range }

-- ---------------------------------------------------------------------------
-- JSON envelope projection (matches calypso/shared's polySignalEnvelopeJson)
-- ---------------------------------------------------------------------------

-- | The family name for a typed PolySignal value — same string the
-- | daemon's wire parser dispatches on (`polylfo`, `polyclock`, …).
polySignalFamily :: forall s. PolySignal s -> String
polySignalFamily = case _ of
  PolyLfoConfig _ -> "polylfo"

-- | Project a PolySignal to the JSON envelope the daemon expects.
-- | The alias argument carries the binding name (resolved by the
-- | walker from `enumerateExports`).  Resulting shape:
-- |
-- |     {"bank":"main","family":"polylfo","alias":"testLfo",
-- |      "outputRange":"bipolar5v",
-- |      "slots":[{"ratio":1.0,"wave":"tri"}, …]}
polySignalAsJson :: forall s. String -> PolySignal s -> String
polySignalAsJson alias = case _ of
  PolyLfoConfig cfg ->
    envelope "polylfo" cfg.bank alias cfg.range
      (map lfoSlotJson cfg.slots)

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

lfoSlotJson :: LfoSlot -> String
lfoSlotJson s =
  "{\"ratio\":" <> show s.ratio
    <> ",\"shape\":\"" <> lfoWaveToWire s.shape
    <> "\"}"
