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
import Tidal.Scales (Scale, Distribution(..), applyDistribution, cChromatic)

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
  -- | Per-cell ratchet count.  When `ratchet[i]` resolves to `N`, the
  -- | engine subdivides cell i's wall-time window into N evenly-spaced
  -- | sub-emits, each at vel/dur.  `1` is the no-op default — one
  -- | emit per step at the step's wall time.  Higher values produce
  -- | Metropolix-flavoured retrigger flurries on a per-cell basis;
  -- | sweeping the array live via the Twister gives you Twister-knob
  -- | → "how much retrigger this cell".  Clamped to `>= 1` at the
  -- | voice (a 0 reads as 1; negatives clamp to 1).
  , ratchet     :: Array (Pattern Int)
  -- | Per-cell probability of firing, on [0.0, 1.0].  `1.0` is the
  -- | no-op default (always fire); `0.0` never fires; `0.5` fires
  -- | half the time.  Sampled fresh per step — each pass through the
  -- | grid rolls independently, so a per-cell probability of 0.5
  -- | doesn't generate the same fire/skip pattern twice.  The roll
  -- | is shared across a step's ratchets — when probability fails,
  -- | the whole step is silent regardless of ratchet count.
  , probability :: Array (Pattern Number)
  -- | Per-cell gate (Slab 6.1).  Lifted from registration-time-only
  -- | `Array Boolean` to `Array (Pattern Boolean)` so the Twister side-
  -- | button gate-bank can toggle a cell's gate live.  When a cell's
  -- | gate samples false the engine lands on it but emits no MIDI
  -- | (silent_step in `odonus_engine:current_event`); cursor advance
  -- | continues normally.  Overrides the binding-time `gate` array
  -- | when present.  Default `replicate16 (pure true)` preserves
  -- | "every cell fires" behaviour.
  , gate        :: Array (Pattern Boolean)
  -- | Per-cell glide (Slab 6.1).  Lifted alongside gate so the side-
  -- | button glide-bank is symmetric.  Today this is engine-internal
  -- | only (the binding-time `glide` was already a pass-through marker
  -- | with no synthesis effect); the wire-up to a per-cell portamento
  -- | / MIDI CC65 hint is a follow-up slab.
  , glide       :: Array (Pattern Boolean)
  -- | Per-cell velocity (Slab 6.1).  Lifted from the binding's scalar
  -- | `vel :: Int` so the Vel knob bank sweeps each cell's velocity
  -- | independently.  The engine reads the sampled value at emit time
  -- | (overrides the binding's scalar `vel`).  Default
  -- | `replicate16 (pure 100)` preserves today's velocity baseline.
  , vel         :: Array (Pattern Int)
  -- | Four per-cell modulation slots (Slab 6.1).  Today these are
  -- | data-only — the snapshot carries them through to the voice but
  -- | the engine does not yet emit MIDI CCs for them.  Wiring is the
  -- | per-rig CC/CV translation layer (task #151).  The Twister surface
  -- | already needs them in place so banks Mod1..Mod4 have somewhere
  -- | to write.  Default `replicate16 (pure 0)`.
  , mod1        :: Array (Pattern Int)
  , mod2        :: Array (Pattern Int)
  , mod3        :: Array (Pattern Int)
  , mod4        :: Array (Pattern Int)
  -- | Per-instance scale + distribution mode (Dail-inspired).  The
  -- | per-cell `notes` integers are reinterpreted through this lens
  -- | just before they reach the engine:
  -- |
  -- |   * `Natural` snaps each sampled integer (treated as a MIDI
  -- |     number) to the nearest active scale note.  With `cChromatic`
  -- |     this is the identity — every chromatic step is in-scale —
  -- |     so the defaults preserve today's "notes are literal MIDI"
  -- |     behaviour.
  -- |   * `Equal` indexes each sampled integer as a 1-based scale
  -- |     *degree* through `renderDegree`.  A 7-note scale sweeps
  -- |     across multiple octaves automatically as the integer grows.
  -- |
  -- | A live `set-control odonus.scale c-minor` is not yet wired (the
  -- | scale is a static value, not a Pattern Scale); the next move is
  -- | the obvious one — promote to `Pattern Scale` and sample at the
  -- | same per-step cadence as everything else.  Thread 2.5 will give
  -- | Vetula an output channel to publish the *currently-held chord
  -- | tones* as a scale, so the held chord becomes a live quantiser.
  , scale        :: Scale
  , distribution :: Distribution
  }

-- | Snapshot returned by `evaluateParamsAt`.  Carries the resolved
-- | per-cell arrays so the voice can refresh the engine's traversal
-- | state before step_x / step_y / current_event run.
type OdonusSnapshot =
  { stepYNow    :: Boolean
  , notes       :: Array Int
  , skip        :: Array Boolean
  , advance     :: Boolean
  , ratchet     :: Array Int
  , probability :: Array Number
  , gate        :: Array Boolean
  , glide       :: Array Boolean
  , vel         :: Array Int
  , mod1        :: Array Int
  , mod2        :: Array Int
  , mod3        :: Array Int
  , mod4        :: Array Int
  }

-- | Default config: Y-clock fires once per 4-step cycle (so
-- | Cartesian mode walks row by row of the 4x4 grid).  Default
-- | notes are middle-C-ish drum range; default skip is all-false.
-- | Override `stepYNow` to `pure false` to lock to row 0; override
-- | notes/skip with `liveIntArrayOr` / `liveBoolArrayOr` to make
-- | them controller-driven.
odonusConfig :: OdonusConfig
odonusConfig =
  { stepYNow:     pure false
  , notes:        Array.replicate 16 (pure 60)
  , skip:         Array.replicate 16 (pure false)
  , advance:      pure true
  , ratchet:      Array.replicate 16 (pure 1)
  , probability:  Array.replicate 16 (pure 1.0)
  , gate:         Array.replicate 16 (pure true)
  , glide:        Array.replicate 16 (pure false)
  , vel:          Array.replicate 16 (pure 100)
  , mod1:         Array.replicate 16 (pure 0)
  , mod2:         Array.replicate 16 (pure 0)
  , mod3:         Array.replicate 16 (pure 0)
  , mod4:         Array.replicate 16 (pure 0)
  , scale:        cChromatic
  , distribution: Natural
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
  let sampleN  p = sampleIntAt    controls 60    p pos
      sampleS  p = sampleBoolAt   controls false p pos
      sampleR  p = sampleIntAt    controls 1     p pos
      sampleP  p = sampleNumberAt controls 1.0   p pos
      sampleG  p = sampleBoolAt   controls true  p pos   -- gate default open
      sampleGl p = sampleBoolAt   controls false p pos   -- glide default off
      sampleV  p = sampleIntAt    controls 100   p pos   -- vel default 100
      sampleM  p = sampleIntAt    controls 0     p pos   -- mod default 0
      -- Per-cell integer → MIDI note number, run through the scale's
      -- distribution mode.  Natural + cChromatic is the identity, so
      -- existing sessions are unaffected.
      distribute = applyDistribution cfg.distribution cfg.scale
  in { stepYNow:    sampleBoolAt controls false cfg.stepYNow pos
     , notes:       map (distribute <<< sampleN) cfg.notes
     , skip:        map sampleS cfg.skip
     , advance:     sampleBoolAt controls true cfg.advance pos
     , ratchet:     map sampleR cfg.ratchet
     , probability: map sampleP cfg.probability
     , gate:        map sampleG  cfg.gate
     , glide:       map sampleGl cfg.glide
     , vel:         map sampleV  cfg.vel
     , mod1:        map sampleM  cfg.mod1
     , mod2:        map sampleM  cfg.mod2
     , mod3:        map sampleM  cfg.mod3
     , mod4:        map sampleM  cfg.mod4
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

-- | Number-typed twin.  Used for per-cell probability sampling.
sampleNumberAt :: ControlMap -> Number -> Pattern Number -> Number -> Number
sampleNumberAt controls dflt pat at =
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
