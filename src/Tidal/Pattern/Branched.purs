-- | Stream fork/merge: labeled fan-out and re-combination.
-- |
-- | A `Branched a` is a labeled fan-out of patterns, one per `Voice`.
-- | `Voice` is musical identity, late-bound to a destination (synth, sample,
-- | CV/Gate channel) by the binding layer. Composers speak Voice; the
-- | binder maps Voice → Destination.
-- |
-- | Design (full rationale: docs/kb/research/purerl-tidal-fork-merge-design.md):
-- |
-- |   1. `Branched a` is first-class inspectable data. The renderer (Calypso
-- |      Hylograph pane) walks it to build a Sankey of voice flow. Don't
-- |      reduce eagerly to `Pattern (Voice, a)` — that loses the topology.
-- |   2. Insertion order is preserved (Array of pairs, not Map). `alternate`
-- |      visits voices in declared order; renderers display them top-to-bottom
-- |      in declared order. Duplicate Voice keys are allowed and route to
-- |      the same destination (downstream sums them).
-- |   3. No default merge. `mult` is sugar for `merge (fanOut ...)`; a cell
-- |      can also leave `Branched` un-merged for direct per-voice routing.
-- |   4. Stateless branches first (per-voice scope deferred). Means
-- |      correlated random degradation across branches; revisit if
-- |      heterophony feels wrong.
-- |   5. Flat first; nesting (Tree-of-Voice) deferred but the type permits
-- |      it later.
module Tidal.Pattern.Branched
  ( -- * Types
    Voice(..)
  , Branched(..)
    -- * Inspection
  , voices
  , branches
    -- * Construction
  , fanOut
    -- * Merges
  , merge
  , gate
  , crossfade
  , alternate
    -- * Sugar
  , mult
  , jux
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype)
import Data.Rational (toNumber)
import Data.Tuple (Tuple(..), fst, snd)
import Tidal.Core.Types (Time)
import Tidal.Pattern.Core (sam, stack)
import Tidal.Pattern.Types
  ( Arc(..)
  , Pattern
  , State(..)
  , arcStart
  , eventPart
  , eventValue
  , pattern
  , query
  , silence
  )

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

-- | Voice identity. A `String` newtype, late-bound to a destination at the
-- | binding layer.
newtype Voice = Voice String

derive instance newtypeVoice :: Newtype Voice _
derive newtype instance eqVoice :: Eq Voice
derive newtype instance ordVoice :: Ord Voice

instance showVoice :: Show Voice where
  show (Voice s) = "Voice " <> show s

-- | A labeled fan-out of patterns. Order-preserving; duplicate Voice keys
-- | are allowed (sum at the routing layer).
newtype Branched a = Branched (Array (Tuple Voice (Pattern a)))

derive instance newtypeBranched :: Newtype (Branched a) _

instance showBranched :: Show (Branched a) where
  show (Branched bs) =
    "Branched [" <> show (map fst bs) <> "]"

-------------------------------------------------------------------------------
-- Inspection
-------------------------------------------------------------------------------

-- | The voices in this Branched, in declared order.
voices :: forall a. Branched a -> Array Voice
voices (Branched bs) = map fst bs

-- | The (Voice, Pattern) pairs in declared order.
branches :: forall a. Branched a -> Array (Tuple Voice (Pattern a))
branches (Branched bs) = bs

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------

-- | Fan a pattern out into labeled, transformed branches.
-- |
-- | `fanOut [Tuple (Voice "L") identity, Tuple (Voice "R") rev] melody`
-- | yields a two-branch `Branched`: L = the original, R = reversed.
fanOut
  :: forall a
   . Array (Tuple Voice (Pattern a -> Pattern a))
  -> Pattern a
  -> Branched a
fanOut transforms p =
  Branched (map (\(Tuple v f) -> Tuple v (f p)) transforms)

-------------------------------------------------------------------------------
-- Merges
-------------------------------------------------------------------------------

-- | Collapse a Branched into a single Pattern by stacking all branches.
-- | Same shape as upstream Tidal's `stack`. Voice labels are erased here;
-- | use them earlier (or use `crossfade`/`gate`) if they need to survive.
merge :: forall a. Branched a -> Pattern a
merge (Branched bs) = stack (map snd bs)

-- | Per-voice boolean mask. Events from a voice survive only when that
-- | voice's gate pattern is `true` over the event's part.
-- |
-- | Missing-key default: **open**. A gate map that doesn't mention a voice
-- | passes that voice through — adding a voice to fan-out can't accidentally
-- | mute it via an old gate cell.
gate
  :: forall a
   . Map Voice (Pattern Boolean)
  -> Branched a
  -> Pattern a
gate gmap (Branched bs) = stack (map gateOne bs)
  where
    gateOne :: Tuple Voice (Pattern a) -> Pattern a
    gateOne (Tuple v p) = case Map.lookup v gmap of
      Nothing -> p
      Just gp -> maskBy gp p

-- | A `Pattern Voice` selects which branch is audible at each moment.
-- | Voices not present in the `Branched` produce silence.
-- |
-- | Routing-default: silent (per question 2). A `crossfadeWarn` variant
-- | that surfaces missing-voice events to the renderer is a future addition.
crossfade
  :: forall a
   . Pattern Voice
  -> Branched a
  -> Pattern a
crossfade voicePat (Branched bs) = pattern \(State st) ->
  let
    bMap = Map.fromFoldable bs
    voiceEvents = query voicePat (State st)
    processVoiceEvent ve =
      case Map.lookup (eventValue ve) bMap of
        Nothing -> []
        Just p -> query p (State st { arc = eventPart ve })
  in Array.concatMap processVoiceEvent voiceEvents

-- | Round-robin over branches, one per cycle, in declared order.
-- |
-- | Per-cycle granularity matches upstream Tidal's `<a b c>`. Section-scale
-- | alternation (verse/chorus over many cycles) is a separate primitive
-- | class — see kb research note.
alternate :: forall a. Branched a -> Pattern a
alternate (Branched []) = silence
alternate (Branched bs) = pattern \(State st) ->
  let
    n = Array.length bs
    cycleArcs = cyclesInArc st.arc
    processOneCycle cycleArc =
      let
        cyc = sam (arcStart cycleArc)
        idx = mod (floorInt cyc) n
      in case Array.index bs idx of
        Nothing -> []
        Just (Tuple _ p) -> query p (State st { arc = cycleArc })
  in Array.concatMap processOneCycle cycleArcs

-------------------------------------------------------------------------------
-- Sugar
-------------------------------------------------------------------------------

-- | Fan-out + merge in one step. The general primitive; `jux` is a special
-- | case. Subsumes upstream's `jux`, `superimpose`, etc., for stereo or
-- | n-way splits.
mult
  :: forall a
   . Array (Tuple Voice (Pattern a -> Pattern a))
  -> Pattern a
  -> Pattern a
mult ts p = merge (fanOut ts p)

-- | Classic Tidal `jux`: identity on Voice "L", `f` on Voice "R", stacked.
-- | The L/R labels exist so the binding layer can map them to stereo
-- | destinations; on its own `jux` is just sugar.
jux :: forall a. (Pattern a -> Pattern a) -> Pattern a -> Pattern a
jux f = mult [Tuple (Voice "L") identity, Tuple (Voice "R") f]

-------------------------------------------------------------------------------
-- Internal
-------------------------------------------------------------------------------

-- | Mask one pattern by another's boolean events. An event from `p` survives
-- | iff some `true` event in `g` overlaps its part.
maskBy :: forall a. Pattern Boolean -> Pattern a -> Pattern a
maskBy g p = pattern \(State st) ->
  let
    pEvents = query p (State st)
    keep ev =
      let
        gateEvents = query g (State st { arc = eventPart ev })
        gateActive = Array.any eventValue gateEvents
      in if gateActive then [ev] else []
  in Array.concatMap keep pEvents

cyclesInArc :: Arc -> Array Arc
cyclesInArc (Arc { start, stop }) =
  let
    startCycle = sam start
    go acc s =
      if s >= stop
        then acc
        else go
          (acc <> [Arc { start: max start s, stop: min stop (s + one) }])
          (s + one)
  in go [] startCycle

floorInt :: Time -> Int
floorInt t = Int.floor (toNumber t)
