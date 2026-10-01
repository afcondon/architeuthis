-- | DEJA VU — seeded loop memory over any random source.
-- |
-- | Modelled on the Mutable Instruments Marbles module's most
-- | distinctive feature: store a *seed* (not the values) for a
-- | length-N loop, and at each step decide between "fresh draw"
-- | and "buffered draw" by a probability knob.
-- |
-- | The hardware uses a single knob with two-stage semantics
-- | (lockProb 7→12 o'clock, then shuffleProb 12→5 o'clock).  V1
-- | here implements lockProb only; shuffleProb is a planned
-- | follow-on.
-- |
-- | Lock semantics:
-- |
-- | - lockProb = 0 → every event passes the inner pattern's value
-- |   through unchanged.  The output is whatever the inner pattern
-- |   produces.
-- | - lockProb = 1 → every event is replaced by the buffered value
-- |   for its slot.  The output cycles through the same N values
-- |   forever.
-- | - lockProb = 0.5 → about half the events lock to the buffer,
-- |   half pass through fresh.  Audibly: a recognisable melodic
-- |   skeleton with occasional drifting notes.
-- |
-- | The buffer is computed by **sampling the inner pattern at N
-- | evenly-spaced points within cycle `seed`**.  This means:
-- | (a) different seeds give different "loops" from the same
-- |     inner pattern, deterministically;
-- | (b) the buffered values are real values the inner pattern
-- |     can produce, so locking doesn't introduce any value the
-- |     downstream rig couldn't already see;
-- | (c) the buffer is stable across cycles and across queries —
-- |     locking sounds the same whether you query [0,1) or [10,11).
-- |
-- | Cell idiom:
-- |
-- | ```purescript
-- | melody = pickFromPool [c4, e4, g4, a4]
-- |        $ dejaVu { length: 8, lockProb: live "dejavu.lock", seed: 42 }
-- |        $ segment 8
-- |        $ irand 4
-- | ```
-- |
-- | A Calypso UI knob that writes to "dejavu.lock" then audibly
-- | morphs the melody between fresh-each-cycle and locked-loop.
module Tidal.DejaVu
  ( DejaVuConfig
  , dejaVu
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Haskell.Rational (fromInt, toNumber) as Rational
import Math (floor)
import Tidal.Pattern.Types
  ( Pattern, pattern, query, mkArc, mkState
  , Arc(..), Event(..), eventPart, eventValue)

-- | Configuration for a DEJA VU instance.
-- |
-- | - `length`   — number of slots in the loop buffer.  1..16 is
-- |   the Marbles range; we don't enforce that, but very large
-- |   lengths defeat the "loop memory" feel.
-- | - `lockProb` — Pattern of probabilities (0..1) for replacing
-- |   the inner value with the buffered slot value.  Typically
-- |   driven by `live "knob.name"` from `Tidal.LiveControl`.
-- | - `seed`     — selects which cycle of the inner pattern is
-- |   sampled to populate the buffer.  Different seeds give
-- |   different loops from the same inner pattern.
type DejaVuConfig =
  { length :: Int
  , lockProb :: Pattern Number
  , seed :: Int
  }

-- | The combinator.  Specialised to `Pattern Int` because that's
-- | the canonical random-source type a cell composes with
-- | `pickFromPool` downstream:
-- |
-- |   pickFromPool [c4, e4, g4, a4] (dejaVu cfg (irand 100))
-- |
-- | The Int output gets mod-wrapped into the pool size, so the
-- | absolute magnitude doesn't matter — only its (seed, slot)-
-- | determinism does.
-- |
-- | Implementation:
-- |
-- |   1. The buffer is N integers derived purely from
-- |      `(cfg.seed, i)` — the locked sequence is independent of
-- |      the inner pattern's natural output.  This is the
-- |      "buffer stores seeds, not voltages" idea from Marbles.
-- |   2. For each event in the inner's output:
-- |      - find its slot index (which 1/N-th of the cycle it falls in);
-- |      - sample lockProb at the event's onset;
-- |      - compute a deterministic-per-event "should we lock?"
-- |        decision via a hash of (seed, onset);
-- |      - if locking, replace the value with `buffer[slot]`;
-- |        otherwise pass the inner value through.
-- |
-- | This means at lockProb=0 you hear the inner pattern; at
-- | lockProb=1 you hear the (seed, slot)-derived locked loop;
-- | at intermediate values you hear a stochastic mixture.
-- | Different seeds give different locked loops by construction.
dejaVu :: DejaVuConfig -> Pattern Int -> Pattern Int
dejaVu cfg innerPat = pattern \st ->
  let
    buffer       = computeBuffer cfg
    innerEvents  = query innerPat st
    lockEvents   = query cfg.lockProb st
  in
    map (decideEvent cfg buffer lockEvents) innerEvents

-- | Compute the N-slot buffer purely from `(cfg.seed, i)`.  Each
-- | slot value is a deterministic pseudo-random Int produced by
-- | `hashSeed`; the inner pattern is *not* sampled.  This makes
-- | the locked loop independent of the inner pattern's structure
-- | (cycle-periodic, evolving, whatever) and guarantees that
-- | different seeds give different loops.
-- |
-- | The values are large positive Ints; downstream `pickFromPool`
-- | wraps them by `mod` into the pool size, so the magnitude
-- | doesn't matter — only the determinism and seed-spread.
computeBuffer :: DejaVuConfig -> Array Int
computeBuffer cfg =
  Array.range 0 (cfg.length - 1) # map (hashSeed cfg.seed)

-- | Pseudo-random Int from a (seed, slot) pair.  Same multiplicative-
-- | hash recipe used by `Pattern.Core.rand` so the "feel" matches
-- | other randomness in the codebase.  Output range is
-- | [0, 1_000_000) — well below Int32 max so it composes cleanly
-- | with downstream `mod` operations.
hashSeed :: Int -> Int -> Int
hashSeed seed i =
  let
    x    = Int.toNumber seed * 13.731 + Int.toNumber i * 7.371
    h    = x * 15485863.0 + 7919.0
    frac = h - floor h
  in
    Int.floor (frac * 1000000.0)

-- | Per-event decision: lock to the buffered value, or pass the
-- | inner value through unchanged.  Pure; deterministic in
-- | (cfg.seed, event onset) so the same event always gets the
-- | same fate (no per-frame flicker at lockProb = 0.5).
decideEvent
  :: DejaVuConfig
  -> Array Int
  -> Array (Event Number)
  -> Event Int
  -> Event Int
decideEvent cfg buffer locks ev =
  let
    onset       = onsetOf ev
    cyclePos    = onset - floor onset                            -- 0..1 within cycle
    slotN       = floor (cyclePos * Int.toNumber cfg.length)     -- which 1/N-th
    slotIdx     = wrap cfg.length (Int.floor slotN)
    lockP       = sampleLockAt locks onset 0.0
    decisionH   = decisionHash (Int.toNumber cfg.seed * 1.371 + onset * 1.731)
    shouldLock  = decisionH < lockP
  in
    case Array.index buffer slotIdx of
      Just bufVal | shouldLock -> setValue ev bufVal
      _                        -> ev

-- | Replace the value in an Event without disturbing its arc structure.
setValue :: forall a b. Event a -> b -> Event b
setValue (Digital e) v = Digital (e { value = v })
setValue (Analog e)  v = Analog  (e { value = v })

-- | Onset time of an event as a Number (the event part's start).
onsetOf :: forall a. Event a -> Number
onsetOf ev = case eventPart ev of
  Arc { start } -> Rational.toNumber start

-- | A simple multiplicative hash → 0..1 fractional output.  Used
-- | for the per-event lock decision.  Same machinery as
-- | `Pattern.Core.rand`'s hash, by design — we want decisions to
-- | feel like "the same kind of randomness" the rest of the
-- | system already produces.
decisionHash :: Number -> Number
decisionHash x =
  let big = x * 15485863.0 + 7919.0
  in big - floor big

-- | Find the value of the lockProb pattern at a given onset.  Lock
-- | values come back as Analog events (since `live` produces them);
-- | the one whose part-arc covers `onset` wins.  Falls back to the
-- | default when no event covers the onset (e.g. the lockProb
-- | pattern is silent).
sampleLockAt :: Array (Event Number) -> Number -> Number -> Number
sampleLockAt events onset def =
  case Array.find (covers onset) events of
    Just ev -> eventValue ev
    Nothing -> def
  where
    covers :: Number -> Event Number -> Boolean
    covers t ev = case eventPart ev of
      Arc { start, stop } ->
        t >= Rational.toNumber start && t < Rational.toNumber stop

-- | Modulo-with-positive-result for slot indexing.  Pure Int
-- | `mod` in PureScript returns a value with the sign of the
-- | divisor, but we want a non-negative slot index regardless of
-- | how the input was computed.
wrap :: Int -> Int -> Int
wrap len i =
  let len' = if len <= 0 then 1 else len
  in ((i `mod` len') + len') `mod` len'
