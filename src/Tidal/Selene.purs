-- | Tidal.Selene — typed polysignals as first-class Session
-- | bindings.  Slab C (2026-05-23 unification: Move A).
-- |
-- | A polysignal is an autonomous, multi-output configuration installed
-- | on an FH-2 bank — an LFO/preset bank, a clock-bus, an ADSR cluster,
-- | a euclidean rhythm machine, etc.  It is *not* a Part (no event
-- | stream) and *not* an Instrument (no pitch/CV emission per beat).
-- | It's a third notation alongside Tidal mini-patterns: a declarative
-- | musical specification of standing-wave control behaviour.
-- |
-- | A typed Session-level binding looks like:
-- |
-- |     testLfo :: Selene "testLfo"
-- |     testLfo = octoLfo fh2Main
-- |       [ triLFO 1.0, sawLFO 0.5, sinLFO 2.0, sqrLFO 4.0
-- |       , triLFO 0.25, sawLFO 0.5, sinLFO 1.0, sqrLFO 0.5
-- |       ]
-- |       (Just Bipolar5V)
-- |
-- | The Symbol parameter is decorative — the walker derives the alias
-- | from the binding name (`testLfo` here).  Keeping it in the type
-- | makes the intended alias visible at the type-level boundary and
-- | leaves room for a future binding-name === Symbol checker.
-- |
-- | The walker classifies the value by constructor tag, builds the
-- | JSON envelope, and emits a `RegisterSelene` event.  The Erlang
-- | side hands the envelope verbatim to fh2-daemon via
-- | `fh2_daemon_call`, which puts it through `Rig.applyWithClaims` —
-- | the unified port-claims layer from `project_port_claims_design`.
-- |
-- | Unified slot model (Move A, 2026-05-23).  Every modulation slot is
-- | one `ModSlot` carrying a rate, a static `level`, and per-shape
-- | amplitudes (sin/sqr/tri/saw/rnd/nse).  A "preset" (static voltage)
-- | is degenerate: `rate = 0`, all amps zero, `level` carries the
-- | static offset.  The user-facing `silent`/`fixed`/`sine`/`square`/
-- | `triangle`/`sawtooth`/`random`/`noise` constructors are the
-- | ergonomic surface; multi-shape mixes are written via record
-- | update on `silent`, e.g.
-- |
-- |     silent { rate = 0.5, tri = 0.8, sqr = 0.3 }
-- |
-- | which lowers to an FH-2 LFO at 0.5 Hz with tri-amp 0.8 and
-- | sqr-amp 0.3 (Σ_shape over the firmware's shape mixer).
-- |
-- | The six families:
-- |   PolyLfoConfig         — eight modulation slots (per-shape amp
-- |                           mix at one rate; presets are degenerate)
-- |   PolyClockConfig       — eight clock-pulse trains (base × multiplier
-- |                           × pulseWidth × phase)
-- |   PolyEnvConfig         — eight ADSR envelopes (attack/decay/sustain/
-- |                           release plus shape and depth)
-- |   PolyEuclidConfig      — eight euclidean rhythms (beats/steps/rate)
-- |   PolyRandConfig        — eight random-walk CV outputs
-- |   PolyPresetNoteConfig  — eight fixed pitches (MIDI note number per
-- |                           slot, converted to V/oct by the daemon).
-- |                           Kept distinct from PolyLfoConfig because
-- |                           V/oct is pitch-scaled, not range-scaled.
module Tidal.Selene
  ( Selene(..)
  , OutputRange(..)
  , Bank(..)
  , Fh2Bank(..)
  , Es9Bank(..)
  , fh2Main
  , fh28Gt
  , fh28Cv
  , es9Main
  , es98Cv
  , es98Gt
  , seleneBank
  , seleneDeviceWire
  , ClockBase(..)
  , RandDirection(..)
  , RandScale(..)
  , RandKey(..)
  , ModSlot
  , ClockSlot
  , EnvSlot
  , EuclidSlot
  , RandSlot
  , PresetNoteSlot
  , silent
  , __
  , fixed
  , sinLFO
  , sqrLFO
  , triLFO
  , sawLFO
  , rndLFO
  , nseLFO
  , sinLFOAmp
  , sqrLFOAmp
  , triLFOAmp
  , sawLFOAmp
  , rndLFOAmp
  , nseLFOAmp
  , octoLfo
  , octoClock
  , octoEnv
  , octoEuclid
  , octoRand
  , octoPresetNote
  , seleneAsJson
  , seleneFamily
  , bankToWire
  , rangeToWire
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

-- | Where a polysignal's outputs go.  Top-level sum across output
-- | devices; adding a new device family (Ornament & Crime, an FH-3,
-- | etc.) is one new outer constructor here plus its own inner ADT
-- | for that device's banks.
-- |
-- | Today's two cases:
-- |   `FH2` — the Expert Sleepers FH-2 + its FHX-8CV / FHX-8GT
-- |   expanders, addressed by a nested `Fh2Bank`.
-- |   `Virtual` — no hardware claim, no daemon round-trip; the
-- |   string is the bus-key prefix and the eight outputs land at
-- |   `<prefix>.0`..`<prefix>.7` on the live-control bus.  The
-- |   walker detects this case and routes to
-- |   `virtual_selene_voice_sup` instead of fh2-daemon.
data Bank
  = FH2 Fh2Bank
  | ES9 Es9Bank
  | Virtual String

derive instance eqBank :: Eq Bank

-- | The FH-2's own front-panel jacks plus its two expander families.
data Fh2Bank
  = FH2Main          -- the FH-2's own eight jacks
  | FH28Cv Int       -- FHX-8CV expander, indices 0..6
  | FH28Gt Int       -- FHX-8GT expander, indices 0..7

derive instance eqFh2Bank :: Eq Fh2Bank

-- | The ES-9's own front-panel jacks plus its Silent Way expanders.
-- | Mirrors `Fh2Bank` deliberately — same constructor shape, different
-- | device target.  The walker emits a `device` discriminator on the
-- | registration event so the Erlang side dispatches to cv-router's
-- | `~/.es9/control.sock` instead of fh2-daemon.
data Es9Bank
  = ES9Main          -- ES-9's own eight panel jacks (cv-router buses 8..15)
  | ES98Cv Int       -- ESX-8CV expander via Silent Way (C.4h pending)
  | ES98Gt Int       -- ESX-8GT expander via Silent Way (C.4h pending)

derive instance eqEs9Bank :: Eq Es9Bank

-- | Smart helpers — cell text reads `octoLfo fh2Main ...` and
-- | `octoLfo (fh28Cv 2) ...` without the `FH2 (...)` wrapping
-- | ceremony.  These ARE the user surface; raw constructors are
-- | available for code that needs to pattern-match on the bank.
fh2Main :: Bank
fh2Main = FH2 FH2Main

fh28Cv :: Int -> Bank
fh28Cv n = FH2 (FH28Cv n)

fh28Gt :: Int -> Bank
fh28Gt n = FH2 (FH28Gt n)

es9Main :: Bank
es9Main = ES9 ES9Main

es98Cv :: Int -> Bank
es98Cv n = ES9 (ES98Cv n)

es98Gt :: Int -> Bank
es98Gt n = ES9 (ES98Gt n)

bankToWire :: Bank -> String
bankToWire = case _ of
  FH2 fb         -> fh2BankToWire fb
  ES9 eb         -> es9BankToWire eb
  Virtual prefix -> "virtual:" <> prefix

fh2BankToWire :: Fh2Bank -> String
fh2BankToWire = case _ of
  FH2Main  -> "main"
  FH28Cv n -> "cv" <> show n
  FH28Gt n -> "gt" <> show n

-- | Wire tokens deliberately mirror FH-2's — the daemon listening on
-- | the ES-9 control socket reads them in its own coordinate system,
-- | so "main" means ES-9 main panel here and FH-2 main panel for
-- | fh2-daemon.  Routing decides which socket; tokens within a
-- | device's namespace are unambiguous.
es9BankToWire :: Es9Bank -> String
es9BankToWire = case _ of
  ES9Main  -> "main"
  ES98Cv n -> "cv" <> show n
  ES98Gt n -> "gt" <> show n

-- | Routing tag used by the walker to pick a daemon socket.  Mirrors
-- | the outer `Bank` constructor; `Virtual` banks have no device tag
-- | (they're handled BEAM-side and don't flow through this codepath).
seleneDeviceWire :: forall s. Selene s -> String
seleneDeviceWire s = case seleneBank s of
  FH2 _     -> "fh2"
  ES9 _     -> "es9"
  Virtual _ -> "fh2"   -- unreachable: virtual banks go via RegisterVirtualSelene

-- ---------------------------------------------------------------------------
-- Modulation slot — unified LFO + preset value
-- ---------------------------------------------------------------------------

-- | A single modulation output slot.  Follows the FH-2 firmware's
-- | per-output equation:
-- |
-- |     output(t) = level + Σ_shape ( amp_shape · shape(rate, phase, t) )
-- |
-- | where `shape ∈ {sin, sqr, tri, saw, rnd, nse}`.  Saw is signed-
-- | amplitude (negative `saw` flips to falling).  Setting `rate = 0`
-- | with all amps zero gives a degenerate "preset" — a static
-- | `level` on the output, the canonical static-voltage slot.
-- |
-- | The `level` field is a normalised value in `[-1, 1]` (or `[0, 1]`
-- | on unipolar ranges) that the realiser scales to volts via the
-- | bank's `outputRange`.  Per-shape amps are likewise normalised.
-- | The user never types a voltage at this layer.
type ModSlot =
  { rate :: Number
  , phase :: Number
  , level :: Number
  , sin :: Number
  , sqr :: Number
  , tri :: Number
  , saw :: Number
  , rnd :: Number
  , nse :: Number
  }

-- ---------------------------------------------------------------------------
-- ModSlot convenience constructors
-- ---------------------------------------------------------------------------

-- | A slot that emits nothing — useful as a placeholder in a bank
-- | snapshot where most slots are inactive, or as the base for
-- | record-update construction:  `silent { rate = 0.5, tri = 0.8 }`.
silent :: ModSlot
silent =
  { rate: 0.0
  , phase: 0.0
  , level: 0.0
  , sin: 0.0
  , sqr: 0.0
  , tri: 0.0
  , saw: 0.0
  , rnd: 0.0
  , nse: 0.0
  }

-- | Visual alias for `silent`.  A flat line for a flat line — reads as
-- | the same horizontal-mark rest notation Tidal users would write as
-- | `~`, but legal PureScript (so the unchanged source-is-AST contract
-- | holds: no parser stage).  Use in slot grids where the eye should
-- | skip rests and land on active slots:
-- |
-- |     [ sinLFO 0.5, __, __, __
-- |     , __,         __, __, __ ]
__ :: ModSlot
__ = silent

-- | A static-value slot: the named `level` (normalised to the bank's
-- | outputRange) on the output, no LFO contribution.  Replaces the
-- | old PolyPreset family — `fixed 1.0` on a Bipolar5V bank is `+5V`.
fixed :: Number -> ModSlot
fixed l = silent { level = l }

-- | Shape-specific LFO slot constructors at full amplitude.
-- |
-- | Suffix `LFO` distinguishes these from the canonical Tidal
-- | pattern combinators `Tidal.Pattern.Core.sine` / `square` (which
-- | produce `Pattern Number`, used in cell text as e.g.
-- | `# pan sine`).  The Selene constructors live at the Session
-- | layer; the Pattern combinators live in cells; keeping the
-- | names disjoint avoids a shadow that would silently break cell
-- | text on the canonical Tidal vocabulary.
sinLFO :: Number -> ModSlot
sinLFO r = silent { rate = r, sin = 1.0 }

sqrLFO :: Number -> ModSlot
sqrLFO r = silent { rate = r, sqr = 1.0 }

triLFO :: Number -> ModSlot
triLFO r = silent { rate = r, tri = 1.0 }

sawLFO :: Number -> ModSlot
sawLFO r = silent { rate = r, saw = 1.0 }

rndLFO :: Number -> ModSlot
rndLFO r = silent { rate = r, rnd = 1.0 }

nseLFO :: Number -> ModSlot
nseLFO r = silent { rate = r, nse = 1.0 }

-- | Shape-specific LFO slot constructors with explicit amplitude.
-- | For multi-shape mixes, use record update on `silent` instead:
-- |
-- |     silent { rate = 0.5, tri = 0.8, sqr = 0.3 }
sinLFOAmp :: Number -> Number -> ModSlot
sinLFOAmp r a = silent { rate = r, sin = a }

sqrLFOAmp :: Number -> Number -> ModSlot
sqrLFOAmp r a = silent { rate = r, sqr = a }

triLFOAmp :: Number -> Number -> ModSlot
triLFOAmp r a = silent { rate = r, tri = a }

sawLFOAmp :: Number -> Number -> ModSlot
sawLFOAmp r a = silent { rate = r, saw = a }

rndLFOAmp :: Number -> Number -> ModSlot
rndLFOAmp r a = silent { rate = r, rnd = a }

nseLFOAmp :: Number -> Number -> ModSlot
nseLFOAmp r a = silent { rate = r, nse = a }

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
-- Preset-note slot — fixed pitches on the bank's outputs
-- ---------------------------------------------------------------------------

-- | A fixed MIDI pitch on a single CV output (V/oct).  The daemon
-- | converts `note` to voltage via the conventional 1V/octave mapping
-- | with note 12 (C0) = 0V (so note 60 = 4V, fits unipolar 0-10V or
-- | bipolar ±5V comfortably).
-- |
-- | Kept distinct from `ModSlot` because pitch is V/oct-scaled (a
-- | fixed semitone constant per volt) rather than range-scaled (a
-- | normalised level mapped to the bank's outputRange).  Mixing the
-- | two scales in one slot kind would conceal a real interpretation
-- | difference at the realiser boundary.
type PresetNoteSlot =
  { note :: Int  -- MIDI 0..127
  }

-- ---------------------------------------------------------------------------
-- Selene sum
-- ---------------------------------------------------------------------------

data Selene (s :: Symbol)
  = PolyLfoConfig
      { bank :: Bank
      , slots :: Array ModSlot
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
  | PolyPresetNoteConfig
      { bank :: Bank
      , slots :: Array PresetNoteSlot
      , range :: Maybe OutputRange
      }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

octoLfo
  :: forall s
   . Bank -> Array ModSlot -> Maybe OutputRange -> Selene s
octoLfo bank slots range = PolyLfoConfig { bank, slots, range }

octoClock
  :: forall s
   . Bank -> Array ClockSlot -> Maybe OutputRange -> Selene s
octoClock bank slots range = PolyClockConfig { bank, slots, range }

octoEnv
  :: forall s
   . Bank -> Array EnvSlot -> Maybe OutputRange -> Selene s
octoEnv bank slots range = PolyEnvConfig { bank, slots, range }

octoEuclid
  :: forall s
   . Bank -> Array EuclidSlot -> Maybe OutputRange -> Selene s
octoEuclid bank slots range = PolyEuclidConfig { bank, slots, range }

octoRand
  :: forall s
   . Bank -> Array RandSlot -> Maybe OutputRange -> Selene s
octoRand bank slots range = PolyRandConfig { bank, slots, range }

octoPresetNote
  :: forall s
   . Bank -> Array PresetNoteSlot -> Maybe OutputRange -> Selene s
octoPresetNote bank slots range = PolyPresetNoteConfig { bank, slots, range }

-- ---------------------------------------------------------------------------
-- JSON envelope projection
-- ---------------------------------------------------------------------------

-- | The bank a typed Selene value targets.  The walker reads
-- | this to choose between the hardware (fh2-daemon) and virtual
-- | (BEAM gen_server) routing paths.
seleneBank :: forall s. Selene s -> Bank
seleneBank = case _ of
  PolyLfoConfig         { bank } -> bank
  PolyClockConfig       { bank } -> bank
  PolyEnvConfig         { bank } -> bank
  PolyEuclidConfig      { bank } -> bank
  PolyRandConfig        { bank } -> bank
  PolyPresetNoteConfig  { bank } -> bank

-- | The family name for a typed Selene value — same string the
-- | daemon's wire parser dispatches on (`polylfo`, `polyclock`, …).
seleneFamily :: forall s. Selene s -> String
seleneFamily = case _ of
  PolyLfoConfig _         -> "polylfo"
  PolyClockConfig _       -> "polyclock"
  PolyEnvConfig _         -> "polyenv"
  PolyEuclidConfig _      -> "polyeuclid"
  PolyRandConfig _        -> "polyrand"
  PolyPresetNoteConfig _  -> "polypresetnote"

-- | Project a Selene to the JSON envelope the daemon expects.
-- | The alias argument carries the binding name (resolved by the
-- | walker from `enumerateExports`).
seleneAsJson :: forall s. String -> Selene s -> String
seleneAsJson alias = case _ of
  PolyLfoConfig cfg ->
    envelope "polylfo" cfg.bank alias cfg.range
      (map modSlotJson cfg.slots)
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

-- | Unified modulation slot — emits rate / phase / level plus the
-- | six per-shape amplitudes (sin/sqr/tri/saw/rnd/nse).  The daemon
-- | sums per-shape contributions at the realiser layer.
modSlotJson :: ModSlot -> String
modSlotJson s =
  "{\"rate\":" <> show s.rate
    <> ",\"phase\":" <> show s.phase
    <> ",\"level\":" <> show s.level
    <> ",\"sin\":" <> show s.sin
    <> ",\"sqr\":" <> show s.sqr
    <> ",\"tri\":" <> show s.tri
    <> ",\"saw\":" <> show s.saw
    <> ",\"rnd\":" <> show s.rnd
    <> ",\"nse\":" <> show s.nse
    <> "}"

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
