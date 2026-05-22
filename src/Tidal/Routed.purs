-- | The `>>` operator — notation routed to a destination.
-- |
-- | Reads any `Notation` (`Pattern a`, `MiniNotation a`, Vetula
-- | declaration, …) on the left, an instrument/drumkit on the right,
-- | and produces a partial Part: a function that takes an mvoice
-- | name and returns a fully-formed `PitchedPart` / `DrumPart`.
-- |
-- |   ```purescript
-- |   bass1Body :: String -> PitchedPart PitchedNote12
-- |   bass1Body = mini "c4 e4 g4" >> bass1Inst
-- |
-- |   bass1A :: PitchedPart PitchedNote12
-- |   bass1A = bass1Body "bass1"
-- |   ```
-- |
-- | This is the cell-text-friendly equivalent of `Calypso.Prelude.on`:
-- |
-- |   ```
-- |   on "bass1" bass1Inst (mini "c4 e4 g4")          -- explicit name + curried
-- |   (mini "c4 e4 g4" >> bass1Inst) "bass1"          -- this module
-- |   ```
-- |
-- | The deferred-mvoice shape is what lets cells in Calypso write
-- | just `pat >> dest`: the cell compiler applies the cell's own name
-- | as the mvoice argument when the cell's body is wrapped for
-- | dispatch.  Today's cell-compile pipeline isn't aware of this yet
-- | (cells still write `on "name" dest (...)` or set patterns
-- | directly); the type-level shape lands here so the compiler-side
-- | work can pick it up.
-- |
-- | Per `docs/north-star.md` §3 — this is the cell-text shorthand
-- | that the architecture's four-cell example assumes:
-- |
-- |   ```
-- |   -- Cell `chord1`: chord1 >> piano1
-- |   -- Cell `melody`: melody >> piano2
-- |   -- Cell `drums`:  (s drums # gain (...)) >> rample
-- |   ```
-- |
-- | Each cell's expression evaluates to a `String -> PitchedPart`;
-- | the cell-template applies the cell's name to complete it.
module Tidal.Routed
  ( class RoutedTo
  , routedTo
  , (>>)
  ) where

import Calypso.Prelude (DrumKit, DrumPart(..), DrumHitRef, Instrument, PitchedPart(..))
import Tidal.Notation (class Notation, toPattern)

-- | A polymorphic infix binder.  The functional dependency
-- | `dest -> result` lets the destination type pick the result shape
-- | (a `PitchedPart`-producing function for `Instrument`, a
-- | `DrumPart`-producing function for `DrumKit`).
class RoutedTo n dest result | dest -> result where
  routedTo :: n -> dest -> result

instance routedInstrument
  :: Notation n note
  => RoutedTo n (Instrument note) (String -> PitchedPart note) where
  routedTo n dest = \mvoice ->
    PitchedPart { mvoice, destination: dest, body: toPattern n }

instance routedDrumKit
  :: Notation n DrumHitRef
  => RoutedTo n DrumKit (String -> DrumPart) where
  routedTo n dest = \mvoice ->
    DrumPart { mvoice, destination: dest, body: toPattern n }

-- | Right-associative, low-precedence — same fixity as application-
-- | style binders.  Doesn't clash with anything in Prelude
-- | (PureScript's Prelude doesn't define `>>`; the monadic sequence
-- | operator is `>>=`).
infixl 1 routedTo as >>
