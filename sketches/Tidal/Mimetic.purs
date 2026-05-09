-- | SKETCH — not yet integrated. Lives in `sketches/`, not `src/`.
-- |
-- | Tidal.Mimetic — recallable 4-CV-vector step sequencer with a
-- | navigator-as-Pattern surface modelled on Noise Engineering
-- | Mimetic Digitalis.
-- |
-- | The hardware uses five trigger inputs (N/X/Y/R/O) to navigate a
-- | 4×4 grid of stored 4-CV vectors.  In code we make the navigator
-- | itself a `Pattern Nav` — strictly more expressive than five
-- | patch cables, since a Pattern of nav-actions composes with
-- | every combinator we already have (`fast`, `slow`, `rev`, `jux`,
-- | `every`).
-- |
-- | Hardware reference: see
-- | docs/sequencer-vocabulary-research-2026-05-09.md §Module 2.
-- |
-- | Status: types, navigator algebra, and `mimetic` combinator
-- | sketched.  Bank-construction helpers (zeros / shred /
-- | pitchShred / slide) are stubbed — they want a real RNG, which
-- | belongs in the runtime layer, not the sketch.
module Tidal.Mimetic
  ( -- * Bank
    Bank
  , Vec4
  , v
  , mkBank
  , zeros
    -- * Position
  , Pos
  , origin
  , posIndex
  , indexPos
    -- * Navigation vocabulary
  , Nav(..)
  , step
    -- * Run
  , mimetic
  , mimeticAt
    -- * Bank operations (sketches)
  , slideBy
  , zeroAt
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Tidal.Pattern.Types
  ( Pattern, pattern, query, Event(..), State(..), Arc(..), eventValue
  , emptyContext)

-------------------------------------------------------------------------------
-- 4-vector and bank
-------------------------------------------------------------------------------

-- | Four CV samples in [0..1].  We keep this as a record-by-position
-- | rather than a tuple so destinations can be addressed by name
-- | (`vec.a` etc.) when routed to specific buses.
type Vec4 =
  { a :: Number
  , b :: Number
  , c :: Number
  , d :: Number
  }

-- | Quick constructor: `v 0.5 0.3 0.7 0.0`
v :: Number -> Number -> Number -> Number -> Vec4
v a b c d = { a, b, c, d }

-- | A 16-step bank of Vec4 values.  We don't refine the length at
-- | the type level (yet); `mkBank` truncates / pads with zeros.
newtype Bank = Bank (Array Vec4)

-- | Build a bank from up to 16 vectors; pads with zero-vectors
-- | beyond the input length.
mkBank :: Array Vec4 -> Bank
mkBank xs = Bank $ Array.take 16 (xs <> Array.replicate 16 zeroV)
  where zeroV = v 0.0 0.0 0.0 0.0

zeros :: Bank
zeros = mkBank []

-------------------------------------------------------------------------------
-- Position on the 4×4 grid
-------------------------------------------------------------------------------

-- | Grid position: row 0..3, col 0..3.  Linearised position
-- | (for full N-step navigation) is `row * 4 + col`.
type Pos = { row :: Int, col :: Int }

origin :: Pos
origin = { row: 0, col: 0 }

-- | Linear index 0..15 from a Pos.
posIndex :: Pos -> Int
posIndex p = (p.row * 4 + p.col) `mod` 16

-- | Pos from a linear index 0..15.
indexPos :: Int -> Pos
indexPos i =
  let n = ((i `mod` 16) + 16) `mod` 16
  in { row: n / 4, col: n `mod` 4 }

-------------------------------------------------------------------------------
-- Navigation vocabulary
-------------------------------------------------------------------------------

-- | The five navigation verbs from the hardware.  We expose `RAt`
-- | and `OAt` as pure variants for testability — `R` is the
-- | "real" random in cell context (uses the runtime RNG seeded by
-- | the loop machinery from Tidal.Pam-style infrastructure), but
-- | when authoring tests it's useful to commit to a specific
-- | random destination.
data Nav
  = N           -- next in linear progression (full 16-step wrap)
  | X           -- next column in current row (wraps within row)
  | Y           -- next row in current column (wraps within column)
  | R           -- random step (runtime RNG)
  | O           -- origin (step 1 = (0,0))
  | RAt Int     -- explicit-target random (testable, hashable)
  | OAt Pos     -- explicit-target origin (for "set origin to here")

derive instance eqNav :: Eq Nav

instance showNav :: Show Nav where
  show = case _ of
    N      -> "N"
    X      -> "X"
    Y      -> "Y"
    R      -> "R"
    O      -> "O"
    RAt i  -> "R@" <> show i
    OAt p  -> "O@(" <> show p.row <> "," <> show p.col <> ")"

-- | One navigation step.  The function is total: every Nav has a
-- | well-defined target from any Pos.  R uses the runtime RNG via
-- | the supplied seed; we thread `Int` for now and let the runtime
-- | layer replace it with proper RNG state.
step :: Int -> Nav -> Pos -> Pos
step _    N      p = indexPos (posIndex p + 1)
step _    X      p = p { col = (p.col + 1) `mod` 4 }
step _    Y      p = p { row = (p.row + 1) `mod` 4 }
step seed R      _ = indexPos (seed `mod` 16)
step _    O      _ = origin
step _    (RAt i) _ = indexPos i
step _    (OAt q) _ = q

-------------------------------------------------------------------------------
-- The mimetic combinator
-------------------------------------------------------------------------------

-- | Run a bank against a Pattern of nav actions.  At each event in
-- | the nav pattern, advance position, emit the bank's Vec4 at the
-- | new position.  The result is a `Pattern Vec4` carrying one
-- | 4-vector emission per nav event.
-- |
-- | The position state is *implicit* — it threads through the
-- | sequence of events naturally because each nav event's position
-- | depends only on the previous event's position.  We compute it
-- | by scanning the nav events in time order.
mimetic :: Bank -> Pattern Nav -> Pattern Vec4
mimetic = mimeticAt origin

-- | Like `mimetic` but with an explicit starting position.  Useful
-- | when chaining mimetic cells across cycles or when the bank
-- | layout has a non-(0,0) "natural" entry point.
mimeticAt :: Pos -> Bank -> Pattern Nav -> Pattern Vec4
mimeticAt start (Bank steps) navPat = pattern \st ->
  let
    navEvents = query navPat st
    sortedByOnset = Array.sortBy onsetCmp navEvents
    walk = scanWalk start sortedByOnset
  in
    Array.zipWith (replaceValue steps) walk sortedByOnset
  where
    onsetCmp :: Event Nav -> Event Nav -> Ordering
    onsetCmp a b = compare (arcStartOf a) (arcStartOf b)

    arcStartOf :: forall x. Event x -> Number
    arcStartOf (Digital e) = arcStart e.part
    arcStartOf (Analog e)  = arcStart e.part

    scanWalk :: Pos -> Array (Event Nav) -> Array Pos
    scanWalk p0 evs = Array.foldl folder ([] /\ p0) evs # _.acc
      where
        folder :: { acc :: Array Pos, pos :: Pos } -> Event Nav
              -> { acc :: Array Pos, pos :: Pos }
        folder { acc, pos } ev =
          let next = step (deriveSeed ev) (eventValue ev) pos
          in { acc: acc <> [next], pos: next }

    -- Derive a per-event RNG seed from the event's onset time.
    -- Deterministic so tests can pin behaviour; pluggable in the
    -- runtime layer once we add proper Loop/seed threading.
    deriveSeed :: Event Nav -> Int
    deriveSeed ev = floorTimes (arcStartOf ev * 65537.0)

    floorTimes :: Number -> Int
    floorTimes _ = 0   -- stub — Data.Int.floor in real impl.

    arcStart :: Arc -> Number
    arcStart (Arc { start }) = rationalToNumber start

    rationalToNumber :: forall x. x -> Number
    rationalToNumber _ = 0.0   -- stub — Data.Rational.toNumber in real impl.

    replaceValue :: Array Vec4 -> Pos -> Event Nav -> Event Vec4
    replaceValue bk p ev =
      let val = fromMaybe (v 0.0 0.0 0.0 0.0) (Array.index bk (posIndex p))
      in case ev of
        Digital e -> Digital (e { value = val })
        Analog e  -> Analog  (e { value = val })

-------------------------------------------------------------------------------
-- Bank operations
-------------------------------------------------------------------------------

-- | Slide the bank: rotate by N steps in the linear progression.
-- | The hardware's "Sliding sequence" combo move (Origin + encoder
-- | turn) — useful for changing where a 16-step pattern starts.
slideBy :: Int -> Bank -> Bank
slideBy n (Bank xs) =
  let len = Array.length xs
      k = ((n `mod` len) + len) `mod` len
  in Bank (Array.drop k xs <> Array.take k xs)

-- | Zero a single step in the bank (the hardware's Zero button).
zeroAt :: Pos -> Bank -> Bank
zeroAt p (Bank xs) =
  let i = posIndex p
  in Bank (modifyAt i (\_ -> v 0.0 0.0 0.0 0.0) xs)
  where
    modifyAt :: forall a. Int -> (a -> a) -> Array a -> Array a
    modifyAt n f arr = case Array.index arr n of
      Nothing -> arr
      Just _  -> fromMaybe arr (Array.modifyAt n f arr)

-- | (/\) — local mini-Tuple operator used in `scanWalk` to keep the
-- | sketch single-file.  In real code we'd use Data.Tuple.Nested.
infixr 6 mkPair as /\
mkPair :: forall a b. a -> b -> { acc :: a, pos :: b }
mkPair a b = { acc: a, pos: b }
