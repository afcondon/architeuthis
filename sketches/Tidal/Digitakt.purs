-- | SKETCH — not yet integrated. Lives in `sketches/`, not `src/`.
-- |
-- | Tidal.Digitakt — Elektron-style sparse-overrides cell vocabulary.
-- |
-- | The Digitakt model rests on three orthogonal mechanisms:
-- |
-- |   1. **Parameter Locks** — sparse per-step overrides over track
-- |      defaults.  Most steps fall through to defaults; a few steps
-- |      carry an explicit `Map Param Value` of overrides.
-- |
-- |   2. **Pattern Pages** — long sequences from short pages.  A
-- |      track's `pages` field is an `Array Page`; each cycle plays
-- |      one page in rotation, giving you 16/32/48/64-step patterns
-- |      from 16-step authoring units.
-- |
-- |   3. **Conditional Trigs** — per-step boolean conditions deciding
-- |      whether the trig fires *this time around*.  Vocabulary:
-- |      `Always | Fill | Pre Bool | Nei TrackIdx Bool | First |
-- |       NotFirst | EveryNthOfM Int Int | Probability Number`.
-- |
-- | Hardware reference: see
-- | docs/sequencer-vocabulary-research-2026-05-09.md §Module 6.
-- |
-- | Status: types and the runDigitakt evaluator sketched; the
-- | conditional-trig evaluator is two-pass (first pass collects per-
-- | step trig decisions across all tracks; second pass evaluates
-- | conditions that depend on cross-track state).
-- |
-- | Phasing recommendation: build (1) P-locks first (~5-6 h), then
-- | (3) conditional trigs (~3-4 h), then (2) pattern pages (~3 h).
-- | All three of these are individually useful; sequence them by
-- | "what unblocks the most musical territory soonest."
module Tidal.Digitakt
  ( -- * Parameter vocabulary
    Param(..)
    -- * Steps
  , Step
  , defaultStep
  , withLocks
  , withCondition
  , withMicroT
  , withRetrig
  , locks
    -- * Conditional trigs
  , TrigCondition(..)
    -- * Pages and tracks
  , Page
  , mkPage
  , Track
  , defaultTrack
  , TrackIdx(..)
    -- * Whole-instrument
  , Digitakt
  , mkDigitakt
    -- * Run
  , runDigitakt
    -- * Convenience
  , trig
  , noTrig
  , p
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Tidal.Pattern.Types
  ( Pattern, Value(..), Note, mkNote, pattern, query, Event(..), State(..)
  , eventValue)

-------------------------------------------------------------------------------
-- Parameter vocabulary — closed ADT for what's lockable
-------------------------------------------------------------------------------

-- | Track parameters.  Closed ADT so we can pattern-match
-- | exhaustively in the evaluator and reject typos at compile time.
-- |
-- | The set here mirrors a Digitakt audio track at first
-- | approximation; we add MIDI/synth params as we wire those tracks
-- | up.  In the live-coding context, "parameter" is whatever the
-- | rig adapter understands — we keep the ADT open enough to expand.
data Param
  -- Pitch + timing
  = PNote          -- MIDI note
  | PVelocity      -- 0..127
  | PNoteLength    -- 0..1 of step duration
  -- Sample (for sample tracks)
  | PSample        -- sample slot index
  | PSampleStart   -- 0..1 sample position
  | PSampleLength  -- 0..1 sample length
  | PSamplePitch   -- semitone offset
  -- Filter
  | PFilterCut
  | PFilterRes
  | PFilterType    -- 0..N type index
  -- Amp envelope
  | PAmpAttack
  | PAmpHold
  | PAmpRelease
  | PAmpVolume
  | PAmpPan
  -- LFO
  | PLfoSpeed
  | PLfoMul
  | PLfoFade
  | PLfoDest       -- closed enum encoded as Int for now
  | PLfoWave
  | PLfoStart
  | PLfoMode
  | PLfoDepth

derive instance eqParam :: Eq Param
derive instance ordParam :: Ord Param

instance showParam :: Show Param where
  show = case _ of
    PNote          -> "note"
    PVelocity      -> "vel"
    PNoteLength    -> "len"
    PSample        -> "sample"
    PSampleStart   -> "smpStart"
    PSampleLength  -> "smpLen"
    PSamplePitch   -> "smpPitch"
    PFilterCut     -> "filterCut"
    PFilterRes     -> "filterRes"
    PFilterType    -> "filterType"
    PAmpAttack     -> "ampAtk"
    PAmpHold       -> "ampHold"
    PAmpRelease    -> "ampRel"
    PAmpVolume     -> "ampVol"
    PAmpPan        -> "ampPan"
    PLfoSpeed      -> "lfoSpd"
    PLfoMul        -> "lfoMul"
    PLfoFade       -> "lfoFade"
    PLfoDest       -> "lfoDest"
    PLfoWave       -> "lfoWave"
    PLfoStart      -> "lfoStart"
    PLfoMode       -> "lfoMode"
    PLfoDepth      -> "lfoDepth"

-------------------------------------------------------------------------------
-- Conditional trigs
-------------------------------------------------------------------------------

-- | The Elektron conditional-trig vocabulary.  These conditions are
-- | what makes Digitakt patterns musically interesting beyond the
-- | usual "step on / step off" of classic step sequencers.
data TrigCondition
  = Always
  | Fill                 -- only when fill mode is engaged
  | Pre Boolean          -- True = "if previous trig played",
                         -- False = "if previous did not play"
  | Nei TrackIdx Boolean -- coupling to another track's last decision
  | First                -- only on the first cycle
  | NotFirst             -- only on cycles 2..
  | EveryNthOfM Int Int  -- A:B — the A-th of every B cycles
  | Probability Number   -- 0..1 — random per-step

derive instance eqTrigCondition :: Eq TrigCondition

-------------------------------------------------------------------------------
-- Step
-------------------------------------------------------------------------------

-- | One step: a sparse map of parameter overrides plus a condition
-- | and timing modifiers.  Steps are stored in pages; a `Just step`
-- | at page index N means "trig at step N (subject to condition)";
-- | a `Nothing` means "no trig at all."
type Step =
  { locks  :: Map Param Value
  , cond   :: TrigCondition
  , microT :: Number              -- -0.5..+0.5 of step duration
  , retrig :: Maybe Int           -- N micro-trigs within this step
  }

-- | A bare trig: no overrides, no condition, no timing offset, no
-- | retrig.  This plus `withLocks`/`withCondition`/etc. is the
-- | author-by-builder idiom.
defaultStep :: Step
defaultStep =
  { locks: Map.empty
  , cond: Always
  , microT: 0.0
  , retrig: Nothing
  }

-- | Add (or replace) parameter locks on a step.  Right-biased: any
-- | existing lock for a param is overwritten by the new value.
withLocks :: Map Param Value -> Step -> Step
withLocks ls s = s { locks = Map.union ls s.locks }

-- | Set the conditional-trig.
withCondition :: TrigCondition -> Step -> Step
withCondition c s = s { cond = c }

-- | Set micro-timing (-0.5..+0.5 of step duration).
withMicroT :: Number -> Step -> Step
withMicroT t s = s { microT = max (-0.5) (min 0.5 t) }

-- | Set retrig count (Just N = N micro-trigs within this step).
withRetrig :: Int -> Step -> Step
withRetrig n s = s { retrig = Just (max 1 n) }

-- | Convenience: build a single-lock map.
locks :: Param -> Value -> Map Param Value
locks param v = Map.singleton param v

-- | Pair-builder for inline lock construction.
p :: Param -> Value -> Tuple Param Value
p = Tuple

-------------------------------------------------------------------------------
-- Page — 16 steps
-------------------------------------------------------------------------------

-- | A page is exactly 16 step slots.  We don't use a refined-length
-- | type; `mkPage` truncates / right-pads with `Nothing`.
newtype Page = Page (Array (Maybe Step))

mkPage :: Array (Maybe Step) -> Page
mkPage xs = Page (Array.take 16 (xs <> Array.replicate 16 Nothing))

-- | Convenience to build a page from a sparse `Array (Tuple Int Step)`
-- | of (stepIndex, step).  Cleaner authoring when only a few steps
-- | are populated.
sparsePage :: Array (Tuple Int Step) -> Page
sparsePage entries =
  let
    indexed = Array.foldl insert (Array.replicate 16 Nothing) entries
    insert acc (Tuple i s) =
      if i < 0 || i >= 16 then acc
      else fromMaybe acc (Array.modifyAt i (\_ -> Just s) acc)
  in
    Page indexed

-------------------------------------------------------------------------------
-- Track
-------------------------------------------------------------------------------

newtype TrackIdx = TrackIdx Int

derive instance eqTrackIdx :: Eq TrackIdx
derive instance ordTrackIdx :: Ord TrackIdx
instance showTrackIdx :: Show TrackIdx where
  show (TrackIdx n) = "track[" <> show n <> "]"

-- | A track: defaults (the "parameter pages" values you set
-- | globally), plus an array of pages played in rotation.  Each
-- | page is 16 steps; total pattern length per cycle = `length`,
-- | which can be less than 16 to create per-track polyrhythms
-- | (e.g. a 13-step track inside a 16-step pattern).
type Track =
  { defaults :: Map Param Value
  , pages    :: Array Page
  , length   :: Int                -- per-cycle step count, 1..16
  }

-- | Empty track at length 16 with no pages, no defaults.  Caller
-- | provides a sample/note default.
defaultTrack :: Track
defaultTrack =
  { defaults: Map.empty
  , pages: [ mkPage [] ]
  , length: 16
  }

-------------------------------------------------------------------------------
-- Whole instrument
-------------------------------------------------------------------------------

-- | A Digitakt is N tracks plus a global BPM.  Eight tracks is the
-- | hardware's count; we don't enforce that.
type Digitakt =
  { tracks :: Array Track
  , bpm    :: Number
  }

mkDigitakt :: Number -> Array Track -> Digitakt
mkDigitakt bpm ts = { tracks: ts, bpm }

-------------------------------------------------------------------------------
-- Run — the evaluator
-------------------------------------------------------------------------------

-- | Render a Digitakt configuration as a Pattern of per-track,
-- | per-event parameter maps.  Each event in the output carries:
-- | which track triggered, and the effective parameter map (defaults
-- | merged with this step's locks, with the conditional decision
-- | already evaluated).
-- |
-- | Implementation in two passes:
-- |
-- |   1. **Decision pass** — for each (cycle, track, step), determine
-- |      whether the trig fires.  This pass needs cross-track state
-- |      because `Nei` conditions look at neighbouring tracks'
-- |      decisions on the same step.  We resolve dependencies in a
-- |      fixed iteration order (track 0, track 1, ...) and treat
-- |      forward references as `false` to avoid cycles.
-- |
-- |   2. **Emission pass** — for each (cycle, track, step) where
-- |      the trig fires, emit a Pattern event carrying the merged
-- |      parameter map.
-- |
-- | The output is a `Pattern (TrackIdx, Map Param Value)`.  Rig
-- | binding (downstream) splits this into per-track CV/gate streams.
runDigitakt :: Digitakt -> Pattern { track :: TrackIdx, params :: Map Param Value }
runDigitakt _dt = pattern \_st ->
  -- Stub for the sketch.  The real implementation:
  --   1. From the query state, determine the cycle range.
  --   2. For each cycle in the range:
  --      a. For each track, consult its pages[cycleIndex `mod` numPages]
  --      b. For each populated step in that page:
  --         - Evaluate condition (using the previous-step decisions
  --           cached from this same pass).
  --         - If true: merge defaults with locks, emit Digital event
  --           with appropriate `whole` and `part` arcs.
  --      c. Cache this track's per-step decisions for `Nei` lookups.
  []

-------------------------------------------------------------------------------
-- Conditional-trig evaluation (sketch)
-------------------------------------------------------------------------------

-- | Decide whether a step fires this cycle.  Pure; uses the step's
-- | condition + the cycle context (which cycle is this, what did
-- | the previous step / neighbouring track do, whether fill is
-- | engaged, the seeded RNG state).
evaluateCondition
  :: TrigCondition
  -> { cycle :: Int
     , prevPlayed :: Boolean
     , neighbourPlayed :: TrackIdx -> Boolean
     , fillActive :: Boolean
     , rngSeed :: Int
     }
  -> Boolean
evaluateCondition cond ctx = case cond of
  Always              -> true
  Fill                -> ctx.fillActive
  Pre b               -> ctx.prevPlayed == b
  Nei tIdx b          -> ctx.neighbourPlayed tIdx == b
  First               -> ctx.cycle == 0
  NotFirst            -> ctx.cycle > 0
  EveryNthOfM a m     ->
    let k = if m <= 0 then 1 else m
        target = ((a - 1) `mod` k + k) `mod` k
    in (ctx.cycle `mod` k) == target
  Probability prob    -> seededRand ctx.rngSeed < prob

-- | A deterministic RNG draw from a seed, returning a Number in [0,1).
-- | Stub: the real implementation threads this through the same
-- | seeded-RNG infrastructure DEJA VU and Pam-with-Loop will use.
seededRand :: Int -> Number
seededRand _ = 0.5   -- placeholder

-- | Convenience: a step at a position in a page.
trig :: Int -> Step -> Tuple Int Step
trig = Tuple

-- | Pseudo-builder for clarity at the call site: "this step has no
-- | trig" — used in dense pages where you want positional clarity.
noTrig :: Maybe Step
noTrig = Nothing

-------------------------------------------------------------------------------
-- Examples (exposed for documentation)
-------------------------------------------------------------------------------

-- | A simple kick on beats 1, 5, 9, 13 with one step pitched up
-- | (step 9) and one step conditional on every-fourth-cycle (step 13).
exampleKick :: Track
exampleKick =
  { defaults: Map.fromFoldable
      [ Tuple PSample (VInt 0)
      , Tuple PNote (VNote (mkNote 36))     -- C2
      , Tuple PAmpVolume (VNumber 0.9)
      , Tuple PFilterCut (VNumber 0.6)
      ]
  , pages:
      [ sparsePage
          [ trig 0 defaultStep
          , trig 4 defaultStep
          , trig 8  (defaultStep `withLocks`
                       Map.singleton PNote (VNote (mkNote 48)))   -- C3 pitched up
          , trig 12 (defaultStep `withCondition` EveryNthOfM 1 4) -- only every 4th cycle
          ]
      ]
  , length: 16
  }

-- | A snare that fires only when its neighbour (track 0, the kick)
-- | also fires on the same step.  Demonstrates Nei conditional.
exampleSnare :: Track
exampleSnare =
  { defaults: Map.fromFoldable
      [ Tuple PSample (VInt 1)
      , Tuple PNote (VNote (mkNote 38))      -- D2
      , Tuple PAmpVolume (VNumber 0.7)
      ]
  , pages:
      [ sparsePage
          [ trig 4  (defaultStep `withCondition` Nei (TrackIdx 0) true)
          , trig 12 (defaultStep `withCondition` Nei (TrackIdx 0) true)
          ]
      ]
  , length: 16
  }

-- | A four-page hat track, simulating a 64-step pattern that cycles
-- | through verse / pre-chorus / chorus / bridge variations.  This
-- | is the pattern-page mechanism: one cycle of the song advances
-- | one page, returning to page 0 on cycle 4.
exampleSongHat :: Track
exampleSongHat =
  { defaults: Map.fromFoldable
      [ Tuple PSample (VInt 2)
      , Tuple PAmpVolume (VNumber 0.5)
      ]
  , pages:
      [ pageVerse
      , pagePreChorus
      , pageChorus
      , pageBridge
      ]
  , length: 16
  }
  where
    pageVerse      = mkPage []                                    -- silent in verse
    pagePreChorus  = sparsePage [ trig 8 defaultStep ]             -- one hit
    pageChorus     = sparsePage
                       [ trig 0  defaultStep, trig 4  defaultStep
                       , trig 8  defaultStep, trig 12 defaultStep ] -- four-on-the-floor
    pageBridge     = sparsePage
                       [ trig 2 defaultStep, trig 6 defaultStep
                       , trig 10 defaultStep, trig 14 defaultStep ] -- offbeat

-- | A complete Digitakt instrument with kick, snare, and song-hat.
exampleSong :: Digitakt
exampleSong = mkDigitakt 120.0
  [ exampleKick
  , exampleSnare
  , exampleSongHat
  ]
