-- | `Tidal.Vetula.Pattern` — V-D slab.
-- |
-- | Makes Vetula a first-class `Notation` in the substrate.  A
-- | `VetulaPart` carries a Key + Progression + VoicingStrategy +
-- | centre octave; the `Notation` instance produces a
-- | `Pattern PitchedNote12` whose each chord is a `stack` of N
-- | parallel `Chromatic` events, sequenced via `cat` across the
-- | progression.
-- |
-- | Vetula sidesteps the per-vmod Erlang gen_server path used by
-- | Balistes / Odonus / Selene.  Those vocabularies are algorithmic
-- | (Markov, Cartesian-walk, config snapshots) and need their own
-- | tick logic.  Vetula is **fully determined at registration**:
-- | given Key + Progression + Strategy, every voicing is fixed.
-- | So it slots into the existing Pattern substrate directly and
-- | gets the MIDI scheduler / SuperDirt emit / timing stack for free.
-- |
-- | `vetula key progression voicing >> piano1` produces a
-- | `String -> PitchedPart PitchedNote12` (via the
-- | `routedInstrument` instance from `Calypso.Prelude`) — drop the
-- | resulting PitchedPart into a `Session`'s `parts` field and the
-- | substrate plays it.
-- |
-- | See `atlantis-site-planning/vetula-design.md` §"Integration
-- | shapes" for the routing patterns this enables.
module Tidal.Vetula.Pattern
  ( VetulaPart(..)
  , vetula
  , vetulaWith
  , vetulaPattern
  , vetulaSplit
  , vetulaArp
  , vetulaEuclid
  , vetulaHeld
  , voicingAsStack
  , voicingAsArp
  , voicingAsStabs
  ) where

import Prelude

import Data.Array (cons)
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Rational (fromInt)
import Data.Set as Set

import Tidal.Notation (class Notation)
import Tidal.Pattern.Core (cat, fastCat, repeatEvery, silence, stack)
import Tidal.Pattern.Types
  ( Arc(..)
  , Event(..)
  , Pattern
  , State(..)
  , emptyContext
  , pattern
  )
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Vetula (Key, realize)
import Tidal.Vetula.Voicing
  ( Progression
  , Selector
  , Voicing(..)
  , VoicingStrategy
  , closeVoicing
  , takeVoicing
  , voiceLead
  )

-- ---------------------------------------------------------------------------
-- VetulaPart — the user-facing declaration
-- ---------------------------------------------------------------------------

-- | A Vetula declaration.  Holds the key, the progression (an array
-- | of chord recipes), the voicing strategy applied to the first
-- | chord, and the centre octave for the initial close-position
-- | voicing.  Subsequent voicings drift via voice-leading from the
-- | previous one.
-- |
-- | The design doc's `in:` field is rendered as `key:` here — `in`
-- | is a PureScript keyword and not safe as a record field name.
newtype VetulaPart = VetulaPart
  { key         :: Key
  , progression :: Progression
  , voicing     :: VoicingStrategy
  , octave      :: Int
  }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

-- | Positional constructor with octave defaulted to 4 (the middle-C
-- | octave).  Best for inline cell-text use.
vetula :: Key -> Progression -> VoicingStrategy -> VetulaPart
vetula k prog strat = VetulaPart
  { key:         k
  , progression: prog
  , voicing:     strat
  , octave:      4
  }

-- | Record-literal constructor — full control of all fields.  Match
-- | the design doc's "canonical record-literal form" shape:
-- | `vetulaWith { key, progression, voicing, octave }`.
vetulaWith
  :: { key :: Key
     , progression :: Progression
     , voicing :: VoicingStrategy
     , octave :: Int
     }
  -> VetulaPart
vetulaWith = VetulaPart

-- ---------------------------------------------------------------------------
-- Pattern realisation
-- ---------------------------------------------------------------------------

-- | The headline derivation.  Builds the chord sequence with
-- | voice-leading from a centred initial voicing, then turns each
-- | voicing into a parallel stack of `Chromatic` events.  Empty
-- | progression yields silence.
-- |
-- | **One chord per cycle** — uses `Tidal.Pattern.Core.cat` which is
-- | slow-cat: a 4-chord progression plays over 4 cycles (= 4 bars
-- | at the default cps).  Wrap with `fast` at the call site to
-- | compress (`fast 4 (vetulaPattern v)` plays the whole progression
-- | per cycle).
vetulaPattern :: VetulaPart -> Pattern PitchedNote12
vetulaPattern (VetulaPart r) =
  case Array.uncons r.progression of
    Nothing -> silence
    Just { head: firstDc, tail: rest } ->
      let
        firstV = r.voicing (closeVoicing { centre: r.octave } (realize r.key firstDc))
        voicings = cons firstV
          (Array.scanl (\prev dc -> voiceLead prev (realize r.key dc))
                       firstV rest)
      in
        cat (map voicingAsStack voicings)

-- | Like `vetulaPattern` but applies a Selector to every voicing post
-- | voice-leading.  Used to split a Vetula progression into per-voice-
-- | group streams routed to different Instruments.
-- |
-- |   bass  = on vBass  bassChan  (vetulaSplit (TakeLow 1) prog)
-- |   upper = on vUpper upperChan (vetulaSplit (DropS (TakeLow 1)) prog)
-- |
-- | Selection happens *after* voice-leading, so the bass voice and the
-- | upper voices stay consistent with the same global voice-leading
-- | decisions — they're just routed to different sinks.
vetulaSplit :: Selector -> VetulaPart -> Pattern PitchedNote12
vetulaSplit sel (VetulaPart r) =
  case Array.uncons r.progression of
    Nothing -> silence
    Just { head: firstDc, tail: rest } ->
      let
        firstV = r.voicing (closeVoicing { centre: r.octave } (realize r.key firstDc))
        voicings = cons firstV
          (Array.scanl (\prev dc -> voiceLead prev (realize r.key dc))
                       firstV rest)
      in
        cat (map (voicingAsStack <<< takeVoicing sel) voicings)

-- | One voicing → a Pattern that emits all its notes simultaneously.
-- | The chord's N MIDI numbers become N parallel `pure (Chromatic n)`
-- | sub-patterns, stacked.
voicingAsStack :: Voicing -> Pattern PitchedNote12
voicingAsStack (Voicing midis) = case midis of
  [] -> silence
  _  -> stack (map (pure <<< Chromatic) midis)

-- | One voicing → a Pattern that arpeggiates its notes ascending across
-- | the cycle slot.  Each note takes 1/N of the chord's time; the
-- | natural ascending arp falls out of the Voicing's sorted order.
-- |
-- | Combined with `cat` at the progression level: outer cat puts one
-- | chord per cycle, inner fastCat fits the chord's N notes inside it.
voicingAsArp :: Voicing -> Pattern PitchedNote12
voicingAsArp (Voicing midis) = case midis of
  [] -> silence
  _  -> fastCat (map (pure <<< Chromatic) midis)

-- | One voicing → Euclidean(k, n) stabs across the cycle slot.  N
-- | evenly-spaced positions, K of them fire the chord (as a stack),
-- | the rest are silence.  Bjorklund distribution.
voicingAsStabs :: Int -> Int -> Voicing -> Pattern PitchedNote12
voicingAsStabs k n v =
  let
    stab = voicingAsStack v
    pattern = bjorklund (max 0 (min n k)) (max 1 n)
    slot b = if b then stab else silence
  in
    fastCat (map slot pattern)

-- | Like `vetulaPattern` but with **common-tone sustain**: a MIDI note
-- | that appears in two adjacent voicings is emitted as a single
-- | Pattern event whose whole-arc spans both cycles, instead of being
-- | retriggered.  Notes that change between chords still fire fresh.
-- |
-- | Definition is pitch-based, not voice-position based: a "held" note
-- | is one whose MIDI number is present in both the current and next
-- | voicing.  This is the correct musical definition of a common tone
-- | (Bach's "C major → A minor: C and E hold, G moves to A") and is
-- | robust to voice-count changes between chords — voice-leading's
-- | fallback `closeVoicing` on size mismatch doesn't break the
-- | sustain logic, because we never assume per-position correspondence.
-- |
-- | Note: the substrate's emit path uses Instrument.defDurMs for note
-- | length, not the Pattern's whole-arc.  To hear the sustain, route to
-- | an Instrument with a long defDurMs (≥ one full cycle's worth of
-- | milliseconds at the current cps).  The Pattern's whole-arc still
-- | controls *retrigger timing* — a held note doesn't get a new
-- | Note-On at the cycle boundary because there's no new event there.
vetulaHeld :: VetulaPart -> Pattern PitchedNote12
vetulaHeld (VetulaPart r) =
  case Array.uncons r.progression of
    Nothing -> silence
    Just { head: firstDc, tail: rest } ->
      let
        firstV = r.voicing (closeVoicing { centre: r.octave } (realize r.key firstDc))
        voicings :: Array Voicing
        voicings = cons firstV
          (Array.scanl (\prev dc -> voiceLead prev (realize r.key dc))
                       firstV rest)
        -- Every MIDI number that appears anywhere in the progression.
        allMidis :: Array Int
        allMidis = Set.toUnfoldable
          (Set.fromFoldable
            (Array.concatMap (\(Voicing xs) -> xs) voicings))
        -- For each MIDI, collapse presence-across-cycles into runs and
        -- build one Pattern event per run.
        runsForMidi :: Int -> Array { midi :: Int, startCycle :: Int, runLen :: Int }
        runsForMidi m = collapseRuns m
          (Array.mapWithIndex
            (\i (Voicing xs) -> if Array.elem m xs then Just i else Nothing)
            voicings)
        allRuns :: Array { midi :: Int, startCycle :: Int, runLen :: Int }
        allRuns = Array.concatMap runsForMidi allMidis
        progLen = Array.length voicings
      in
        sustainedPattern progLen allRuns

-- | Collapse an Array (Maybe Int) of per-cycle presence indices into
-- | runs of consecutive present cycles.  Each Just i means "this MIDI
-- | is present at cycle i"; Nothing means "absent here".  Output is
-- | one record per maximal consecutive run.
collapseRuns
  :: Int
  -> Array (Maybe Int)
  -> Array { midi :: Int, startCycle :: Int, runLen :: Int }
collapseRuns m presence =
  let
    step
      :: { runs :: Array { midi :: Int, startCycle :: Int, runLen :: Int }
         , current :: Maybe { start :: Int, len :: Int }
         }
      -> Maybe Int
      -> { runs :: Array { midi :: Int, startCycle :: Int, runLen :: Int }
         , current :: Maybe { start :: Int, len :: Int }
         }
    step acc = case _ of
      Just i -> case acc.current of
        Just c  -> acc { current = Just (c { len = c.len + 1 }) }
        Nothing -> acc { current = Just { start: i, len: 1 } }
      Nothing -> flushCurrent acc
    flushCurrent acc = case acc.current of
      Just c  -> { runs: Array.snoc acc.runs
                    { midi: m, startCycle: c.start, runLen: c.len }
                 , current: Nothing }
      Nothing -> acc
    final = Array.foldl step { runs: [], current: Nothing } presence
  in
    (flushCurrent final).runs

-- | Build a Pattern from a flat list of sustained-note runs.  Each run
-- | produces *one* Digital event at its start cycle, with whole arc
-- | spanning only that one cycle (not the full run).
-- |
-- | Why one cycle, not the run length: the voice gen_server's emit
-- | loop re-discovers events every tick by intersecting the query
-- | window with each event's part arc.  A multi-cycle whole arc would
-- | get re-dispatched at every cycle boundary it crosses, defeating
-- | the "held" effect.  Single-cycle wholes at run *starts* mean each
-- | held note gets exactly one Note-On; the Instrument's long defDurMs
-- | then carries the sustain audibly through the rest of the run.
-- |
-- | Proper substrate-level hold-across (where the *Pattern* asserts
-- | "this note holds for N cycles" and the emit path honours that)
-- | requires either filtering events by whole.start in the voice
-- | gen_server or carrying per-event noteLength (task #88).
sustainedPattern
  :: Int
  -> Array { midi :: Int, startCycle :: Int, runLen :: Int }
  -> Pattern PitchedNote12
sustainedPattern progLen runs = repeatEvery progLen single
  where
    -- Single iteration: emit one event per run at its start cycle.
    -- `repeatEvery progLen` then loops this across all subsequent
    -- progression iterations.
    single = pattern \(State st) ->
      Array.concatMap (eventFor st.arc) runs
    eventFor qArc run =
      let
        whole = Arc { start: fromInt run.startCycle
                    , stop:  fromInt (run.startCycle + 1)
                    }
      in
        case arcIntersect qArc whole of
          Nothing   -> []
          Just part -> [ Digital
                          { context: emptyContext
                          , whole
                          , part
                          , value: Chromatic run.midi
                          }
                       ]

-- | Half-open arc intersection.  Returns Nothing for non-overlapping or
-- | degenerate (zero-length) arcs.  Pattern.Types has `sectArc` but it's
-- | not in the export list, so we inline.
arcIntersect :: Arc -> Arc -> Maybe Arc
arcIntersect (Arc a) (Arc b) =
  let
    start = max a.start b.start
    stop  = min a.stop  b.stop
  in
    if start < stop
      then Just (Arc { start, stop })
      else Nothing

-- | Euclidean rhythm: distribute k hits as evenly as possible over n
-- | steps.  Closed-form Toussaint formulation: position i has a hit
-- | iff (i * k) mod n < k.  Equivalent to Bjorklund without the
-- | recursive group-shuffling.
-- |
-- |   bjorklund 3 8  = [T F F T F F T F]  -- tresillo
-- |   bjorklund 3 4  = [T F T T]
-- |   bjorklund 5 16 = [T F F F T F F T F F T F F T F F]  -- bossa
bjorklund :: Int -> Int -> Array Boolean
bjorklund k n
  | n <= 0    = []
  | k <= 0    = Array.replicate n false
  | k >= n    = Array.replicate n true
  | otherwise = map (\i -> (i * k) `mod` n < k) (Array.range 0 (n - 1))

-- | Like `vetulaPattern` but renders each voicing as an ascending arp
-- | instead of a parallel stack.  Same voice-leading, same progression
-- | structure — just the within-cycle realisation differs.
-- |
-- | The note duration is governed by the Instrument's defDurMs, not by
-- | the Pattern's whole-arc length (substrate limitation — see
-- | task #88, `noteLength`).  Use a shorter defDurMs (~300-500ms) on
-- | the routing Instrument for a clean arp at the default cps.
vetulaArp :: VetulaPart -> Pattern PitchedNote12
vetulaArp (VetulaPart r) =
  case Array.uncons r.progression of
    Nothing -> silence
    Just { head: firstDc, tail: rest } ->
      let
        firstV = r.voicing (closeVoicing { centre: r.octave } (realize r.key firstDc))
        voicings = cons firstV
          (Array.scanl (\prev dc -> voiceLead prev (realize r.key dc))
                       firstV rest)
      in
        cat (map voicingAsArp voicings)

-- | Like `vetulaPattern` but fires each chord as Euclidean(k, n) stabs
-- | within its cycle slot.  k of n evenly-spaced positions are kept,
-- | the rest become silence.  Classic Tidal idiom (`chord # euclid(3,8)`).
-- |
-- | `vetulaEuclid 3 8 prog` produces 8 evenly-spaced slots per cycle,
-- | with the chord firing on 3 of them at Bjorklund-distributed
-- | positions (typically beats 1, 4, 7 for the 3-8 case).
vetulaEuclid :: Int -> Int -> VetulaPart -> Pattern PitchedNote12
vetulaEuclid k n (VetulaPart r) =
  case Array.uncons r.progression of
    Nothing -> silence
    Just { head: firstDc, tail: rest } ->
      let
        firstV = r.voicing (closeVoicing { centre: r.octave } (realize r.key firstDc))
        voicings = cons firstV
          (Array.scanl (\prev dc -> voiceLead prev (realize r.key dc))
                       firstV rest)
      in
        cat (map (voicingAsStabs k n) voicings)

-- ---------------------------------------------------------------------------
-- Notation instance — the substrate hook
-- ---------------------------------------------------------------------------

-- | Vetula is a `Notation` over `PitchedNote12`.  This is the
-- | substrate handshake — anywhere the system accepts a Notation
-- | (cell text, `>>` routing, Pattern combinators), Vetula slots in.
-- |
-- | Combined with `routedInstrument` from `Calypso.Prelude`:
-- |
-- |   vetula key prog strat >> piano1
-- |     :: String -> PitchedPart PitchedNote12
instance notationVetulaPart :: Notation VetulaPart PitchedNote12 where
  toPattern = vetulaPattern
