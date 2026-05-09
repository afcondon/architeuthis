-- | SKETCH — not yet integrated. Lives in `sketches/`, not `src/`.
-- |
-- | Tidal.Pam — typed mod-matrix vocabulary modelled on ALM
-- | Pamela's NEW Workout (ALM-017).
-- |
-- | Eight independently-configurable modulation lanes, each producing
-- | a clocked stream of voltage samples (gate / triangle / sine /
-- | envelope / random) shaped by a recipe of typed parameters.
-- | Recipe parameters are themselves patternable — the `mods` field
-- | is the mod-matrix the prior research called the language-extension
-- | North Star.
-- |
-- | Hardware reference: see
-- | docs/sequencer-vocabulary-research-2026-05-09.md §Module 1.
-- |
-- | The hardware Pam navigates lane state via clock ticks; we lift
-- | that to "navigate via the global Pattern temporal substrate" —
-- | each lane's `modifier` decides how often it samples, and the
-- | whole lane bank is queried into a `Pattern (Vec8 Voltage)`.
-- |
-- | Status: types and helpers in place; the runtime evaluator
-- | (`runPam`) is sketched but stubbed at the cycle-resolution level.
-- | Integration with the per-voice supervisor + cv-router happens at
-- | the rig-binding pass (Phase 3).
module Tidal.Pam
  ( -- * Recipe
    Lane
  , Wave(..)
  , Modifier(..)
  , Euclid
  , defaultLane
    -- * Lane bank
  , Pam
  , LaneIdx(..)
  , lanes
  , withLanes
    -- * Mod matrix
  , Param(..)
  , ParamMod
  , Combine(..)
  , withMods
  , on
  , scaleBy
  , addTo
    -- * Output
  , Voltage
  , Vec8
    -- * Run
  , runPam
  , runLane
    -- * Convenience constructors
  , kick
  , hat
  , triLfo
  , envOnTrigger
  , euclid
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Tidal.Pattern.Types
  (Pattern, pattern, query, silence, Event(..), Arc(..), State(..)
  , mkArc, eventValue)
import Tidal.Pattern.Core (stack)

-------------------------------------------------------------------------------
-- Voltage and 8-vector
-------------------------------------------------------------------------------

-- | A single CV sample, normalised to [0..1] (we scale to physical
-- | volts at the rig boundary; cv-router knows the per-bus mapping).
type Voltage = Number

-- | Eight lanes' simultaneous output samples. Indexed positionally —
-- | lane 0 first.  We keep this as `Array Voltage` of length 8 rather
-- | than introducing a refined-length type; helpers enforce the
-- | invariant.
newtype Vec8 a = Vec8 (Array a)

-- | Build a Vec8 from exactly eight values; right-pads or truncates
-- | with the supplied default if the input length is wrong.  We
-- | accept the cost of softness here so a half-built Pam still
-- | renders rather than crashes the editor.
mkVec8 :: forall a. a -> Array a -> Vec8 a
mkVec8 d xs =
  Vec8 $ Array.take 8 (xs <> Array.replicate (8 - Array.length xs) d)

-------------------------------------------------------------------------------
-- Recipe — the typed per-lane parameter bag
-------------------------------------------------------------------------------

-- | What kind of waveform a lane emits.  One full cycle of the
-- | waveform spans one `step` (which is one tick at the lane's
-- | configured `modifier`).
-- |
-- | The hardware's Random produces a stepped random sample per step;
-- | combine with `loop` (in Lane) for re-seedable randomness.
data Wave
  = Gate
  | Triangle
  | Sine
  | Envelope    -- attack-snappy, release shaped by `width`
  | Random

derive instance eqWave :: Eq Wave

instance showWave :: Show Wave where
  show = case _ of
    Gate -> "Gate"
    Triangle -> "Triangle"
    Sine -> "Sine"
    Envelope -> "Envelope"
    Random -> "Random"

-- | Clock modifier — how often a lane fires relative to the master
-- | BPM.  `Mul n` = n times per beat; `Div n` = once every n beats.
-- | The triplet/dotted constructors carry rational integer step
-- | counts; we render them via the modifier evaluator.
data Modifier
  = Mul Int               -- × 1 .. × 48
  | Div Int               -- /1 .. /512
  | TripletMul Int        -- ×N triplet (N · 2/3)
  | TripletDiv Int
  | DottedMul Int         -- ×N dotted (N · 3/2)
  | DottedDiv Int
  | AlwaysOn
  | AlwaysOff
  | PulseStart            -- one pulse on transport start
  | PulseStop             -- one pulse on transport stop

derive instance eqModifier :: Eq Modifier
instance showModifier :: Show Modifier where show = showModifier

showModifier :: Modifier -> String
showModifier = case _ of
  Mul n -> "x" <> show n
  Div n -> "/" <> show n
  TripletMul n -> "x" <> show n <> "T"
  TripletDiv n -> "/" <> show n <> "T"
  DottedMul n -> "x" <> show n <> "."
  DottedDiv n -> "/" <> show n <> "."
  AlwaysOn -> "on"
  AlwaysOff -> "off"
  PulseStart -> "pulse-start"
  PulseStop -> "pulse-stop"

-- | Euclidean parameters: (steps, hits, rotation).  Hits ≤ steps.
type Euclid = { steps :: Int, trigs :: Int, rot :: Int }

-- | A complete recipe for one lane.  Defaults to a one-per-beat
-- | gate with no Euclidean masking.
type Lane =
  { modifier :: Modifier
  , wave     :: Wave
  , level    :: Number       -- 0..1 — output amplitude
  , offset   :: Number       -- 0..1 — vertical offset
  , width    :: Number       -- 0..1 — meaning depends on wave
  , phase    :: Number       -- 0..1 — start point in cycle
  , delay    :: Number       -- 0..1 of step time before waveform begins
  , delayDiv :: Int          -- which steps get delayed (every Nth)
  , slop     :: Number       -- 0..1 timing humanisation
  , euclid   :: Maybe Euclid
  , rSkip    :: Number       -- 0..1 random per-step skip
  , loop     :: Maybe Int    -- beats; Nothing = free-running RNG
  }

defaultLane :: Lane
defaultLane =
  { modifier: Mul 1
  , wave:     Gate
  , level:    1.0
  , offset:   0.0
  , width:    0.5
  , phase:    0.0
  , delay:    0.0
  , delayDiv: 1
  , slop:     0.0
  , euclid:   Nothing
  , rSkip:    0.0
  , loop:     Nothing
  }

-------------------------------------------------------------------------------
-- Pam — the eight-lane bank plus mod matrix
-------------------------------------------------------------------------------

-- | Lane index 0..7.  We use a newtype rather than `Int` so the
-- | mod-matrix destinations can't accidentally point at a non-lane
-- | parameter.
newtype LaneIdx = LaneIdx Int

derive instance eqLaneIdx :: Eq LaneIdx
derive instance ordLaneIdx :: Ord LaneIdx
instance showLaneIdx :: Show LaneIdx where
  show (LaneIdx n) = "lane[" <> show n <> "]"

-- | A complete Pam configuration: the eight static recipes plus an
-- | array of patternable parameter overrides.
type Pam =
  { lanes :: Vec8 Lane
  , mods  :: Array ParamMod
  }

-- | Static-only Pam.  Right place to start when authoring; add `mods`
-- | via `withMods` once you want patternable parameters.
lanes :: Array Lane -> Pam
lanes ls = { lanes: mkVec8 defaultLane ls, mods: [] }

-- | Replace the lane bank in an existing Pam.  Useful when you've
-- | built a Pam with `withMods` first and want to swap recipes.
withLanes :: Array Lane -> Pam -> Pam
withLanes ls pam = pam { lanes = mkVec8 defaultLane ls }

-------------------------------------------------------------------------------
-- Mod matrix — patternable parameters
-------------------------------------------------------------------------------

-- | Which scalar parameter of a lane a mod targets.  The hardware's
-- | per-CV-input attenuverter is replaced by `Combine` plus the
-- | Pattern's own arithmetic.
data Param
  = PLevel | POffset | PWidth | PPhase | PDelay | PSlop
  | PRSkip | PLoop
  | PESteps | PETrigs | PERot

derive instance eqParam :: Eq Param

instance showParam :: Show Param where
  show = case _ of
    PLevel  -> "level"
    POffset -> "offset"
    PWidth  -> "width"
    PPhase  -> "phase"
    PDelay  -> "delay"
    PSlop   -> "slop"
    PRSkip  -> "rSkip"
    PLoop   -> "loop"
    PESteps -> "esteps"
    PETrigs -> "etrigs"
    PERot   -> "erot"

-- | How a Pattern's value combines with the lane's static value.
data Combine
  = Replace     -- pattern value overrides static
  | ScaleBy     -- result = static × patternValue
  | AddTo       -- result = clamp01 (static + patternValue)

derive instance eqCombine :: Eq Combine

-- | One entry in the mod matrix: target lane, target param, how to
-- | combine, and the pattern of values.
type ParamMod =
  { lane    :: LaneIdx
  , param   :: Param
  , combine :: Combine
  , pat     :: Pattern Number
  }

-- | Add mods to a Pam.  Order matters when multiple mods target the
-- | same (lane, param): the last-added wins (right-biased fold).
withMods :: Array ParamMod -> Pam -> Pam
withMods ms pam = pam { mods = pam.mods <> ms }

-- | Replace-style mod helper: `on lane.0 PLevel pat`
on :: LaneIdx -> Param -> Pattern Number -> ParamMod
on l p pat = { lane: l, param: p, combine: Replace, pat }

-- | Multiplicative mod helper.
scaleBy :: LaneIdx -> Param -> Pattern Number -> ParamMod
scaleBy l p pat = { lane: l, param: p, combine: ScaleBy, pat }

-- | Additive mod helper (clamped to [0..1]).
addTo :: LaneIdx -> Param -> Pattern Number -> ParamMod
addTo l p pat = { lane: l, param: p, combine: AddTo, pat }

-------------------------------------------------------------------------------
-- Convenience lane constructors
-------------------------------------------------------------------------------

-- | Standard 4-on-the-floor kick gate.
kick :: Lane
kick = defaultLane { modifier = Mul 1, wave = Gate, width = 0.1 }

-- | Off-beat hat (every 8th note).
hat :: Lane
hat = defaultLane { modifier = Mul 2, wave = Gate, width = 0.05, phase = 0.5 }

-- | Slow triangle LFO at /4.
triLfo :: Lane
triLfo = defaultLane { modifier = Div 4, wave = Triangle }

-- | Envelope on every beat — attack-snappy with shaped release.
envOnTrigger :: Number -> Lane
envOnTrigger releasePct =
  defaultLane { modifier = Mul 1, wave = Envelope, width = releasePct }

-- | Euclidean rhythm helper.  `euclid 5 8 0` → 5 hits in 8 steps,
-- | no rotation.
euclid :: Int -> Int -> Int -> Lane
euclid s t r = defaultLane
  { modifier = Mul (max 1 s)
  , wave     = Gate
  , width    = 0.25
  , euclid   = Just { steps: s, trigs: t, rot: r }
  }

-------------------------------------------------------------------------------
-- Evaluation — runPam
-------------------------------------------------------------------------------

-- | Render a Pam configuration as a Pattern of 8-channel voltage
-- | snapshots.  At each tick, each lane is evaluated independently
-- | (modifier, wave, all extended params, then any matching mods);
-- | the eight results are bundled into a Vec8.
-- |
-- | Implementation strategy: each lane becomes its own
-- | `Pattern Voltage`; `runPam` stacks them and zips per-cycle.  The
-- | mod-matrix evaluation happens *inside* `runLane` so that each
-- | lane's pattern correctly carries its own time-warped behaviour
-- | when wrapped in `fast`/`slow` etc.
runPam :: Pam -> Pattern (Vec8 Voltage)
runPam pam =
  let
    ls = unVec8 pam.lanes
    laneStreams = Array.mapWithIndex (\i lane -> runLane (LaneIdx i) lane pam.mods) ls
  in
    bundle laneStreams

-- | Render one lane as a Pattern of voltage samples.  The mods are
-- | filtered to those matching this lane and applied at query time.
runLane :: LaneIdx -> Lane -> Array ParamMod -> Pattern Voltage
runLane idx lane mods = pattern \st ->
  let
    laneMods = Array.filter (\m -> m.lane == idx) mods
    effective = applyMods lane laneMods st
  in
    laneEvents effective st

-- | Resolve the static recipe + matching mods into an effective
-- | recipe for the *current* query window.  Each mod queries its
-- | own pattern at the same arc and overlays its result on the
-- | corresponding field.  When a mod's pattern is silent for this
-- | arc the static value passes through.
applyMods :: Lane -> Array ParamMod -> State -> Lane
applyMods static ms st =
  Array.foldl (\acc m -> applyOne acc m st) static ms
  where
    applyOne :: Lane -> ParamMod -> State -> Lane
    applyOne lane m queryState =
      case firstEventValue (query m.pat queryState) of
        Nothing -> lane
        Just v  -> setParam m.param (combine m.combine (getParam m.param lane) v) lane

    firstEventValue :: Array (Event Number) -> Maybe Number
    firstEventValue arr = case Array.head arr of
      Nothing -> Nothing
      Just ev -> Just (eventValue ev)

    combine :: Combine -> Number -> Number -> Number
    combine Replace _ patV    = patV
    combine ScaleBy staticV v = staticV * v
    combine AddTo   staticV v = clamp01 (staticV + v)

    clamp01 :: Number -> Number
    clamp01 x = max 0.0 (min 1.0 x)

-- | Get a scalar parameter from a Lane.  Note: PLoop and Euclid-
-- | params don't naturally carry Number; we coerce conservatively.
getParam :: Param -> Lane -> Number
getParam = case _ of
  PLevel  -> _.level
  POffset -> _.offset
  PWidth  -> _.width
  PPhase  -> _.phase
  PDelay  -> _.delay
  PSlop   -> _.slop
  PRSkip  -> _.rSkip
  PLoop   -> \l -> case l.loop of Nothing -> 0.0
                                  Just n  -> toNum n
  PESteps -> \l -> case l.euclid of Nothing -> 0.0
                                    Just e  -> toNum e.steps
  PETrigs -> \l -> case l.euclid of Nothing -> 0.0
                                    Just e  -> toNum e.trigs
  PERot   -> \l -> case l.euclid of Nothing -> 0.0
                                    Just e  -> toNum e.rot
  where
    toNum :: Int -> Number
    toNum = fromInt

-- | Set a scalar parameter on a Lane.  Integer-valued params (Loop
-- | and Euclid) are floored from the Number we receive.
setParam :: Param -> Number -> Lane -> Lane
setParam p v lane = case p of
  PLevel  -> lane { level = v }
  POffset -> lane { offset = v }
  PWidth  -> lane { width = v }
  PPhase  -> lane { phase = v }
  PDelay  -> lane { delay = v }
  PSlop   -> lane { slop = v }
  PRSkip  -> lane { rSkip = v }
  PLoop   -> lane { loop = Just (toInt v) }
  PESteps -> lane { euclid = setSteps (toInt v) lane.euclid }
  PETrigs -> lane { euclid = setTrigs (toInt v) lane.euclid }
  PERot   -> lane { euclid = setRot   (toInt v) lane.euclid }
  where
    toInt :: Number -> Int
    toInt = floorN

    setSteps n = case _ of
      Nothing -> Just { steps: n, trigs: 1, rot: 0 }
      Just e  -> Just (e { steps = n })
    setTrigs n = case _ of
      Nothing -> Nothing
      Just e  -> Just (e { trigs = min n e.steps })
    setRot n = case _ of
      Nothing -> Nothing
      Just e  -> Just (e { rot = n })

-------------------------------------------------------------------------------
-- Per-lane event generation (the actual sampling)
-------------------------------------------------------------------------------

-- | Generate the events for one lane within a query state.  This is
-- | where the modifier becomes a step rate, the wave becomes a
-- | shaped voltage, the Euclidean mask gates triggers, and the
-- | random-skip-with-loop machinery decides "is this step on?"
-- |
-- | The implementation here is the simplest correct shape; real
-- | musical fidelity requires per-step sub-sampling for waveforms
-- | (so that a Triangle lane at /4 emits a smooth ramp across 4
-- | beats, not a single value).  That's deferred to Phase 2 — see
-- | the note in the research doc about ESX-8CV's ~750 Hz update
-- | rate as the natural target frequency.
laneEvents :: Lane -> State -> Array (Event Voltage)
laneEvents lane (State st) =
  case lane.modifier of
    AlwaysOn  -> [ Analog { context: emptyContext, part: st.arc, value: lane.level + lane.offset } ]
    AlwaysOff -> []
    _         -> stepEvents lane st.arc

-- | Generate digital step events for one lane within an arc.  Each
-- | step's voltage is the wave evaluation at phase=0 (i.e. the
-- | event onset) — we'd refine this to a sub-sampled Analog stream
-- | for non-Gate waves in the runtime pass.
stepEvents :: Lane -> Arc -> Array (Event Voltage)
stepEvents lane queryArc =
  let
    stepLen = stepLength lane.modifier
    -- Steps that overlap queryArc.  Keep this simple — the real
    -- evaluator threads RNG state across all steps in a Loop.
    steps = stepArcsInArc stepLen queryArc
    activeMask = euclideanMask lane.euclid (Array.length steps)
  in
    Array.concat $ Array.mapWithIndex (renderStep lane activeMask) steps

renderStep :: Lane -> Array Boolean -> Int -> Arc -> Array (Event Voltage)
renderStep lane mask i arc =
  if not (atIndex mask i) then []
  else
    let v = sampleWaveform lane 0.0
    in [ Digital { context: emptyContext, whole: arc, part: arc, value: v } ]
  where
    atIndex xs n = fromMaybe true (Array.index xs n)

-- | Evaluate the wave at fractional phase 0..1 (where 0 is step
-- | start, 1 is step end).  Returns voltage scaled by `level` plus
-- | `offset`, clamped to 0..1.
sampleWaveform :: Lane -> Number -> Voltage
sampleWaveform lane phase =
  let raw = case lane.wave of
        Gate     -> if phase < lane.width then 1.0 else 0.0
        Triangle -> triangle phase lane.width
        Sine     -> sine phase
        Envelope -> envelope phase lane.width
        Random   -> 0.5  -- placeholder: real RNG threading happens
                         -- in the Loop-aware runtime layer
  in
    clamp01 (raw * lane.level + lane.offset)

triangle :: Number -> Number -> Number
triangle p w =
  if p < w then p / w
  else (1.0 - p) / (1.0 - w)

sine :: Number -> Number
sine p = 0.5 * (1.0 + cosine (2.0 * 3.14159265 * p))
  where
    -- Cell scope doesn't import Math.cos by default; placeholder.
    -- Real implementation: import Math (cos)
    cosine x = 1.0 - 2.0 * (x - 3.14159265) * (x - 3.14159265) / 9.8696
    -- (Taylor approximation; replace with Math.cos in real build.)

envelope :: Number -> Number -> Voltage
envelope phase release =
  if phase < 0.05 then phase / 0.05         -- 5% attack
  else if phase < release
       then 1.0 - (phase - 0.05) / (release - 0.05)
       else 0.0

clamp01 :: Number -> Number
clamp01 x = max 0.0 (min 1.0 x)

-------------------------------------------------------------------------------
-- Helpers — Euclidean mask, step arcs, plumbing
-------------------------------------------------------------------------------

-- | Bjorklund's algorithm.  Returns an array of length `steps` with
-- | `trigs` `true`s distributed as evenly as possible, then rotated.
euclideanMask :: Maybe Euclid -> Int -> Array Boolean
euclideanMask Nothing n = Array.replicate n true
euclideanMask (Just { steps, trigs, rot }) _ =
  rotate rot (bjorklund steps trigs)
  where
    rotate :: Int -> Array Boolean -> Array Boolean
    rotate r xs =
      let len = Array.length xs
          k = if len == 0 then 0 else ((r `mod` len) + len) `mod` len
      in Array.drop k xs <> Array.take k xs

-- | Bjorklund's algorithm — the pulse-distribution heart of
-- | Euclidean rhythms.  Produces `[true × pulses]` distributed
-- | among `[false × (steps - pulses)]` as evenly as possible.
bjorklund :: Int -> Int -> Array Boolean
bjorklund steps pulses
  | pulses <= 0   = Array.replicate steps false
  | pulses >= steps = Array.replicate steps true
  | otherwise     = go (Array.replicate pulses [true]) (Array.replicate (steps - pulses) [false])
  where
    go :: Array (Array Boolean) -> Array (Array Boolean) -> Array Boolean
    go front back =
      let frontLen = Array.length front
          backLen  = Array.length back
          paired   = Array.length (Array.zip front back)
      in
        if paired <= 1 then Array.concat (front <> back)
        else
          let zipped = Array.zip front back
              merged = map (\(Tuple a b) -> a <> b) zipped
              leftover = if frontLen > backLen
                         then Array.drop backLen front
                         else Array.drop frontLen back
          in
            if Array.length leftover <= 1 then Array.concat (merged <> leftover)
            else go merged leftover

-- | How many beats one step takes for a given modifier.  We
-- | normalise to "fraction of a cycle" — a Mul 4 modifier produces
-- | 4 steps per cycle, so step length = 1/4.
stepLength :: Modifier -> Number
stepLength = case _ of
  Mul n        -> 1.0 / fromInt (max 1 n)
  Div n        -> fromInt (max 1 n)
  TripletMul n -> (2.0 / 3.0) / fromInt (max 1 n)
  TripletDiv n -> fromInt (max 1 n) * (2.0 / 3.0)
  DottedMul n  -> (3.0 / 2.0) / fromInt (max 1 n)
  DottedDiv n  -> fromInt (max 1 n) * (3.0 / 2.0)
  AlwaysOn     -> 1.0
  AlwaysOff    -> 1.0
  PulseStart   -> 1.0
  PulseStop    -> 1.0

-- | Step arcs that overlap a query arc — placeholder; the real
-- | implementation lives in Tidal.Pattern.Core.cycleArcsInArc and
-- | needs adaptation for fractional step lengths.
stepArcsInArc :: Number -> Arc -> Array Arc
stepArcsInArc _ _ = []   -- runtime: tile [n*step, (n+1)*step) within arc

-- | Bundle eight per-lane Patterns into a single Pattern emitting
-- | Vec8 voltage snapshots.  Per query, we sample each lane and
-- | merge by event onset time.  Implementation deferred to runtime
-- | pass; here as a typed stub.
bundle :: Array (Pattern Voltage) -> Pattern (Vec8 Voltage)
bundle _ = silence  -- placeholder

-- | Lift the inner array out of a Vec8.
unVec8 :: forall a. Vec8 a -> Array a
unVec8 (Vec8 xs) = xs

-- | Internal: floor of a Number to an Int.  We keep this local so
-- | the sketch doesn't pull in Data.Int just for the Floor case.
floorN :: Number -> Int
floorN n = if n < 0.0 then negate (floorN' (negate n) + 1) - 1 else floorN' n
  where
    floorN' :: Number -> Int
    floorN' _ = 0   -- stub: replace with Data.Int.floor in real impl.

fromInt :: Int -> Number
fromInt _ = 0.0   -- stub: replace with Data.Int.toNumber in real impl.

-- | Stand-in for Tidal.Pattern.Types.emptyContext.  The real module
-- | would import it; we re-declare here to keep the sketch
-- | self-contained.
emptyContext :: forall a. a
emptyContext = unsafeCoerce {}
  where
    unsafeCoerce :: forall b c. b -> c
    unsafeCoerce _ = unsafeCoerce {}   -- intentional: this file is sketch-only

-- | Tuple is referenced once above; declare locally so the sketch
-- | stays single-file.
data Tuple a b = Tuple a b
