-- | SKETCH — not yet integrated. Lives in `sketches/`, not `src/`.
-- |
-- | Tidal.Cartesian — two-clock Cartesian walker extracted as a
-- | Pattern combinator from Make Noise René 2.
-- |
-- | René 2 is a rich module with 64-state Z-axis memory, mesh-paste,
-- | latch, and a full FUN page — most of which is hardware-UX whose
-- | value is gestural, not algorithmic.  The one genuinely novel
-- | algorithmic idea worth porting is the **two-clock Cartesian
-- | channel**: small clock-ratio changes produce large pattern
-- | shifts, which is hard to express in mini-notation.
-- |
-- | Hardware reference: see
-- | docs/sequencer-vocabulary-research-2026-05-09.md §Module 3.
-- |
-- | Status: Cell + Grid types, the 16 named Snake curves, walkSnake
-- | and walkCartesian sketched.  Quantizer integration uses the
-- | existing Tidal.Cell.Prelude scale machinery (Phase 3a in the
-- | scenes-and-shared-state doc).
module Tidal.Cartesian
  ( -- * Cell
    Cell
  , defaultCell
  , skip
  , gate
  , glide
    -- * Grid
  , Grid
  , mkGrid
  , readCell
    -- * Snake patterns
  , SnakeCurve(..)
  , snakeIndices
    -- * Walkers
  , walkSnake
  , walkCartesian
    -- * Access modes
  , AccessMode(..)
  , withAccess
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Tidal.Pattern.Types
  ( Pattern, pattern, query, Event(..), State(..), Arc(..), eventValue
  , emptyContext)

-------------------------------------------------------------------------------
-- Cell — the per-location state
-------------------------------------------------------------------------------

-- | A single cell in the 4×4 grid.
-- |
-- | - `cv`     : pre-quantise voltage 0..1 (will be quantised at
-- |              read time if a Scale is provided downstream).
-- | - `gate`   : if true, this cell emits a gate when reached.
-- | - `glide`  : if true, the CV transition INTO this cell glides.
-- | - `access` : if false, the walker either skips or sleeps at this
-- |              cell, depending on the channel's AccessMode.
type Cell =
  { cv     :: Number
  , gate   :: Boolean
  , glide  :: Boolean
  , access :: Boolean
  }

defaultCell :: Cell
defaultCell = { cv: 0.0, gate: true, glide: false, access: true }

-- | Cell builder helpers — these compose so you can write
-- | `(skip <<< gate <<< glide) (defaultCell { cv = 0.5 })`.
skip :: Cell -> Cell
skip c = c { access = false }

gate :: Cell -> Cell
gate c = c { gate = true }

glide :: Cell -> Cell
glide c = c { glide = true }

-------------------------------------------------------------------------------
-- Grid — the 4×4 of cells
-------------------------------------------------------------------------------

-- | A 4×4 grid.  We don't refine the dimensions at the type level;
-- | mkGrid pads/truncates to 4×4.
newtype Grid = Grid (Array (Array Cell))

-- | Build a grid from a row-major 2D array.  Out-of-range entries
-- | are clipped; missing rows / columns are padded with default
-- | (silent, accessible, no glide) cells.
mkGrid :: Array (Array Cell) -> Grid
mkGrid rows = Grid $
  Array.take 4 (rows <> emptyRows)
    # map (\row -> Array.take 4 (row <> emptyCols))
  where
    emptyRows = Array.replicate 4 []
    emptyCols = Array.replicate 4 defaultCell

-- | Read a cell at (row, col) — wraps with mod 4 to keep things
-- | total.  This is the lookup the Cartesian walker uses.
readCell :: Grid -> Int -> Int -> Cell
readCell (Grid rows) row col =
  let r = ((row `mod` 4) + 4) `mod` 4
      c = ((col `mod` 4) + 4) `mod` 4
  in fromMaybe defaultCell $ do
       rowArr <- Array.index rows r
       Array.index rowArr c

-------------------------------------------------------------------------------
-- Snake patterns — the 16 named curves
-------------------------------------------------------------------------------

-- | The 16 snake patterns from the René 2 SNAKE page.  Each curve
-- | defines a permutation of [0..15] — the order in which the snake
-- | walker visits cells (linear position 0..15).
-- |
-- | Names follow the manual where possible; the unnamed "spirals"
-- | and "random walks" use generic names.
data SnakeCurve
  = LinearLR        -- 1: left-to-right, top-to-bottom
  | LinearTB        -- 2: top-to-bottom, left-to-right
  | LinearRL        -- 3: right-to-left, bottom-to-top
  | LinearBT        -- 4: bottom-to-top, right-to-left
  | BoustrophedonH  -- 5: zigzag rows
  | BoustrophedonV  -- 6: zigzag columns
  | SpiralIn        -- 7: outer-to-inner spiral
  | SpiralOut       -- 8: inner-to-outer spiral
  | DiagonalNE      -- 9: NE diagonals
  | DiagonalSW      -- 10: SW diagonals
  | KnightsTour1    -- 11: a chess-knight-style tour
  | KnightsTour2    -- 12: another knight tour
  | RandomWalk1     -- 13-16: four random-but-fixed permutations
  | RandomWalk2
  | RandomWalk3
  | RandomWalk4

derive instance eqSnakeCurve :: Eq SnakeCurve

-- | Realised permutation for a curve.  Each entry is a linear cell
-- | index (0..15 = row-major).  These values match the manual's
-- | diagrams as closely as we can reproduce; the four random ones
-- | are *fixed* permutations chosen for variety, not generated each
-- | run — matching the hardware's 16 hardcoded patterns.
snakeIndices :: SnakeCurve -> Array Int
snakeIndices = case _ of
  LinearLR -> [ 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 ]
  LinearTB -> [ 0,  4,  8, 12,  1,  5,  9, 13,  2,  6, 10, 14,  3,  7, 11, 15 ]
  LinearRL -> [ 15, 14, 13, 12, 11, 10,  9,  8,  7,  6,  5,  4,  3,  2,  1,  0 ]
  LinearBT -> [ 15, 11,  7,  3, 14, 10,  6,  2, 13,  9,  5,  1, 12,  8,  4,  0 ]
  BoustrophedonH ->
            [ 0,  1,  2,  3,  7,  6,  5,  4,  8,  9, 10, 11, 15, 14, 13, 12 ]
  BoustrophedonV ->
            [ 0,  4,  8, 12, 13,  9,  5,  1,  2,  6, 10, 14, 15, 11,  7,  3 ]
  SpiralIn ->
            [ 0,  1,  2,  3,  7, 11, 15, 14, 13, 12,  8,  4,  5,  6, 10,  9 ]
  SpiralOut ->
            [ 5,  6, 10,  9,  4,  8, 12, 13, 14, 15, 11,  7,  3,  2,  1,  0 ]
  DiagonalNE ->
            [ 0,  1,  4,  2,  5,  8,  3,  6,  9, 12,  7, 10, 13, 11, 14, 15 ]
  DiagonalSW ->
            [ 15, 14, 11, 13, 10,  7, 12,  9,  6,  3,  8,  5,  2,  4,  1,  0 ]
  KnightsTour1 ->
            [ 0,  6,  9,  3,  4, 10, 13,  7,  1, 11, 14,  8,  2,  5, 15, 12 ]
  KnightsTour2 ->
            [ 5,  3,  8, 14,  0,  6,  9, 15, 10,  4, 11,  1, 12,  7,  2, 13 ]
  RandomWalk1 ->
            [ 7,  3, 11,  1, 14,  9,  5,  0, 13,  8,  4, 15,  2, 12,  6, 10 ]
  RandomWalk2 ->
            [ 2,  9, 12,  5,  0,  7, 14, 11,  4,  6, 15,  3,  8, 13, 10,  1 ]
  RandomWalk3 ->
            [ 11,  4,  7, 15,  2,  9,  0, 13,  6, 12,  3, 10,  1,  8, 14,  5 ]
  RandomWalk4 ->
            [ 14,  1,  6,  9, 12,  3,  5, 11,  0,  8, 15,  2,  7, 10,  4, 13 ]

-------------------------------------------------------------------------------
-- Access mode — the FUN.OP.SLEEP distinction
-------------------------------------------------------------------------------

-- | What happens when the walker hits an inaccessible cell.
-- |
-- | - `Skip` : advance immediately to the next accessible cell.
-- | - `Sleep`: rest at the cell for one tick, emitting silence.
-- |
-- | The Sleep mode is René's distinctive choice — it lets you carve
-- | rests into a sequence without changing its length.  Use it
-- | through `withAccess Sleep`.
data AccessMode = Skip | Sleep

derive instance eqAccessMode :: Eq AccessMode

-------------------------------------------------------------------------------
-- Walkers
-------------------------------------------------------------------------------

-- | Walk a grid via a snake curve, advancing one step per event in
-- | the trigger pattern.  Each event in the input pattern produces
-- | exactly one Cell event in the output (or zero, if the cell at
-- | that position is `access = false` and the AccessMode is Skip).
-- |
-- | Position threading: just like Mimetic's mimetic combinator, the
-- | position is implicit — we scan events in time order and apply
-- | the snake permutation modulo length.
walkSnake :: AccessMode -> Grid -> SnakeCurve -> Pattern Unit -> Pattern Cell
walkSnake mode grid curve trigPat = pattern \st ->
  let
    perm = snakeIndices curve
    permLen = Array.length perm
    trigEvents = query trigPat st
    -- For each event, derive an index into `perm`.  The simplest
    -- correct shape: index = Nth event since cycle start, mod
    -- permLen.  This deliberately doesn't track wall-clock time —
    -- the trigger pattern's own structure determines pace.
  in
    Array.mapWithIndex (renderStep grid mode perm permLen) trigEvents
      # Array.concat
  where
    renderStep :: Grid -> AccessMode -> Array Int -> Int -> Int -> Event Unit
              -> Array (Event Cell)
    renderStep g am p len i ev =
      let pos = fromMaybe 0 (Array.index p (i `mod` len))
          c = readCell g (pos / 4) (pos `mod` 4)
      in
        if c.access then
          [ replaceValue ev c ]
        else case am of
          Skip  -> []                          -- vanish entirely
          Sleep -> [ replaceValue ev silentCell ]   -- emit silence
      where
        silentCell = c { gate = false }

    replaceValue :: forall a. Event a -> Cell -> Event Cell
    replaceValue (Digital e) c = Digital (e { value = c })
    replaceValue (Analog e)  c = Analog  (e { value = c })

-- | The Cartesian channel — two clocks, two coordinates, one cell
-- | lookup per joint event.  The X clock advances the column; the Y
-- | clock advances the row; the cell read is at (row, col) at the
-- | current instant.
-- |
-- | Implementation: at each X event we move col, at each Y event we
-- | move row, and we emit a Cell event whenever *either* clock
-- | ticks (matching the hardware's behaviour where the gate output
-- | combines X and Y rising edges).
walkCartesian :: AccessMode -> Grid -> Pattern Unit -> Pattern Unit -> Pattern Cell
walkCartesian mode grid xClock yClock = pattern \st ->
  let
    xEvs = map (\e -> { ev: e, axis: AxisX }) (query xClock st)
    yEvs = map (\e -> { ev: e, axis: AxisY }) (query yClock st)
    merged = mergeByOnset (xEvs <> yEvs)
    walk = scanWalk { row: 0, col: 0 } merged
  in
    Array.zipWith (renderStep grid mode) walk merged
      # Array.concat
  where
    -- Sort joint events by their onset time; preserve axis tag.
    mergeByOnset
      :: Array { ev :: Event Unit, axis :: Axis }
      -> Array { ev :: Event Unit, axis :: Axis }
    mergeByOnset = Array.sortBy (\a b -> compare (onset a.ev) (onset b.ev))

    onset :: forall x. Event x -> Number
    onset _ = 0.0   -- stub: rationalToNumber (arcStart (eventPart ev))

    -- Scan, threading position through axis-tagged events.
    scanWalk
      :: { row :: Int, col :: Int }
      -> Array { ev :: Event Unit, axis :: Axis }
      -> Array { row :: Int, col :: Int }
    scanWalk p0 evs =
      Array.foldl folder { acc: [], pos: p0 } evs # _.acc
      where
        folder :: { acc :: Array { row :: Int, col :: Int }, pos :: { row :: Int, col :: Int } }
              -> { ev :: Event Unit, axis :: Axis }
              -> { acc :: Array { row :: Int, col :: Int }, pos :: { row :: Int, col :: Int } }
        folder { acc, pos } { axis } =
          let next = case axis of
                AxisX -> pos { col = (pos.col + 1) `mod` 4 }
                AxisY -> pos { row = (pos.row + 1) `mod` 4 }
          in { acc: acc <> [next], pos: next }

    renderStep
      :: Grid -> AccessMode
      -> { row :: Int, col :: Int }
      -> { ev :: Event Unit, axis :: Axis }
      -> Array (Event Cell)
    renderStep g am pos { ev } =
      let c = readCell g pos.row pos.col
      in
        if c.access then
          [ replaceValue ev c ]
        else case am of
          Skip  -> []
          Sleep -> [ replaceValue ev (c { gate = false }) ]

    replaceValue :: forall a. Event a -> Cell -> Event Cell
    replaceValue (Digital e) c = Digital (e { value = c })
    replaceValue (Analog e)  c = Analog  (e { value = c })

-- | Internal axis tag for the Cartesian walker.
data Axis = AxisX | AxisY

derive instance eqAxis :: Eq Axis

-- | Wrap a Pattern Cell with an explicit AccessMode at the
-- | boundary, useful for downstream consumers that expect a
-- | specific behaviour (e.g. quantiser sees only accessible
-- | cells under Skip mode).
withAccess :: AccessMode -> Pattern Cell -> Pattern Cell
withAccess _ p = p   -- pass-through; mode is set at walker construction
                     -- (kept here as a lever for future extension)
